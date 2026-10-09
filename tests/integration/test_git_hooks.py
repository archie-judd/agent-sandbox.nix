import subprocess
import sys
from pathlib import Path

import pytest

from harness.build import BuildSandbox
from harness.launch import Launch
from harness.probes import PathOp, probe_paths

READ_ONLY = {"linux": "EROFS", "darwin": "EPERM"}[sys.platform]
READ_ONLY_MODE = {"linux": "EACCES", "darwin": "EPERM"}[sys.platform]


def _git(*args: str) -> None:
    subprocess.run(
        ["git", "-c", "init.defaultBranch=main", "-c", "protocol.file.allow=always", *args],
        check=True,
        capture_output=True,
    )


def _make_repo(path: Path) -> None:
    path.mkdir(parents=True)
    _git("-C", str(path), "init", "-q")
    _git("-C", str(path), "config", "user.email", "test@test.com")
    _git("-C", str(path), "config", "user.name", "Test")
    _git("-C", str(path), "commit", "-q", "--allow-empty", "-m", "initial")


@pytest.fixture
def main_repo(tmp_path: Path) -> Path:
    _make_repo(tmp_path / "sub-src")
    main = tmp_path / "main"
    _make_repo(main)
    (main / "file.txt").write_text("init\n")
    _git("-C", str(main), "add", "-A")
    _git("-C", str(main), "commit", "-q", "-m", "file")
    _git("-C", str(main), "submodule", "-q", "add", str(tmp_path / "sub-src"), "vendor/sub")
    _git("-C", str(main), "commit", "-q", "-m", "add submodule")
    _git("-C", str(main), "config", "extensions.worktreeConfig", "true")
    _git("-C", str(main), "worktree", "add", "-q", str(main / ".worktrees" / "feat"), "-b", "feat")
    _make_repo(main / "nested-unrelated")
    return main


@pytest.fixture
def sandbox(build_sandbox: BuildSandbox) -> Path:
    return build_sandbox("git-topologies")


def _install_hook(main_repo: Path, body: str) -> None:
    hook = main_repo / ".git" / "hooks" / "pre-commit"
    hook.write_text(f"#!/bin/sh\n{body}\n")
    hook.chmod(0o755)


def test_persistence_vectors_are_read_only_from_a_worktree(
    sandbox: Path, launch: Launch, main_repo: Path
) -> None:
    worktree = main_repo / ".worktrees" / "feat"
    common = main_repo / ".git"
    submodule = common / "modules" / "vendor" / "sub"
    denied: list[tuple[PathOp, Path]] = [
        ("write", common / "hooks" / "post-checkout"),
        ("write", common / "hooks" / "pre-commit"),
        ("write", common / "config"),
        ("write", common / "worktrees" / "feat" / "commondir"),
        ("write", worktree / ".git"),
        ("write", submodule / "hooks" / "pre-commit"),
        ("write", submodule / "config"),
    ]
    masked: list[tuple[PathOp, Path]] = [
        ("write", common / "config.worktree"),
        ("write", common / "worktrees" / "feat" / "config.worktree"),
        ("write", common / "objects" / "info" / "alternates"),
        ("write", submodule / "objects" / "info" / "alternates"),
    ]
    allowed: list[tuple[PathOp, Path]] = [("read", common / "config"), ("list", common / "hooks")]
    config_before = (common / "config").read_text()

    outcomes = probe_paths(launch, sandbox, [*denied, *masked, *allowed], cwd=worktree)
    renamed = launch(
        sandbox,
        f"touch '{common}/config.sandbox-evil' && mv '{common}/config.sandbox-evil' '{common}/config'",
        cwd=worktree,
    )

    assert outcomes == {
        **{check: READ_ONLY for check in denied},
        **{check: READ_ONLY_MODE for check in masked},
        **{check: "ok" for check in allowed},
    }
    assert renamed.returncode != 0
    assert (common / "config").read_text() == config_before


def test_commits_and_installed_hooks_still_work_from_a_worktree(
    sandbox: Path, launch: Launch, main_repo: Path
) -> None:
    worktree = main_repo / ".worktrees" / "feat"
    marker = worktree / "pre-commit-ran"
    _install_hook(main_repo, f"touch '{marker}'")

    result = launch(sandbox, "git commit --allow-empty -q -m sandbox-test-hook", cwd=worktree)

    assert result.returncode == 0, result.stderr
    assert marker.exists()


def test_persistence_vectors_are_read_only_from_the_repo_root(
    sandbox: Path, launch: Launch, main_repo: Path
) -> None:
    common = main_repo / ".git"
    submodule = common / "modules" / "vendor" / "sub"
    worktree = main_repo / ".worktrees" / "feat"
    nested_hook = main_repo / "nested-unrelated" / ".git" / "hooks" / "post-checkout"
    denied: list[tuple[PathOp, Path]] = [
        ("write", common / "hooks" / "post-checkout"),
        ("write", common / "config"),
        ("write", submodule / "hooks" / "pre-commit"),
        ("write", main_repo / "vendor" / "sub" / ".git"),
        ("write", worktree / ".git"),
    ]
    masked: list[tuple[PathOp, Path]] = [
        ("write", common / "config.worktree"),
        ("write", common / "objects" / "info" / "alternates"),
    ]
    allowed: list[tuple[PathOp, Path]] = [
        ("write", main_repo / "file.txt"),
        ("create", nested_hook),
    ]

    outcomes = probe_paths(launch, sandbox, [*denied, *masked, *allowed], cwd=main_repo)

    assert outcomes == {
        **{check: READ_ONLY for check in denied},
        **{check: READ_ONLY_MODE for check in masked},
        **{check: "ok" for check in allowed},
    }


def test_git_keeps_working_from_the_repo_root(
    sandbox: Path, launch: Launch, main_repo: Path
) -> None:
    marker = main_repo / "pre-commit-ran"
    _install_hook(main_repo, f"touch '{marker}'")
    script = f"""
        mkdir -p '{main_repo}/brand-new' && (cd '{main_repo}/brand-new' && git init -q .) && echo init
        (cd '{main_repo}/vendor/sub' && git log --oneline >/dev/null) && echo submodule-log
        git commit --allow-empty -q -m sandbox-test-hook-root && echo commit
    """

    result = launch(sandbox, script, cwd=main_repo)

    assert result.stdout.split() == ["init", "submodule-log", "commit"], result.stderr
    assert marker.exists()


def test_a_refusing_hook_stops_a_commit_from_a_subdirectory(
    sandbox: Path, launch: Launch, main_repo: Path
) -> None:
    (main_repo / "subdir").mkdir()
    _install_hook(main_repo, "exit 1")

    result = launch(
        sandbox,
        "git commit --allow-empty -q -m sandbox-test-hook-subdir || echo REFUSED",
        cwd=main_repo / "subdir",
    )

    assert result.stdout == "REFUSED\n", result.stderr
