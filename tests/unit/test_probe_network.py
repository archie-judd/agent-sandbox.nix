import json
import socket
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

from harness.listeners import tcp_listener, udp_listener

PAYLOAD = Path(__file__).resolve().parent.parent / "integration" / "payloads" / "probe_network.py"


def _free_port() -> int:
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        port: int = sock.getsockname()[1]
        return port


def _probe(*checks: tuple[str, str, int]) -> list[str]:
    result = subprocess.run(
        [sys.executable, str(PAYLOAD), json.dumps(checks)], capture_output=True, text=True, check=True
    )
    outcomes: list[str] = json.loads(result.stdout)
    return outcomes


def test_connect_reports_a_listener_and_a_refusal() -> None:
    listening, closed = _free_port(), _free_port()

    with tcp_listener(listening):
        outcomes = _probe(("connect", "127.0.0.1", listening), ("connect", "127.0.0.1", closed))

    assert outcomes == ["ok", "ECONNREFUSED"]


def test_resolve_reports_resolver_errors_by_name() -> None:
    outcomes = _probe(("resolve", "localhost", 80), ("resolve", "name.invalid", 80))

    assert outcomes[0] == "ok"
    assert outcomes[1].startswith("EAI_")


def test_send_udp_reaches_a_udp_listener() -> None:
    port = _free_port()

    with udp_listener(port) as received:
        outcomes = _probe(("send_udp", "127.0.0.1", port))
        deadline = time.monotonic() + 2
        while not received and time.monotonic() < deadline:
            time.sleep(0.01)

    assert outcomes == ["ok"]
    assert received == [b"probe"]


def test_the_tcp_listener_answers_any_method() -> None:
    port = _free_port()

    with tcp_listener(port):
        for method in ("GET", "POST", "HEAD"):
            request = urllib.request.Request(f"http://127.0.0.1:{port}/", method=method, data=b"x" if method == "POST" else None)
            with urllib.request.urlopen(request, timeout=3) as response:
                assert response.status == 200
