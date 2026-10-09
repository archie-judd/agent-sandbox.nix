import shutil
import subprocess
import tempfile
from collections.abc import Iterator
from pathlib import Path

import pytest

from harness.build import BuildSandbox
from harness.launch import Launch
from harness.probes import PathOp, probe_paths

pytestmark = pytest.mark.darwin


@pytest.fixture
def root() -> Iterator[Path]:
    root = Path(tempfile.mkdtemp(dir="/private/tmp", prefix="user-folders."))
    yield root
    shutil.rmtree(root)


@pytest.fixture
def fake_home(root: Path) -> Path:
    home = root / "home"
    (home / ".test-state-dir").mkdir(parents=True)
    (home / ".test-state-file").touch()
    return home


@pytest.fixture
def sessions_root(root: Path) -> Path:
    sessions = root / "sessions"
    sessions.mkdir()
    return sessions


def _getconf(name: str) -> Path:
    result = subprocess.run(["getconf", name], capture_output=True, text=True, check=True)
    return Path(result.stdout.strip())


def test_the_per_user_folders_are_unreachable(
    build_sandbox: BuildSandbox, launch: Launch, root: Path, fake_home: Path
) -> None:
    user_tmp = _getconf("DARWIN_USER_TEMP_DIR")
    user_cache = _getconf("DARWIN_USER_CACHE_DIR")
    folders = Path("/private/var/folders")
    workspace = root / "workspace"
    workspace.mkdir()
    checks: list[tuple[PathOp, Path]] = [
        ("stat", user_tmp),
        ("stat", user_cache),
        ("list", user_tmp),
        ("list", user_cache),
        ("stat", folders),
        ("list", folders),
        ("create", Path("$TMPDIR/new")),
    ]

    outcomes = probe_paths(launch, build_sandbox("basic-sandbox"), checks, cwd=workspace)

    assert outcomes == {
        **{check: "EPERM" for check in checks},
        ("create", Path("$TMPDIR/new")): "ok",
    }
