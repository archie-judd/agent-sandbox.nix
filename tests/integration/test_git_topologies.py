import subprocess
import sys
from pathlib import Path

import pytest

from harness.build import BuildSandbox
from harness.launch import Launch
from harness.probes import PathOp, probe_paths

HIDDEN = {"linux": "ENOENT", "darwin": "EPERM"}[sys.platform]
READ_ONLY = {"linux": "EROFS", "darwin": "EPERM"}[sys.platform]

GIT_SCRIPT = """
git status --porcelain >/dev/null && echo status
git log --oneline -1 >/dev/null && echo log
git diff --name-only | while read -r name; do echo "diff:$name"; done
git commit --allow-empty -q -m sandbox-commit && echo commit
"""


def _git(*args: str) -> None:
    subprocess.run(
        ["git", "-c", "init.defaultBranch=main", "-c", "protocol.file.allow=always", *args],
        check=True,
        capture_output=True,
    )


def _make_repo(path: Path, files: dict[str, str]) -> None:
    path.mkdir(parents=True)
    _git("-C", str(path), "init", "-q")
    _git("-C", str(path), "config", "user.email", "test@test.com")
    _git("-C", str(path), "config", "user.name", "Test")
    for name, content in files.items():
        (path / name).parent.mkdir(parents=True, exist_ok=True)
        (path / name).write_text(content)
    _git("-C", str(path), "add", "-A")
    _git("-C", str(path), "commit", "-q", "--allow-empty", "-m", "initial")


@pytest.fixture
def base(tmp_path: Path) -> Path:
    _make_repo(tmp_path / "main", {"root-file.txt": "main\n", "subdir/sub-file.txt": "sub\n"})
    _git("-C", str(tmp_path / "main"), "worktree", "add", "-q", "-b", "wt", str(tmp_path / "worktree"))
    _make_repo(tmp_path / "sub-a", {"a-file.txt": "a\n", "nested/deep.txt": "deep\n"})
    _make_repo(tmp_path / "sub-b", {"b-file.txt": "b\n"})
    superproject = tmp_path / "super"
    _make_repo(superproject, {"super-file.txt": "super\n"})
    for name in ("sub-a", "sub-b"):
        _git("-C", str(superproject), "submodule", "-q", "add", str(tmp_path / name), name)
        _git("-C", str(superproject / name), "config", "user.email", "test@test.com")
        _git("-C", str(superproject / name), "config", "user.name", "Test")
    _git("-C", str(superproject), "commit", "-q", "-m", "add submodules")
    for changed in ("main/root-file.txt", "worktree/root-file.txt", "super/sub-a/a-file.txt"):
        (tmp_path / changed).write_text("modified\n")
    return tmp_path


def _checks(base: Path, topology: str) -> tuple[Path, dict[tuple[PathOp, Path], str]]:
    main_file = base / "main" / "root-file.txt"
    super_file = base / "super" / "super-file.txt"
    sibling_gitdir = base / "super" / ".git" / "modules" / "sub-b" / "HEAD"
    match topology:
        case "repository root":
            cwd = base / "main"
            return cwd, {
                ("read", cwd / "root-file.txt"): "ok",
                ("read", cwd / "subdir" / "sub-file.txt"): "ok",
                ("create", cwd / "probe"): "ok",
            }
        case "repository subdirectory":
            cwd = base / "main" / "subdir"
            return cwd, {
                ("read", cwd.parent / "root-file.txt"): "ok",
                ("create", cwd.parent / "escape.txt"): READ_ONLY,
                ("create", cwd / "probe"): "ok",
            }
        case "worktree root":
            cwd = base / "worktree"
            return cwd, {
                ("read", cwd / "root-file.txt"): "ok",
                ("read", main_file): HIDDEN,
                ("create", cwd / "probe"): "ok",
            }
        case "worktree subdirectory":
            cwd = base / "worktree" / "subdir"
            return cwd, {
                ("read", cwd.parent / "root-file.txt"): "ok",
                ("read", main_file): HIDDEN,
                ("create", cwd.parent / "escape.txt"): READ_ONLY,
            }
        case "submodule root":
            cwd = base / "super" / "sub-a"
            return cwd, {
                ("read", cwd / "a-file.txt"): "ok",
                ("read", super_file): HIDDEN,
                ("read", sibling_gitdir): HIDDEN,
                ("create", cwd / "probe"): "ok",
            }
        case "submodule subdirectory":
            cwd = base / "super" / "sub-a" / "nested"
            return cwd, {
                ("read", cwd.parent / "a-file.txt"): "ok",
                ("read", super_file): HIDDEN,
                ("read", sibling_gitdir): HIDDEN,
            }
    raise AssertionError(topology)


@pytest.mark.parametrize(
    "topology",
    [
        "repository root",
        "repository subdirectory",
        "worktree root",
        "worktree subdirectory",
        "submodule root",
        "submodule subdirectory",
    ],
)
def test_git_works_and_nothing_above_the_work_tree_is_exposed(
    build_sandbox: BuildSandbox, launch: Launch, base: Path, topology: str
) -> None:
    sandbox = build_sandbox("git-topologies")
    cwd, expected = _checks(base, topology)

    git = launch(sandbox, GIT_SCRIPT, cwd=cwd)
    outcomes = probe_paths(launch, sandbox, list(expected), cwd=cwd)

    lines = git.stdout.splitlines()
    assert {"status", "log", "commit"} <= set(lines), git.stderr
    assert any(line.startswith("diff:") for line in lines), git.stdout
    assert outcomes == expected


def test_a_path_under_a_subdirectory_diffs_clean(
    build_sandbox: BuildSandbox, launch: Launch, base: Path
) -> None:
    result = launch(
        build_sandbox("git-topologies"),
        "git diff --exit-code --quiet -- ../subdir/sub-file.txt && echo clean",
        cwd=base / "main" / "subdir",
    )

    assert result.stdout == "clean\n", result.stderr
