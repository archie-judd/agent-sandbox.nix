import subprocess
from pathlib import Path

import pytest

from harness.build import BuildSandbox
from harness.launch import Launch
from harness.probes import PathOp, probe_paths

pytestmark = pytest.mark.darwin

LIBRARY_PREFERENCES = Path("/Library/Preferences")
DATA_VOLUME = Path("/System/Volumes/Data")
PLISTS = (
    "SystemConfiguration/preferences.plist",
    "SystemConfiguration/NetworkInterfaces.plist",
    "com.apple.loginwindow.plist",
    "com.apple.bluetooth.plist",
)
DEEP_STATE = ".tmp-test-deep-statedir"


def _existing(paths: list[Path]) -> list[Path]:
    present = [path for path in paths if path.exists()]
    assert present, f"none of {paths} exist on this host"
    return present


def test_host_identity_paths_are_denied(basic_sandbox: Path, launch: Launch) -> None:
    plists = _existing([LIBRARY_PREFERENCES / plist for plist in PLISTS])
    data_plists = [DATA_VOLUME / plist.relative_to("/") for plist in plists]
    volumes = _existing([Path("/System/Volumes/Preboot"), Path("/System/Volumes/Update")])
    checks: list[tuple[PathOp, Path]] = [
        ("stat", LIBRARY_PREFERENCES),
        ("list", LIBRARY_PREFERENCES),
        *[("read", plist) for plist in plists],
        ("list", DATA_VOLUME),
        ("list", DATA_VOLUME / "Library" / "Preferences"),
        *[("read", plist) for plist in data_plists],
        *[("list", volume) for volume in volumes],
        ("exec", Path("/usr/bin/plutil")),
    ]

    outcomes = probe_paths(launch, basic_sandbox, checks)

    assert outcomes == {check: "EPERM" for check in checks}


def test_system_libraries_stay_readable(basic_sandbox: Path, launch: Launch) -> None:
    checks: list[tuple[PathOp, Path]] = [
        ("list", Path("/usr/lib")),
        ("list", Path("/System/Library")),
        ("stat", Path("/System/Library/Frameworks/Foundation.framework")),
        ("read", Path("/System/Library/CoreServices/SystemVersion.plist")),
    ]

    outcomes = probe_paths(launch, basic_sandbox, checks)

    assert outcomes == {check: "ok" for check in checks}


@pytest.fixture
def deep_sandbox(build_sandbox: BuildSandbox, fake_home: Path) -> Path:
    (fake_home / DEEP_STATE / "a" / "b" / "c" / "data").mkdir(parents=True)
    (fake_home / DEEP_STATE / "a" / "b" / "c" / "config.json").write_text("{}")
    return build_sandbox("deep-statedir-sandbox")


def test_a_deep_workspace_is_reachable_through_stat_only_ancestors(
    deep_sandbox: Path, launch: Launch, fake_home: Path
) -> None:
    root = fake_home / ".tmp-test-deep-cwd"
    workspace = root / "a" / "b" / "c" / "d" / "e"
    workspace.mkdir(parents=True)
    subprocess.run(["git", "-C", str(workspace), "init", "-q"], check=True)
    ancestors = [root, root / "a", root / "a" / "b", root / "a" / "b" / "c"]
    checks: list[tuple[PathOp, Path]] = [
        *[("stat", ancestor) for ancestor in ancestors],
        ("list", root),
        ("stat", workspace),
        ("create", workspace / "new"),
        ("create", Path("$TMPDIR/new")),
    ]

    outcomes = probe_paths(launch, deep_sandbox, checks, cwd=workspace)

    assert outcomes == {
        **{check: "ok" for check in checks},
        ("list", root): "EPERM",
    }


def test_a_deep_rw_dir_and_rw_file_work_through_the_sandbox_home(
    deep_sandbox: Path, launch: Launch, fake_home: Path
) -> None:
    root = fake_home / DEEP_STATE
    (root / "a" / "b" / "c" / "data" / "existing.txt").write_text("content")
    through_home = Path("$HOME") / DEEP_STATE / "a" / "b" / "c"
    intermediates = [root, root / "a", root / "a" / "b", root / "a" / "b" / "c"]
    checks: list[tuple[PathOp, Path]] = [
        ("create", through_home / "data" / "new.txt"),
        ("read", through_home / "data" / "existing.txt"),
        ("delete", through_home / "data" / "existing.txt"),
        ("write", through_home / "config.json"),
        ("read", through_home / "config.json"),
        *[("stat", intermediate) for intermediate in intermediates],
        ("list", root),
    ]

    outcomes = probe_paths(launch, deep_sandbox, checks)

    assert outcomes == {
        **{check: "ok" for check in checks},
        ("list", root): "EPERM",
    }
