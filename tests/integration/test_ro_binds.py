import sys
from pathlib import Path

import pytest

from harness.build import BuildSandbox
from harness.launch import Launch
from harness.probes import PathOp, probe_paths

READ_ONLY = {"linux": "EROFS", "darwin": "EPERM"}[sys.platform]
NESTED = ".agent-sandbox-nested-ro"


@pytest.fixture
def ro_sandbox(build_sandbox: BuildSandbox, fake_home: Path) -> Path:
    (fake_home / ".test-ro-dir").mkdir()
    (fake_home / ".test-ro-dir" / "contents.txt").write_text("dir-content\n")
    (fake_home / ".test-ro-file").write_text("file-content\n")
    (fake_home / NESTED / "vendor").mkdir(parents=True)
    (fake_home / NESTED / "vendor" / "contents.txt").write_text("dir-content\n")
    (fake_home / NESTED / "pinned.txt").write_text("file-content\n")
    return build_sandbox("ro-binds-sandbox")


def _assert_untouched(ro_dir: Path, ro_file: Path) -> None:
    assert (ro_dir / "contents.txt").read_text() == "dir-content\n"
    assert ro_file.read_text() == "file-content\n"
    assert sorted(path.name for path in ro_dir.iterdir()) == ["contents.txt"]


def test_ro_paths_are_readable(ro_sandbox: Path, launch: Launch) -> None:
    result = launch(
        ro_sandbox, 'cat "$HOME/.test-ro-dir/contents.txt" "$HOME/.test-ro-file"; ls "$HOME/.test-ro-dir"'
    )

    assert result.stdout == "dir-content\nfile-content\ncontents.txt\n", result.stderr


def test_ro_paths_are_not_writable(ro_sandbox: Path, launch: Launch, fake_home: Path) -> None:
    ro_dir = Path("$HOME/.test-ro-dir")
    checks: list[tuple[PathOp, Path]] = [
        ("write", ro_dir / "contents.txt"),
        ("create", ro_dir / "new-file"),
        ("delete", ro_dir / "contents.txt"),
        ("write", Path("$HOME/.test-ro-file")),
    ]

    outcomes = probe_paths(launch, ro_sandbox, checks)

    assert outcomes == {check: READ_ONLY for check in checks}
    _assert_untouched(fake_home / ".test-ro-dir", fake_home / ".test-ro-file")


def test_ro_paths_nested_in_the_workspace_stay_read_only(
    ro_sandbox: Path, launch: Launch, fake_home: Path
) -> None:
    workspace = fake_home / NESTED
    checks: list[tuple[PathOp, Path]] = [
        ("write", workspace / "vendor" / "contents.txt"),
        ("create", workspace / "vendor" / "new-file"),
        ("delete", workspace / "vendor" / "contents.txt"),
        ("write", workspace / "pinned.txt"),
        ("create", workspace / "sibling-file"),
    ]

    contents = launch(ro_sandbox, "cat vendor/contents.txt pinned.txt; ls vendor", cwd=workspace)
    outcomes = probe_paths(launch, ro_sandbox, checks, cwd=workspace)

    assert contents.stdout == "dir-content\nfile-content\ncontents.txt\n", contents.stderr
    assert outcomes == {
        **{check: READ_ONLY for check in checks},
        ("create", workspace / "sibling-file"): "ok",
    }
    _assert_untouched(workspace / "vendor", workspace / "pinned.txt")
