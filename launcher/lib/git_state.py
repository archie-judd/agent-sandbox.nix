import os
import subprocess
from dataclasses import dataclass
from pathlib import Path
from typing import Mapping


@dataclass(frozen=True, kw_only=True)
class GitState:
    common_dir: Path
    repo_root: Path
    work_tree_root: Path
    protected_dirs: tuple[Path, ...]
    protected_files: Mapping[Path, bool]


def _path_exists(path: Path) -> bool:
    try:
        return path.exists()
    except OSError:
        return False


def _run_git_command(git: Path, *args: str, cwd: Path | None = None) -> str | None:
    try:
        result = subprocess.run(
            [str(git), *args],
            cwd=cwd,
            capture_output=True,
            text=True,
            check=False,
        )
    except OSError:
        return None
    if result.returncode != 0:
        return None
    return result.stdout.strip()


def _get_all_gitdirs(common_dir: Path) -> list[Path]:
    owned = [common_dir]
    modules = common_dir / "modules"
    if not modules.is_dir():
        return owned
    walker = os.walk(modules)
    for parent, directories, _ in walker:
        directories.sort()
        for name in directories:
            candidate = Path(parent) / name
            if (candidate / "HEAD").is_file() and (candidate / "config").is_file():
                owned.append(candidate)
    return owned


def _is_worktree_config_enabled(git: Path, config: Path) -> bool:
    # Read per gitdir, because submodules carry their own setting.
    value = _run_git_command(
        git, "config", "--file", str(config), "--get", "extensions.worktreeConfig"
    )
    return value == "true"


def _get_worktree_pointer_files(
    gitdir: Path, worktree_config_enabled: bool
) -> list[Path]:
    # commondir sends the host's git at a different gitdir entirely, so
    # protecting the config without the pointers to it closes nothing.
    worktrees = gitdir / "worktrees"
    if not worktrees.is_dir():
        return []

    pointers: list[Path] = []
    for worktree in sorted(worktrees.iterdir()):
        if not worktree.is_dir():
            continue
        pointers.append(worktree / "commondir")
        if worktree_config_enabled:
            pointers.append(worktree / "config.worktree")
    return pointers


def _get_submodule_dot_git(git: Path, gitdir: Path) -> Path | None:
    # core.worktree is set only for submodules and is relative to the gitdir.
    # Left writable, the .git file it points at would redirect the host's
    # git past the hooks and config protected alongside it.
    submodule_worktree = _run_git_command(
        git, "config", "--file", str(gitdir / "config"), "--get", "core.worktree"
    )
    if not submodule_worktree:
        return None

    dot_git = gitdir / submodule_worktree / ".git"
    if not dot_git.is_file():
        return None
    return Path(os.path.realpath(dot_git))


def _get_protected_files_in_gitdir(git: Path, gitdir: Path) -> list[Path]:
    config = gitdir / "config"
    protected: list[Path] = []
    if config.is_file():
        protected.append(config)

    worktree_config_enabled = _is_worktree_config_enabled(git, config)
    if worktree_config_enabled:
        protected.append(gitdir / "config.worktree")

    protected += _get_worktree_pointer_files(gitdir, worktree_config_enabled)

    submodule_dot_git = _get_submodule_dot_git(git, gitdir)
    if submodule_dot_git is not None:
        protected.append(submodule_dot_git)

    return protected


def _get_worktree_dot_git_files(git: Path, cwd: Path) -> list[Path]:
    # Only worktrees at or under cwd are ever reachable from inside the
    # sandbox; the rest are never bound.
    listing = _run_git_command(git, "worktree", "list", "--porcelain", cwd=cwd)
    if listing is None:
        return []

    dot_git_files: list[Path] = []
    for line in listing.splitlines():
        if not line.startswith("worktree "):
            continue
        worktree_path = Path(line[len("worktree ") :])
        under_cwd = worktree_path == cwd or cwd in worktree_path.parents
        if under_cwd and (worktree_path / ".git").is_file():
            dot_git_files.append(worktree_path / ".git")
    return dot_git_files


def _find_work_tree_root(cwd: Path) -> Path:
    """The nearest ancestor of `cwd`, itself included, holding a .git entry.

    A repository root holds a .git directory; a worktree or submodule root
    holds a .git file. Walked locally rather than asked of git, because
    `git rev-parse --show-toplevel` answers from core.worktree and
    $GIT_WORK_TREE, which a repository the agent can write is free to set.

    A stray or half-built .git between `cwd` and the real root stops the walk
    early, where git would step over it. That direction only ever grants less
    than the caller could have had, so it degrades git rather than exposing
    anything. Falling back to `cwd` when nothing is found does the same.
    """
    current = cwd
    while True:
        dot_git = current / ".git"
        if dot_git.is_dir() or dot_git.is_file():
            return current
        if current.parent == current:
            return cwd
        current = current.parent


def read_git_state(git: Path, cwd: Path) -> GitState | None:
    common = _run_git_command(
        git, "rev-parse", "--path-format=absolute", "--git-common-dir", cwd=cwd
    )
    if not common:
        return None
    common_dir = Path(common)

    protected_dirs: list[Path] = []
    protected_files: dict[Path, bool] = {}

    for gitdir in _get_all_gitdirs(common_dir):
        hooks = gitdir / "hooks"
        if hooks.is_dir():
            protected_dirs.append(hooks)
        for path in _get_protected_files_in_gitdir(git, gitdir):
            protected_files[path] = _path_exists(path)

    for path in _get_worktree_dot_git_files(git, cwd):
        protected_files[path] = _path_exists(path)

    return GitState(
        common_dir=common_dir,
        repo_root=common_dir.parent,
        work_tree_root=_find_work_tree_root(cwd),
        protected_dirs=tuple(protected_dirs),
        protected_files=protected_files,
    )
