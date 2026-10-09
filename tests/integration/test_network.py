import shutil
import socket
import sys
import tempfile
import time
from collections.abc import Iterator
from pathlib import Path

import pytest

from harness.build import BuildSandbox
from harness.launch import Launch
from harness.listeners import tcp_listener, udp_listener
from harness.ports import HOST_ADDRESS_PORT, HOST_SERVICE_PORT, HTTPBIN_PORT, INSIDE_PORT, UDP_PORT
from harness.probes import NetworkOp, probe_network

pytestmark = pytest.mark.xdist_group("fixed-ports")

GATEWAY = "10.0.2.2"
DROPPED = {"linux": "timeout", "darwin": "EPERM"}[sys.platform]
CURL = "curl -s -o /dev/null --max-time 10 -w '%{http_code} %{http_connect}\\n'"


def _host_address() -> str | None:
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        try:
            sock.connect(("192.0.2.1", 9))
        except OSError:
            return None
        address: str = sock.getsockname()[0]
    return None if address.startswith("127.") else address


@pytest.fixture
def host_address() -> Iterator[str]:
    address = _host_address()
    if address is None:
        pytest.skip("the host has no non-loopback IPv4 address")
    with tcp_listener(HOST_ADDRESS_PORT, address):
        yield address


@pytest.fixture
def httpbin() -> Iterator[None]:
    with tcp_listener(HTTPBIN_PORT):
        yield


def _curl(launch: Launch, binary: Path, requests: dict[str, str]) -> dict[str, str]:
    script = "\n".join(
        f"printf '%s ' {label}; {CURL} {request} || true" for label, request in requests.items()
    )
    result = launch(binary, script)
    lines = [line.split(" ", 1) for line in result.stdout.splitlines()]
    codes = {label: code for label, code in lines}
    assert codes.keys() == requests.keys(), f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}"
    return codes


def _proxy_log(sessions_root: Path) -> str:
    (session,) = sessions_root.iterdir()
    return (session / "proxy.log").read_text()


def test_the_proxy_admits_allowed_domains_and_refuses_the_rest(
    build_sandbox: BuildSandbox, launch: Launch, sessions_root: Path, httpbin: None
) -> None:
    sandbox = build_sandbox("network-allowed", {"httpbinPort": str(HTTPBIN_PORT)})

    codes = _curl(
        launch,
        sandbox,
        {
            "http": "http://httpbin.test/get",
            "https": "https://httpbin.test/get",
            "post": "-X POST https://httpbin.test/post",
            "blocked": "http://blocked.test/",
            "connect-8080": "https://httpbin.test:8080/get",
            "plain-8081": "http://httpbin.test:8081/get",
        },
    )

    assert {label: codes[label] for label in ("http", "https", "post", "blocked", "plain-8081")} == {
        "http": "200 000",
        "https": "200 200",
        "post": "200 200",
        "blocked": "403 000",
        "plain-8081": "403 000",
    }
    assert codes["connect-8080"].split()[1] == "403"
    log = _proxy_log(sessions_root)
    assert "allowed: httpbin.test" in log
    assert "blocked domain: blocked.test" in log
    assert "blocked non-443 CONNECT: httpbin.test:8080" in log
    assert "blocked non-80 plaintext: httpbin.test:8081" in log


def test_an_empty_allowlist_refuses_everything(
    build_sandbox: BuildSandbox, launch: Launch, sessions_root: Path
) -> None:
    codes = _curl(launch, build_sandbox("network-blocked"), {"http": "http://httpbin.test/get"})

    assert codes == {"http": "403 000"}
    assert "blocked domain: httpbin.test" in _proxy_log(sessions_root)


def test_subdomains_match_but_shared_suffixes_do_not(
    build_sandbox: BuildSandbox, launch: Launch, httpbin: None
) -> None:
    sandbox = build_sandbox("network-method-filtered", {"httpbinPort": str(HTTPBIN_PORT)})

    codes = _curl(
        launch,
        sandbox,
        {"subdomain": "https://www.httpbin.test/get", "suffix": "https://nothttpbin.test/"},
    )

    assert codes["subdomain"] == "200 200"
    assert codes["suffix"].split()[1] == "403"


def test_restricted_mode_has_no_way_around_the_proxy(
    build_sandbox: BuildSandbox, launch: Launch, host_address: str
) -> None:
    loopback_service = GATEWAY if sys.platform == "linux" else "127.0.0.1"
    checks: list[tuple[NetworkOp, str, int]] = [
        ("connect", host_address, HOST_ADDRESS_PORT),
        ("connect", loopback_service, HOST_SERVICE_PORT),
        ("resolve", "localhost", 80),
    ]

    with tcp_listener(HOST_SERVICE_PORT):
        outcomes = probe_network(
            launch, build_sandbox("network-allowed", {"httpbinPort": str(HTTPBIN_PORT)}), checks
        )

    assert outcomes == {checks[0]: DROPPED, checks[1]: DROPPED, checks[2]: "ok"}


@pytest.mark.linux
def test_restricted_mode_resolves_no_names_and_drops_udp_and_icmp(
    build_sandbox: BuildSandbox, launch: Launch
) -> None:
    sandbox = build_sandbox("network-allowed", {"httpbinPort": str(HTTPBIN_PORT)})
    checks: list[tuple[NetworkOp, str, int]] = [
        ("resolve", "example.com", 80),
        ("send_udp", GATEWAY, UDP_PORT),
    ]

    with udp_listener(UDP_PORT) as received:
        outcomes = probe_network(launch, sandbox, checks)
        time.sleep(0.5)
    ping = launch(
        sandbox,
        f"ping -c 1 -W 2 127.0.0.1 >/dev/null && echo loopback; ping -c 1 -W 2 {GATEWAY} >/dev/null || echo gateway-dropped",
    )

    assert outcomes[checks[0]].startswith("EAI_")
    assert outcomes[checks[1]] == "ok"
    assert received == []
    if "loopback" not in ping.stdout:
        pytest.skip("unprivileged ping is not available in this namespace")
    assert "gateway-dropped" in ping.stdout


INSIDE_LOOPBACK = f"""python3 -c '
import errno, socket
server = socket.socket()
server.bind(("127.0.0.1", {INSIDE_PORT}))
server.listen()
try:
    socket.create_connection(("127.0.0.1", {INSIDE_PORT}), timeout=2).close()
    print("ok")
except OSError as error:
    print(errno.errorcode.get(error.errno, error))
'"""


@pytest.mark.linux
def test_open_mode_reaches_beyond_the_host(
    build_sandbox: BuildSandbox, launch: Launch, host_address: str
) -> None:
    check: tuple[NetworkOp, str, int] = ("connect", host_address, HOST_ADDRESS_PORT)

    outcomes = probe_network(launch, build_sandbox("network-unrestricted"), [check])

    assert outcomes == {check: "ok"}


@pytest.mark.linux
def test_open_mode_keeps_host_loopback_out_but_its_own_loopback_in(
    build_sandbox: BuildSandbox, launch: Launch
) -> None:
    sandbox = build_sandbox("network-unrestricted")
    check: tuple[NetworkOp, str, int] = ("connect", GATEWAY, HOST_SERVICE_PORT)

    with tcp_listener(HOST_SERVICE_PORT):
        outcomes = probe_network(launch, sandbox, [check])
    inside = launch(sandbox, INSIDE_LOOPBACK)

    assert outcomes == {check: "timeout"}
    assert inside.stdout == "ok\n", inside.stderr


@pytest.fixture
def host_unix_socket() -> Iterator[Path]:
    directory = Path(tempfile.mkdtemp(dir="/private/tmp", prefix="uxs."))
    path = directory / "l.sock"
    server = socket.socket(socket.AF_UNIX)
    server.bind(str(path))
    server.listen()
    yield path
    server.close()
    shutil.rmtree(directory)


@pytest.mark.darwin
def test_open_mode_denies_every_way_to_the_host_loopback(
    build_sandbox: BuildSandbox, launch: Launch, host_unix_socket: Path
) -> None:
    sandbox = build_sandbox("network-unrestricted")
    checks: list[tuple[NetworkOp, str, int]] = [
        ("connect", "127.0.0.1", HOST_SERVICE_PORT),
        ("connect", "::1", HOST_SERVICE_PORT),
    ]
    unix_connect = f"""python3 -c '
import errno, socket
try:
    socket.socket(socket.AF_UNIX).connect("{host_unix_socket}")
    print("ok")
except OSError as error:
    print(errno.errorcode.get(error.errno, error))
'"""

    with tcp_listener(HOST_SERVICE_PORT), tcp_listener(HOST_SERVICE_PORT, "::1"):
        outcomes = probe_network(launch, sandbox, checks)
    inside = launch(sandbox, INSIDE_LOOPBACK)
    unix = launch(sandbox, unix_connect)

    assert outcomes == {check: "EPERM" for check in checks}
    assert inside.stdout == "EPERM\n", inside.stderr
    assert unix.stdout == "EPERM\n", unix.stderr
