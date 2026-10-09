import json

import pytest

from harness.nix_eval import nix_eval


@pytest.mark.parametrize(
    ("ports", "expected"),
    [
        pytest.param([3000], [{"port": 3000, "bind_addr": "127.0.0.1"}], id="integer port"),
        pytest.param(
            [{"port": 3000, "bindAddr": "0.0.0.0"}],
            [{"port": 3000, "bind_addr": "0.0.0.0"}],
            id="attrset with bindAddr",
        ),
        pytest.param(
            [{"port": 3000}],
            [{"port": 3000, "bind_addr": "127.0.0.1"}],
            id="attrset defaults bindAddr",
        ),
        pytest.param([3000, 3000], [{"port": 3000, "bind_addr": "127.0.0.1"}], id="duplicates collapse"),
        pytest.param([], [], id="empty list"),
    ],
)
def test_accepted(ports: object, expected: object) -> None:
    result = nix_eval(allowed_domains=[], published_ports=ports)
    assert result.returncode == 0, result.stderr
    assert json.loads(result.stdout)["published_ports"] == expected


def test_null_is_rejected() -> None:
    result = nix_eval(published_ports=None)
    assert result.returncode != 0
    assert "publishedPorts must be a list" in result.stderr


@pytest.mark.parametrize(
    "ports",
    [
        pytest.param(["3000"], id="string port"),
        pytest.param([0], id="zero"),
        pytest.param([65536], id="above range"),
        pytest.param([{"bindAddr": "127.0.0.1"}], id="attrset without port"),
        pytest.param([{"port": 3000, "bindAddr": "localhost"}], id="hostname bindAddr"),
        pytest.param([{"port": 3000, "bindAddr": "256.0.0.1"}], id="out-of-range octet"),
    ],
)
def test_invalid_entry_is_rejected(ports: object) -> None:
    result = nix_eval(published_ports=ports)
    assert result.returncode != 0
    assert "publishedPorts entries must be integers" in result.stderr
