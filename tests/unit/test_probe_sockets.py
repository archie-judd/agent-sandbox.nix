import json
import subprocess
import sys
from pathlib import Path

import pytest

from harness.listeners import unix_listener

PAYLOAD = Path(__file__).resolve().parent.parent / "integration" / "payloads" / "probe_sockets.py"


def _probe(*checks: tuple[str, str]) -> list[str]:
    result = subprocess.run(
        [sys.executable, str(PAYLOAD), json.dumps(checks)], capture_output=True, text=True, check=True
    )
    outcomes: list[str] = json.loads(result.stdout)
    return outcomes


@pytest.fixture
def in_tmp(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> Path:
    monkeypatch.chdir(tmp_path)
    return tmp_path


def test_socket_creation_operations_succeed_unsandboxed() -> None:
    assert _probe(("create", ""), ("create_dgram", ""), ("socketpair", ""), ("inet", "")) == [
        "ok",
        "ok",
        "ok",
        "ok",
    ]


def test_roundtrip_and_bind_leave_nothing_behind(in_tmp: Path) -> None:
    assert _probe(("roundtrip", "r.sock"), ("bind", "b.sock")) == ["ok", "ok"]
    assert list(in_tmp.iterdir()) == []


def test_connect_reaches_a_unix_listener_and_reports_a_missing_one(in_tmp: Path) -> None:
    with unix_listener(Path("l.sock")):
        outcomes = _probe(("connect", "l.sock"), ("connect", "missing.sock"))

    assert outcomes == ["ok", "ENOENT"]


def test_unix_listener_refuses_an_over_long_path() -> None:
    with pytest.raises(ValueError, match="sun_path"):
        with unix_listener(Path("/" + "x" * 120)):
            pass
