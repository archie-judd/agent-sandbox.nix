import os
from datetime import datetime
from pathlib import Path

import pytest

from harness.builders import make_host_darwin, make_session_darwin, make_spec_darwin
from launcher.lib.host_state import _get_declared_paths
from launcher.lib.launch_config.shared import get_sessions_root_warnings
from launcher.lib.launch_log import (
    write_launch_outcome,
    write_launch_refusals,
    write_launch_request,
)
from launcher.lib.session_state import create_session_dir

NOW = datetime(2026, 1, 1)


def test_the_request_records_the_wrapper_and_the_version(tmp_path: Path) -> None:
    log = tmp_path / "launch.log"

    write_launch_request(log, tmp_path, Path("/spec.json"), make_spec_darwin(), tmp_path, NOW)

    text = log.read_text()
    assert "sandboxed-agent launch requested" in text
    assert "version:           0.0.0" in text
    assert "rwDirs:" in text


def test_the_request_records_env_keys(tmp_path: Path) -> None:
    log = tmp_path / "launch.log"
    spec = make_spec_darwin(env_keys=("TEST_VAR",))

    write_launch_request(log, tmp_path, Path("/spec.json"), spec, tmp_path, NOW)

    assert "env keys:          TEST_VAR" in log.read_text()


def test_refusals_are_recorded(tmp_path: Path) -> None:
    log = tmp_path / "launch.log"

    write_launch_refusals(log, ["the reason"])

    assert log.read_text() == "=== launch refused ===\n  the reason\n\n"


def test_the_outcome_records_what_a_declared_path_expanded_to(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    home = Path(os.path.realpath(tmp_path))
    monkeypatch.setenv("HOME", str(home))
    (home / ".test-state-dir").mkdir()
    declared = tuple(_get_declared_paths(["$HOME/.test-state-dir"], "rw", "dir"))
    log = tmp_path / "launch.log"

    write_launch_outcome(log, make_host_darwin(declared=declared), make_session_darwin(), [])

    assert f"rwDir  $HOME/.test-state-dir -> {home}/.test-state-dir" in log.read_text()


def test_an_rw_dir_holding_the_sessions_root_warns(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    home = Path(os.path.realpath(tmp_path))
    monkeypatch.setenv("HOME", str(home))
    (home / ".test-state-dir").mkdir()
    declared = tuple(_get_declared_paths(["$HOME/.test-state-dir"], "rw", "dir"))
    session_dir = home / ".test-state-dir" / "sessions" / "session"

    warnings = get_sessions_root_warnings(make_host_darwin(declared=declared), session_dir)

    assert warnings == [
        f"[WARN][agent-sandbox.nix] {home}/.test-state-dir is declared read-write and "
        f"contains this sandbox's own session records ({session_dir.parent})."
    ]


@pytest.mark.skipif(os.geteuid() == 0, reason="root bypasses permissions")
def test_an_unwritable_sessions_root_fails_with_a_reason(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    locked = tmp_path / "locked"
    locked.mkdir()
    locked.chmod(0o500)
    monkeypatch.setenv("AGENT_SANDBOX_SESSIONS_ROOT", str(locked / "sessions"))

    with pytest.raises(SystemExit, match="could not create the session directory"):
        create_session_dir(make_spec_darwin(), NOW)

    locked.chmod(0o700)
