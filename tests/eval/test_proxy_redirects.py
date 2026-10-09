import json

import pytest

from harness.nix_eval import nix_eval


@pytest.mark.parametrize(
    "redirects",
    [
        pytest.param({"httpbin.test": "127.0.0.1:18918"}, id="hostname to loopback"),
        pytest.param({"a.test": "[::1]:18918"}, id="bracketed IPv6"),
        pytest.param({}, id="empty attrset"),
    ],
)
def test_accepted(redirects: dict[str, str]) -> None:
    result = nix_eval(allowed_domains=["httpbin.test"], proxy_redirects=redirects)
    assert result.returncode == 0, result.stderr
    assert json.loads(result.stdout)["proxy"]["redirects"] == redirects


@pytest.mark.parametrize(
    "redirects",
    [
        pytest.param({"a.test,b.test=127.0.0.1:1": "127.0.0.1:18918"}, id="comma in host"),
        pytest.param({"a.test=127.0.0.1:1": "127.0.0.1:18918"}, id="equals in host"),
        pytest.param({"a.test": "127.0.0.1:18918,b.test=127.0.0.1:1"}, id="comma in address"),
        pytest.param({"a.test": 18918}, id="non-string address"),
    ],
)
def test_invalid_entry_is_rejected(redirects: dict[str, object]) -> None:
    result = nix_eval(allowed_domains=["httpbin.test"], proxy_redirects=redirects)
    assert result.returncode != 0
    assert "_proxyRedirects hosts must not contain" in result.stderr


def test_list_is_rejected() -> None:
    result = nix_eval(allowed_domains=["httpbin.test"], proxy_redirects=["a.test=127.0.0.1:18918"])
    assert result.returncode != 0
    assert "_proxyRedirects must be an attrset" in result.stderr
