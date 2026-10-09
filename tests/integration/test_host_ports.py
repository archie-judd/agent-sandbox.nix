import sys

import pytest

from harness.build import BuildSandbox
from harness.launch import Launch
from harness.listeners import tcp_listener
from harness.ports import ALLOWED_HOST_PORT, DENIED_HOST_PORT, INSIDE_PORT, NULL_PORT_A, NULL_PORT_B
from harness.probes import NetworkOp, probe_network

pytestmark = pytest.mark.xdist_group("fixed-ports")

GATEWAY = "10.0.2.2"


def _inside_loopback(port: int) -> str:
    return f"""python3 -c '
import errno, socket
server = socket.socket()
server.bind(("127.0.0.1", {port}))
server.listen()
try:
    socket.create_connection(("127.0.0.1", {port}), timeout=2).close()
    print("ok")
except OSError as error:
    print(errno.errorcode.get(error.errno, error))
'"""


def test_only_the_allowed_host_port_is_reachable(build_sandbox: BuildSandbox, launch: Launch) -> None:
    sandbox = build_sandbox("allowed-host-ports", {"ports": [ALLOWED_HOST_PORT]})
    checks: list[tuple[NetworkOp, str, int]] = [
        ("connect", "127.0.0.1", ALLOWED_HOST_PORT),
        ("connect", "127.0.0.1", DENIED_HOST_PORT),
    ]
    expected = {checks[0]: "ok", checks[1]: "ECONNREFUSED" if sys.platform == "linux" else "EPERM"}
    if sys.platform == "linux":
        gateway_check: tuple[NetworkOp, str, int] = ("connect", GATEWAY, DENIED_HOST_PORT)
        checks.append(gateway_check)
        expected[gateway_check] = "timeout"

    with tcp_listener(ALLOWED_HOST_PORT), tcp_listener(DENIED_HOST_PORT):
        outcomes = probe_network(launch, sandbox, checks)

    assert outcomes == expected


def test_the_sandbox_reaches_its_own_loopback_service(
    build_sandbox: BuildSandbox, launch: Launch
) -> None:
    sandbox = build_sandbox("allowed-host-ports", {"ports": [ALLOWED_HOST_PORT]})
    port = INSIDE_PORT if sys.platform == "linux" else ALLOWED_HOST_PORT

    result = launch(sandbox, _inside_loopback(port))

    assert result.stdout == "ok\n", result.stderr


@pytest.mark.linux
def test_null_allows_every_host_port(build_sandbox: BuildSandbox, launch: Launch) -> None:
    sandbox = build_sandbox("allowed-host-ports", {"ports": None})
    checks: list[tuple[NetworkOp, str, int]] = [
        ("connect", "127.0.0.1", NULL_PORT_A),
        ("connect", "127.0.0.1", NULL_PORT_B),
        ("connect", GATEWAY, NULL_PORT_A),
        ("connect", GATEWAY, NULL_PORT_B),
    ]

    with tcp_listener(NULL_PORT_A), tcp_listener(NULL_PORT_B):
        outcomes = probe_network(launch, sandbox, checks)

    assert outcomes == {check: "ok" for check in checks}
