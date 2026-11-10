import threading
from collections.abc import Iterator
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import pytest

from harness.build import BuildSandbox
from harness.launch import Launch
from harness.ports import HTTPBIN_PORT

pytestmark = pytest.mark.xdist_group("fixed-ports")


class _EchoAuthorization(BaseHTTPRequestHandler):
    def do_GET(self) -> None:
        body = (self.headers.get("Authorization") or "").encode()
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format: str, *args: object) -> None:
        pass


@pytest.fixture
def echo_server() -> Iterator[None]:
    server = ThreadingHTTPServer(("127.0.0.1", HTTPBIN_PORT), _EchoAuthorization)
    server.daemon_threads = True
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield
    finally:
        server.shutdown()
        server.server_close()


def test_the_proxy_injects_the_secret_the_sandbox_never_sees(
    build_sandbox: BuildSandbox, launch: Launch, echo_server: None
) -> None:
    binary = build_sandbox("injected-credentials", {"httpbinPort": str(HTTPBIN_PORT)})

    result = launch(
        binary,
        'printf "%s\\n" "$TEST_TOKEN"; env | grep -c real-secret; '
        "curl -s --max-time 10 -H 'Authorization: Bearer placeholder-value' https://httpbin.test/",
        env={"SANDBOX_TEST_SECRET": "real-secret"},
    )

    assert result.stdout.splitlines() == ["placeholder-value", "0", "Bearer real-secret"], result.stderr


def test_an_unresolved_secret_is_reported_by_attribute(
    build_sandbox: BuildSandbox, launch: Launch
) -> None:
    binary = build_sandbox("injected-credentials", {"httpbinPort": str(HTTPBIN_PORT)})

    result = launch(binary, "true")

    assert result.returncode == 1
    assert (
        "[ERROR][agent-sandbox.nix] could not resolve these env and injectedCredentials values:"
        in result.stderr
    )
    assert 'injectedCredentials.TEST_TOKEN.secret = "$SANDBOX_TEST_SECRET"' in result.stderr
