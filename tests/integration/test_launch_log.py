import os
from pathlib import Path

from harness.build import BuildSandbox
from harness.launch import Launch
from launcher.lib.constants import LAUNCH_LOG, STUB_PID

VERSION = (Path(__file__).resolve().parent.parent.parent / "version.txt").read_text().strip()


def _launch_log(sessions_root: Path) -> str:
    (session,) = sessions_root.iterdir()
    return (session / LAUNCH_LOG).read_text()


def test_a_launch_records_its_request_outcome_and_exit(
    basic_sandbox: Path, launch: Launch, sessions_root: Path, fake_home: Path
) -> None:
    result = launch(basic_sandbox, "echo ok")

    assert result.stdout == "ok\n", result.stderr
    log = _launch_log(sessions_root)
    assert "sandboxed-bash launch requested" in log
    assert f"version:           {VERSION}" in log
    assert "launch prepared" in log
    home = os.path.realpath(fake_home)
    assert f"rwDir  $HOME/.test-state-dir -> {home}/.test-state-dir" in log
    assert "TEST_VAR" in log
    assert "test-value" not in log
    assert "sandbox exited with status 0" in log


def test_a_non_zero_exit_status_is_recorded(
    basic_sandbox: Path, launch: Launch, sessions_root: Path
) -> None:
    assert launch(basic_sandbox, "exit 3").returncode == 3
    assert "sandbox exited with status 3" in _launch_log(sessions_root)


def test_a_refused_launch_says_where_it_was_recorded(
    build_sandbox: BuildSandbox, launch: Launch, sessions_root: Path
) -> None:
    result = launch(build_sandbox("basic-sandbox"), "echo should-not-run")

    assert result.returncode == 1
    assert f"this launch was recorded in {os.path.realpath(sessions_root)}/" in result.stderr
    log = _launch_log(sessions_root)
    assert "launch refused" in log
    assert "declared as rwDir but does not exist" in log


def test_an_rw_dir_holding_the_sessions_root_warns_and_logs(
    basic_sandbox: Path, launch: Launch, fake_home: Path
) -> None:
    root = fake_home / ".test-state-dir" / "sessions"
    root.mkdir()

    result = launch(basic_sandbox, "true", env={"AGENT_SANDBOX_SESSIONS_ROOT": str(root)})

    assert result.returncode == 0, result.stderr
    warning = "is declared read-write and contains this sandbox's own session records"
    assert f"{os.path.realpath(fake_home)}/.test-state-dir {warning}" in result.stderr
    assert warning in _launch_log(root)


def test_the_stub_records_its_pid(
    basic_sandbox: Path, launch: Launch, sessions_root: Path
) -> None:
    assert launch(basic_sandbox, "true").returncode == 0

    (session,) = sessions_root.iterdir()
    assert int((session / STUB_PID).read_text()) > 0
