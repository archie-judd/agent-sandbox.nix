import socket
import sys
import time
import urllib.request
from collections.abc import Iterator
from contextlib import ExitStack
from pathlib import Path

import pytest

from harness.build import BuildSandbox
from harness.launch import Launch, launch_background
from harness.listeners import tcp_listener
from harness.ports import (
    HOST_ADDRESS_PORT,
    NONLOCAL_PUBLISHED_PORT,
    PUBLISHED_PORT,
    UNDECLARED_PORT,
)
from harness.probes import NetworkOp, probe_network

pytestmark = pytest.mark.xdist_group("fixed-ports")

INSIDE_BIND = {"linux": "0.0.0.0", "darwin": "127.0.0.1"}[sys.platform]
DROPPED = {"linux": "timeout", "darwin": "EPERM"}[sys.platform]
UNDECLARED_LISTEN = {"linux": "ok", "darwin": "EPERM"}[sys.platform]
SERVE = """python3 -c '
import errno, http.server, sys, threading
handler = http.server.SimpleHTTPRequestHandler
server = http.server.ThreadingHTTPServer((sys.argv[1], int(sys.argv[2])), handler)
outcomes = []
for port in sys.argv[3:]:
    try:
        extra = http.server.ThreadingHTTPServer((sys.argv[1], int(port)), handler)
    except OSError as error:
        outcomes.append(errno.errorcode.get(error.errno, str(error.errno)))
    else:
        threading.Thread(target=extra.serve_forever, daemon=True).start()
        outcomes.append("ok")
with open("listen-outcomes", "w") as report:
    report.write(" ".join(outcomes))
server.serve_forever()
'"""


def _host_address() -> str | None:
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        try:
            sock.connect(("192.0.2.1", 9))
        except OSError:
            return None
        address: str = sock.getsockname()[0]
    return None if address.startswith("127.") else address


def _status(host: str, port: int) -> int:
    with urllib.request.urlopen(f"http://{host}:{port}/", timeout=3) as response:
        status: int = response.status
        return status


def _refuses(host: str, port: int) -> bool:
    try:
        socket.create_connection((host, port), timeout=3).close()
    except OSError:
        return True
    return False


def _read_when_written(path: Path) -> str:
    deadline = time.monotonic() + 5
    while not path.exists() and time.monotonic() < deadline:
        time.sleep(0.05)
    return path.read_text()


@pytest.fixture
def workspace(tmp_path: Path) -> Path:
    workspace = tmp_path / "workspace"
    workspace.mkdir()
    return workspace


def test_only_the_published_port_reaches_the_sandbox(
    build_sandbox: BuildSandbox, fake_home: Path, sessions_root: Path, workspace: Path
) -> None:
    sandbox = build_sandbox(
        "published-ports", {"publishedPorts": [{"port": PUBLISHED_PORT, "bindAddr": "127.0.0.1"}]}
    )

    with launch_background(
        sandbox,
        f"{SERVE} {INSIDE_BIND} {PUBLISHED_PORT} {UNDECLARED_PORT}",
        is_ready=lambda: _status("127.0.0.1", PUBLISHED_PORT) == 200,
        cwd=workspace,
        home=fake_home,
        sessions_root=sessions_root,
    ):
        assert _status("127.0.0.1", PUBLISHED_PORT) == 200
        assert _refuses("127.0.0.1", UNDECLARED_PORT)
        assert _read_when_written(workspace / "listen-outcomes") == UNDECLARED_LISTEN


@pytest.fixture
def host_address() -> Iterator[str]:
    address = _host_address()
    if address is None:
        pytest.skip("the host has no non-loopback IPv4 address")
    with tcp_listener(HOST_ADDRESS_PORT, address):
        yield address


def test_egress_stays_blocked_while_ports_are_published(
    build_sandbox: BuildSandbox, launch: Launch, host_address: str
) -> None:
    sandbox = build_sandbox(
        "published-ports", {"publishedPorts": [{"port": PUBLISHED_PORT, "bindAddr": "127.0.0.1"}]}
    )
    check: tuple[NetworkOp, str, int] = ("connect", host_address, HOST_ADDRESS_PORT)

    outcomes = probe_network(launch, sandbox, [check])

    assert outcomes == {check: DROPPED}


@pytest.mark.linux
def test_the_bind_address_scopes_who_reaches_a_published_port(
    build_sandbox: BuildSandbox, fake_home: Path, sessions_root: Path, workspace: Path
) -> None:
    address = _host_address()
    if address is None:
        pytest.skip("the host has no non-loopback IPv4 address")
    loopback = build_sandbox(
        "published-ports", {"publishedPorts": [{"port": PUBLISHED_PORT, "bindAddr": "127.0.0.1"}]}
    )
    wildcard = build_sandbox(
        "published-ports",
        {"publishedPorts": [{"port": NONLOCAL_PUBLISHED_PORT, "bindAddr": "0.0.0.0"}]},
    )

    with ExitStack() as stack:
        stack.enter_context(
            launch_background(
                loopback,
                f"{SERVE} 0.0.0.0 {PUBLISHED_PORT}",
                is_ready=lambda: _status("127.0.0.1", PUBLISHED_PORT) == 200,
                cwd=workspace,
                home=fake_home,
                sessions_root=sessions_root,
            )
        )
        stack.enter_context(
            launch_background(
                wildcard,
                f"{SERVE} 0.0.0.0 {NONLOCAL_PUBLISHED_PORT}",
                is_ready=lambda: _status(address, NONLOCAL_PUBLISHED_PORT) == 200,
                cwd=workspace,
                home=fake_home,
                sessions_root=sessions_root,
            )
        )
        assert _status(address, NONLOCAL_PUBLISHED_PORT) == 200
        assert _refuses(address, PUBLISHED_PORT)
