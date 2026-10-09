from pathlib import Path

import pytest

from harness.build import BuildSandbox
from harness.launch import Launch
from harness.listeners import tcp_listener
from harness.ports import HTTPBIN_PORT, NO_PROXY_PORT

pytestmark = pytest.mark.xdist_group("fixed-ports")

CURL = "curl -s -o /dev/null --max-time 10 -w '%{http_code}\\n'"


def test_allowed_host_ports_bypass_the_proxy_and_domains_still_use_it(
    build_sandbox: BuildSandbox, launch: Launch, sessions_root: Path
) -> None:
    sandbox = build_sandbox(
        "local-ports-with-domains", {"ports": [NO_PROXY_PORT], "httpbinPort": str(HTTPBIN_PORT)}
    )
    script = f"""
        [ -n "$NO_PROXY" ] && [ -n "$no_proxy" ] && [ -n "$HTTP_PROXY" ] && echo env
        {CURL} http://127.0.0.1:{NO_PROXY_PORT}/
        {CURL} http://localhost:{NO_PROXY_PORT}/
        {CURL} http://httpbin.test/get
        {CURL} http://blocked.test/
    """

    with tcp_listener(NO_PROXY_PORT), tcp_listener(HTTPBIN_PORT):
        result = launch(sandbox, script)

    assert result.stdout.split() == ["env", "200", "200", "200", "403"], result.stderr
    (session,) = sessions_root.iterdir()
    log = (session / "proxy.log").read_text()
    assert "allowed: httpbin.test" in log
    assert "blocked domain: blocked.test" in log
    assert f":{NO_PROXY_PORT}" not in log
