import os
import shutil
import subprocess
from pathlib import Path

import pytest

from harness.builders import make_host_darwin
from launcher.lib.git_state import GitState, _find_work_tree_root, read_git_state
from launcher.lib.host_state import get_usable_git_state


def _host_git() -> Path:
    git = shutil.which("git")
    assert git is not None
    return Path(git)


def _git(*args: str) -> None:
    subprocess.run(
        ["git", "-c", "init.defaultBranch=main", "-c", "protocol.file.allow=always", *args],
        check=True,
        capture_output=True,
    )


def _make_repo(path: Path) -> Path:
    path.mkdir(parents=True)
    _git("-C", str(path), "init", "-q")
    _git("-C", str(path), "config", "user.email", "test@test.com")
    _git("-C", str(path), "config", "user.name", "Test")
    _git("-C", str(path), "commit", "-q", "--allow-empty", "-m", "initial")
    return path


@pytest.fixture
def base(tmp_path: Path) -> Path:
    return Path(os.path.realpath(tmp_path))


@pytest.fixture(scope="module")
def main_repo(tmp_path_factory: pytest.TempPathFactory) -> Path:
    base = Path(os.path.realpath(tmp_path_factory.mktemp("git-state")))
    source = _make_repo(base / "sub-src")
    main = _make_repo(base / "main")
    _git("-C", str(main), "submodule", "-q", "add", str(source), "vendor/sub")
    _git("-C", str(main), "commit", "-q", "-m", "add submodule")
    _git("-C", str(main), "config", "extensions.worktreeConfig", "true")
    _git("-C", str(main), "worktree", "add", "-q", str(main / ".worktrees" / "feat"), "-b", "feat")
    return main


def test_every_injection_vector_is_protected(main_repo: Path) -> None:
    worktree = main_repo / ".worktrees" / "feat"
    common = main_repo / ".git"
    submodule = common / "modules" / "vendor" / "sub"

    git = read_git_state(_host_git(), worktree)

    assert git is not None
    assert git.common_dir == common
    assert set(git.protected_dirs) == {common / "hooks", submodule / "hooks"}
    assert git.protected_files == {
        common / "config": True,
        common / "objects" / "info" / "alternates": False,
        common / "config.worktree": False,
        common / "worktrees" / "feat" / "commondir": True,
        common / "worktrees" / "feat" / "config.worktree": False,
        submodule / "config": True,
        submodule / "objects" / "info" / "alternates": False,
        main_repo / "vendor" / "sub" / ".git": True,
        worktree / ".git": True,
    }


def test_the_work_tree_root_is_the_nearest_dot_git(main_repo: Path) -> None:
    (main_repo / "subdir").mkdir()
    (main_repo / ".worktrees" / "feat" / "subdir").mkdir()
    (main_repo / "vendor" / "sub" / "nested").mkdir()

    assert _find_work_tree_root(main_repo / "subdir") == main_repo
    assert _find_work_tree_root(main_repo / ".worktrees" / "feat" / "subdir") == (
        main_repo / ".worktrees" / "feat"
    )
    assert _find_work_tree_root(main_repo / "vendor" / "sub" / "nested") == (
        main_repo / "vendor" / "sub"
    )


def _home_repo_state(home: Path, workspace: Path) -> tuple[GitState | None, list[str]]:
    git = read_git_state(_host_git(), workspace)
    assert git is not None
    return get_usable_git_state(make_host_darwin(workspace_dir=workspace, real_home=home, git=git))


def test_a_repo_rooted_at_home_disables_git(base: Path) -> None:
    home = _make_repo(base / "home")
    (home / "subdir").mkdir()

    git, warnings = _home_repo_state(home, home / "subdir")

    assert git is None
    assert warnings == [
        f"[WARN][agent-sandbox.nix] git root resolves to your home directory ({home}), "
        "which the sandbox will not expose. git is disabled for this session."
    ]


def test_a_repo_rooted_above_home_disables_git(base: Path) -> None:
    outer = _make_repo(base / "outer")
    (outer / "home" / "project").mkdir(parents=True)

    git, warnings = _home_repo_state(outer / "home", outer / "home" / "project")

    assert git is None
    assert len(warnings) == 1


def test_a_home_rooted_repo_keeps_git_when_the_workspace_is_home(base: Path) -> None:
    home = _make_repo(base / "home")

    git, warnings = _home_repo_state(home, home)

    assert git is not None
    assert warnings == []
