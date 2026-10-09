import os
import time
from pathlib import Path

import pytest

from harness.build import BuildSandbox
from harness.launch import Launch
from launcher.lib.constants import PROXY_PID


def _is_running(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    return True


def test_the_exit_status_reaches_the_caller(basic_sandbox: Path, launch: Launch) -> None:
    assert launch(basic_sandbox, "exit 3").returncode == 3


def test_the_proxy_is_killed_on_exit(
    build_sandbox: BuildSandbox, launch: Launch, sessions_root: Path
) -> None:
    result = launch(build_sandbox("network-allowed"), "true")

    assert result.returncode == 0, result.stderr
    (session,) = sessions_root.iterdir()
    pid = int((session / PROXY_PID).read_text())
    deadline = time.monotonic() + 2
    while _is_running(pid) and time.monotonic() < deadline:
        time.sleep(0.05)
    assert not _is_running(pid)


@pytest.mark.darwin
@pytest.mark.parametrize("status", [0, 3])
def test_the_session_home_and_tmpdir_are_removed_on_exit(
    basic_sandbox: Path, launch: Launch, sessions_root: Path, status: int
) -> None:
    result = launch(basic_sandbox, f'printf "%s\\n%s" "$HOME" "$TMPDIR"; exit {status}')

    assert result.returncode == status, result.stderr
    home, tmpdir = (Path(line) for line in result.stdout.splitlines())
    root = Path(os.path.realpath(sessions_root))
    assert (home.parent.parent, home.name) == (root, "home")
    assert (tmpdir.parent.parent, tmpdir.name) == (root, "tmp")
    assert not home.exists()
    assert not tmpdir.exists()
