import os
import shutil
import subprocess
from pathlib import Path
from typing import Literal

import pytest

from harness.builders import (
    make_host_darwin,
    make_host_linux,
    make_session,
    make_session_darwin,
    make_spec_darwin,
    make_spec_linux,
)
from launcher.lib.git_state import GitState
from launcher.lib.host_state import (
    MaskedPath,
    _get_declared_paths,
    _get_inner_symlinks,
    _get_masked_paths,
)
from launcher.lib.launch_checks import get_launch_refusals
from launcher.lib.launch_config.darwin import seatbelt
from launcher.lib.launch_config.darwin.compute import (
    compute_launch_config as compute_darwin,
)
from launcher.lib.launch_config.linux.binds import get_declared_binds, get_mask_binds
from launcher.lib.launch_config.linux.compute import (
    compute_launch_config as compute_linux,
)

HOME = Path("/home/someone")
WORKSPACE = HOME / "project"
EMPTY_FILE = "/nix/store/empty"
STORE_FILE = Path(os.path.realpath(os.__file__))


def _mask(
    path: Path,
    kind: Literal["dir", "file"] = "file",
    *,
    exists: bool = True,
    is_dir: bool | None = None,
    hops: tuple[Path, ...] = (),
    unfollowed_symlink: str | None = None,
    is_tracked: bool = False,
) -> MaskedPath:
    return MaskedPath(
        unexpanded_path=str(path),
        expanded_path=path,
        kind=kind,
        exists=exists,
        is_dir=(kind == "dir" and exists and not hops) if is_dir is None else is_dir,
        hops=hops,
        unfollowed_symlink=unfollowed_symlink,
        is_tracked=is_tracked,
    )


def _git(common_dir: Path = WORKSPACE / ".git") -> GitState:
    return GitState(
        common_dir=common_dir,
        repo_root=common_dir.parent,
        work_tree_root=common_dir.parent,
        protected_dirs=(),
        protected_files={},
    )


def _refusals(*masked: MaskedPath, git: GitState | None = None) -> tuple[str, ...]:
    host = make_host_darwin(masked=masked, git=git)
    return get_launch_refusals(make_spec_darwin(), host)


def test_a_masked_file_in_the_workspace_launches() -> None:
    assert _refusals(_mask(WORKSPACE / ".env")) == ()


def test_a_masked_dir_in_the_workspace_launches() -> None:
    assert _refusals(_mask(WORKSPACE / "secrets", "dir")) == ()


def test_a_relative_mask_is_refused() -> None:
    assert _refusals(_mask(Path(".env"))) == (
        ".env: declared as maskedFile but is not an absolute path; write it out "
        "in full or use $HOME",
    )


def test_a_mask_outside_every_exposed_path_is_refused() -> None:
    assert _refusals(_mask(HOME / ".ssh", "dir")) == (
        f"{HOME / '.ssh'}: declared as maskedDir but the sandbox does not expose "
        "it, so there is nothing to mask",
    )


def test_a_mask_inside_the_git_directory_is_refused() -> None:
    assert _refusals(_mask(WORKSPACE / ".git" / "objects", "dir"), git=_git()) == (
        f"{WORKSPACE / '.git' / 'objects'}: declared as maskedDir but it is inside "
        f"the git directory {WORKSPACE / '.git'}, which cannot be masked",
    )


def test_a_masked_dir_containing_the_git_directory_is_refused() -> None:
    git = _git(WORKSPACE / "sub" / ".git")

    refusals = _refusals(_mask(WORKSPACE / "sub", "dir"), git=git)

    assert refusals == (
        f"{WORKSPACE / 'sub'}: declared as maskedDir but it contains "
        f"{WORKSPACE / 'sub' / '.git'}, which the sandbox binds separately. "
        "Overlapping masks are not supported",
    )


def test_a_masked_dir_containing_a_declared_path_is_refused(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    home = Path(os.path.realpath(tmp_path))
    monkeypatch.setenv("HOME", str(home))
    (home / "state" / "inner").mkdir(parents=True)
    declared = tuple(_get_declared_paths(["$HOME/state/inner"], "rw", "dir"))
    declared += tuple(_get_declared_paths(["$HOME/state"], "rw", "dir"))
    host = make_host_darwin(
        workspace_dir=home / "project",
        real_home=home,
        declared=declared,
        masked=(_mask(home / "state", "dir"),),
    )

    refusals = get_launch_refusals(make_spec_darwin(), host)

    assert (
        f"{home / 'state'}: declared as maskedDir but it contains "
        f"{home / 'state' / 'inner'}, which the sandbox binds separately. "
        "Overlapping masks are not supported"
    ) in refusals


def test_a_masked_symlink_to_an_exposed_path_is_refused() -> None:
    link = _mask(WORKSPACE / ".env", hops=(WORKSPACE / "config" / ".env",))

    assert _refusals(link) == (
        f"{WORKSPACE / '.env'}: declared as maskedFile but it is a symlink to "
        f"{WORKSPACE / 'config' / '.env'}, which the sandbox still exposes, so "
        "masking the link would not hide it",
    )


def test_a_masked_symlink_out_of_the_sandbox_launches() -> None:
    link = _mask(WORKSPACE / ".env", hops=(HOME / "private" / ".env",))

    assert _refusals(link) == ()


def test_a_mask_with_an_unfollowed_symlink_is_refused() -> None:
    mask = _mask(
        WORKSPACE / "loop" / ".env",
        unfollowed_symlink="it is reached through a symlink loop",
    )

    assert _refusals(mask) == (
        f"{WORKSPACE / 'loop' / '.env'}: declared as maskedFile but it is reached "
        "through a symlink loop",
    )


def test_a_directory_in_masked_files_is_refused() -> None:
    assert _refusals(_mask(WORKSPACE / "secrets", is_dir=True)) == (
        f"{WORKSPACE / 'secrets'}: declared as maskedFile but it is a directory; "
        "declare it in maskedDirs",
    )


def test_a_file_in_masked_dirs_is_refused() -> None:
    assert _refusals(_mask(WORKSPACE / ".env", "dir", is_dir=False)) == (
        f"{WORKSPACE / '.env'}: declared as maskedDir but it is not a directory; "
        "declare it in maskedFiles",
    )


def test_get_masked_paths_expands_and_resolves(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    home = Path(os.path.realpath(tmp_path))
    monkeypatch.setenv("HOME", str(home))
    (home / "real").mkdir()
    (home / "real" / ".env").touch()
    (home / "linked").symlink_to(home / "real")
    (home / "real" / "dangling").symlink_to(home / "nowhere")

    masked = _get_masked_paths(
        ["$HOME/linked/.env", "~/real/dangling", "$HOME/real/missing"],
        "file",
        Path("/nonexistent/git"),
    )

    assert [m.expanded_path for m in masked] == [
        home / "real" / ".env",
        home / "real" / "dangling",
        home / "real" / "missing",
    ]
    assert [m.exists for m in masked] == [True, True, False]
    assert [m.hops for m in masked] == [(), (home / "nowhere",), ()]
    assert [m.is_dir for m in masked] == [False, False, False]
    assert [m.unfollowed_symlink for m in masked] == [None, None, None]


def test_get_masked_paths_records_the_host_type(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    home = Path(os.path.realpath(tmp_path))
    monkeypatch.setenv("HOME", str(home))
    (home / "dir").mkdir()
    (home / "file").touch()

    masked = _get_masked_paths(["$HOME/dir", "$HOME/file"], "dir", Path("/nonexistent/git"))

    assert [m.is_dir for m in masked] == [True, False]


def test_get_masked_paths_records_an_unfollowed_symlink(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    home = Path(os.path.realpath(tmp_path))
    monkeypatch.setenv("HOME", str(home))
    (home / "loop").symlink_to(home / "loop")

    [mask] = _get_masked_paths(["$HOME/loop/.env"], "file", Path("/nonexistent/git"))

    assert mask.unfollowed_symlink is not None
    assert mask.expanded_path == home / "loop" / ".env"


@pytest.mark.skipif(shutil.which("git") is None, reason="needs git")
def test_get_masked_paths_reports_tracked_files(tmp_path: Path) -> None:
    git = Path(shutil.which("git") or "git")
    repo = Path(os.path.realpath(tmp_path))
    subprocess.run([str(git), "init", "-q", str(repo)], check=True)
    (repo / "tracked").write_text("x")
    (repo / "ignored").write_text("x")
    (repo / "dir").mkdir()
    (repo / "dir" / "tracked").write_text("x")
    subprocess.run([str(git), "-C", str(repo), "add", "tracked", "dir"], check=True)

    files = _get_masked_paths([str(repo / "tracked"), str(repo / "ignored")], "file", git)
    dirs = _get_masked_paths([str(repo / "dir")], "dir", git)

    assert [m.is_tracked for m in files] == [True, False]
    assert [m.is_tracked for m in dirs] == [True]


def test_mask_binds_cover_dirs_and_files() -> None:
    host = make_host_linux(
        masked=(_mask(WORKSPACE / "secrets", "dir"), _mask(WORKSPACE / ".env"))
    )

    assert get_mask_binds(make_spec_linux(), host) == [
        "--tmpfs",
        str(WORKSPACE / "secrets"),
        "--remount-ro",
        str(WORKSPACE / "secrets"),
        "--ro-bind",
        EMPTY_FILE,
        str(WORKSPACE / ".env"),
    ]


def test_missing_and_symlinked_masks_get_no_bind() -> None:
    host = make_host_linux(
        masked=(
            _mask(WORKSPACE / ".env", exists=False),
            _mask(WORKSPACE / ".envrc", hops=(HOME / "private",)),
        )
    )

    assert get_mask_binds(make_spec_linux(), host) == []


def test_mask_binds_follow_the_workspace_and_declared_binds() -> None:
    host = make_host_linux(masked=(_mask(WORKSPACE / ".env"),))

    args = list(compute_linux(make_spec_linux(), host, make_session()).bwrap_args)

    workspace_bind = args.index("--bind", args.index(str(WORKSPACE)) - 1)
    mask_bind = args.index(str(WORKSPACE / ".env"))
    assert workspace_bind < mask_bind
    assert args[mask_bind - 2 : mask_bind + 1] == [
        "--ro-bind",
        EMPTY_FILE,
        str(WORKSPACE / ".env"),
    ]


TRACKED_WARNING = (
    f"[WARN][agent-sandbox.nix] {WORKSPACE / '.env'} is masked but tracked by git, "
    "so its contents stay readable through git history."
)


def test_a_tracked_mask_warns_on_linux() -> None:
    host = make_host_linux(masked=(_mask(WORKSPACE / ".env", is_tracked=True),))

    config = compute_linux(make_spec_linux(), host, make_session())

    assert TRACKED_WARNING in config.warnings


def test_a_tracked_mask_warns_on_darwin() -> None:
    host = make_host_darwin(masked=(_mask(WORKSPACE / ".env", is_tracked=True),))

    config = compute_darwin(make_spec_darwin(), host, make_session_darwin())

    assert TRACKED_WARNING in config.warnings


def test_seatbelt_masked_paths() -> None:
    lines = seatbelt.masked_paths(
        [Path("/ws/secrets")], [Path("/ws/a/.env")], [Path("/ws/a")]
    )

    assert lines == [
        "",
        ";; Masked paths — deny every access",
        '(deny file-read* file-write* process-exec (subpath "/ws/secrets"))',
        '(deny network-bind (local unix-socket (subpath "/ws/secrets")))',
        '(deny network-outbound (remote unix-socket (subpath "/ws/secrets")))',
        '(deny file-read* file-write* process-exec (literal "/ws/a/.env"))',
        '(deny network-bind (local unix-socket (path-literal "/ws/a/.env")))',
        '(deny network-outbound (remote unix-socket (path-literal "/ws/a/.env")))',
        ";; ...and their ancestors cannot be renamed out from under them",
        '(deny file-write* (literal "/ws/a"))',
    ]


def test_seatbelt_masked_paths_is_empty_without_masks() -> None:
    assert seatbelt.masked_paths([], [], []) == []


def test_darwin_masks_come_last_with_their_ancestors() -> None:
    nested = WORKSPACE / "a" / "b" / ".env"
    host = make_host_darwin(
        git=_git(),
        masked=(_mask(nested), _mask(WORKSPACE / "gone", exists=False)),
    )

    lines = list(compute_darwin(make_spec_darwin(), host, make_session_darwin()).seatbelt_profile_lines)

    start = lines.index(";; Masked paths — deny every access")
    assert lines[start:] == [
        ";; Masked paths — deny every access",
        f'(deny file-read* file-write* process-exec (literal "{nested}"))',
        f'(deny network-bind (local unix-socket (path-literal "{nested}")))',
        f'(deny network-outbound (remote unix-socket (path-literal "{nested}")))',
        ";; ...and their ancestors cannot be renamed out from under them",
        f'(deny file-write* (literal "{WORKSPACE / "a" / "b"}"))',
        f'(deny file-write* (literal "{WORKSPACE / "a"}"))',
    ]


def test_a_masked_workspace_symlink_gets_no_warning_and_no_bind(tmp_path: Path) -> None:
    root = Path(os.path.realpath(tmp_path))
    workspace = root / "workspace"
    workspace.mkdir()
    (root / "secret").touch()
    (workspace / ".env").symlink_to(root / "secret")
    (workspace / "result").symlink_to(STORE_FILE)
    host = make_host_linux(
        workspace_inner_symlinks=_get_inner_symlinks(workspace),
        masked=(
            _mask(workspace / ".env", hops=(root / "secret",)),
            _mask(workspace / "result", hops=(STORE_FILE,)),
        ),
    )

    binds = get_declared_binds(host, [workspace])

    assert binds.warnings == ()
    assert binds.symlink_targets == ()


def test_a_symlink_inside_a_masked_dir_gets_no_warning(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    home = Path(os.path.realpath(tmp_path))
    monkeypatch.setenv("HOME", str(home))
    (home / "state").mkdir()
    (home / "secret").touch()
    (home / "state" / "link").symlink_to(home / "secret")
    declared = tuple(_get_declared_paths(["$HOME/state"], "rw", "dir"))
    host = make_host_linux(declared=declared, masked=(_mask(home / "state", "dir"),))

    binds = get_declared_binds(host, [home / "state"])

    assert binds.warnings == ()
