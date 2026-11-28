import sys
from pathlib import Path

import pytest

from harness.build import BuildSandbox
from harness.launch import Launch
from harness.probes import PathOp, probe_paths

DENIED = {"linux": "EROFS", "darwin": "EPERM"}[sys.platform]
SECRET = "secret-content\n"


@pytest.fixture
def workspace(tmp_path: Path) -> Path:
    root = tmp_path / "workspace"
    (root / "secrets").mkdir(parents=True)
    (root / "secrets" / "key").write_text(SECRET)
    (root / ".env").write_text(SECRET)
    (root / "a" / "b").mkdir(parents=True)
    (root / "a" / "b" / ".env").write_text(SECRET)
    (root / "visible.txt").write_text("visible\n")
    return root


@pytest.fixture
def masked_sandbox(build_sandbox: BuildSandbox) -> Path:
    return build_sandbox("masked-paths")


def _assert_untouched(workspace: Path) -> None:
    assert (workspace / ".env").read_text() == SECRET
    assert (workspace / "a" / "b" / ".env").read_text() == SECRET
    assert sorted(p.name for p in (workspace / "secrets").iterdir()) == ["key"]
    assert (workspace / "secrets" / "key").read_text() == SECRET


def test_masked_contents_are_hidden(
    masked_sandbox: Path, launch: Launch, workspace: Path
) -> None:
    result = launch(
        masked_sandbox,
        "cat .env a/b/.env secrets/key; ls -A secrets; cat visible.txt",
        cwd=workspace,
    )

    assert "secret-content" not in result.stdout
    assert "key" not in result.stdout
    assert "visible" in result.stdout
    _assert_untouched(workspace)


def test_masked_paths_are_not_writable(
    masked_sandbox: Path, launch: Launch, workspace: Path
) -> None:
    checks: list[tuple[PathOp, Path]] = [
        ("write", workspace / ".env"),
        ("delete", workspace / ".env"),
        ("create", workspace / "secrets" / "new-file"),
        ("delete", workspace / "secrets" / "key"),
        ("create", workspace / "sibling-file"),
    ]

    outcomes = probe_paths(launch, masked_sandbox, checks, cwd=workspace)

    assert outcomes[("write", workspace / ".env")] == DENIED
    assert outcomes[("delete", workspace / ".env")] != "ok"
    assert outcomes[("create", workspace / "secrets" / "new-file")] == DENIED
    assert outcomes[("delete", workspace / "secrets" / "key")] != "ok"
    assert outcomes[("create", workspace / "sibling-file")] == "ok"
    _assert_untouched(workspace)


def test_a_missing_mask_leaves_nothing_on_the_host(
    masked_sandbox: Path, launch: Launch, workspace: Path
) -> None:
    result = launch(masked_sandbox, "true", cwd=workspace)

    assert result.returncode == 0, result.stderr
    assert not (workspace / "missing").exists()


def test_a_masked_symlink_out_of_the_sandbox_does_not_warn(
    masked_sandbox: Path, launch: Launch, workspace: Path, tmp_path: Path
) -> None:
    outside = tmp_path / "outside-envrc"
    outside.write_text(SECRET)
    (workspace / ".envrc").symlink_to(outside)

    result = launch(masked_sandbox, "cat .envrc", cwd=workspace)

    assert "secret-content" not in result.stdout
    assert "ignoring symlink" not in result.stderr
    assert outside.read_text() == SECRET


@pytest.mark.darwin
def test_renaming_an_ancestor_does_not_unmask(
    masked_sandbox: Path, launch: Launch, workspace: Path
) -> None:
    result = launch(
        masked_sandbox,
        "mv a z; mv a/b a/c; cat z/b/.env a/c/.env",
        cwd=workspace,
    )

    assert "secret-content" not in result.stdout
    assert (workspace / "a" / "b" / ".env").read_text() == SECRET


@pytest.mark.darwin
def test_files_can_still_be_created_beside_a_mask(
    masked_sandbox: Path, launch: Launch, workspace: Path
) -> None:
    checks: list[tuple[PathOp, Path]] = [
        ("create", workspace / "a" / "new-file"),
        ("create", workspace / "a" / "b" / "new-file"),
    ]

    outcomes = probe_paths(launch, masked_sandbox, checks, cwd=workspace)

    assert outcomes == {check: "ok" for check in checks}


@pytest.mark.darwin
def test_git_status_tolerates_a_masked_ignored_file(
    masked_sandbox: Path, launch: Launch, workspace: Path
) -> None:
    (workspace / ".gitignore").write_text(".env\nsecrets/\na/b/.env\n")

    result = launch(
        masked_sandbox,
        "git init -q . && git status --porcelain",
        cwd=workspace,
    )

    assert result.returncode == 0, result.stderr
    assert "warning" not in result.stderr
