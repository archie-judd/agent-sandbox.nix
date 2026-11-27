import json

import pytest

from harness.nix_eval import nix_eval


def test_allowed_tcp_egress_is_emitted_in_the_linux_spec() -> None:
    rules = [{"cidr": "172.27.0.0/24", "port": 5432}, {"cidr": "192.0.2.1", "port": 443}]
    result = nix_eval(platform="linux", allowed_tcp_egress=rules)
    assert result.returncode == 0, result.stderr
    assert json.loads(result.stdout)["allowed_tcp_egress"] == rules


@pytest.mark.parametrize(
    "rules",
    [
        None,
        [{"port": 5432}],
        [{"cidr": "172.27.0.256", "port": 5432}],
        [{"cidr": "172.27.0.0/33", "port": 5432}],
        [{"cidr": "172.27.0.0/24", "port": 65536}],
        [{"cidr": "172.27.0.0/24\naccept", "port": 5432}],
    ],
)
def test_invalid_tcp_egress_is_rejected(rules: object) -> None:
    result = nix_eval(platform="linux", allowed_tcp_egress=rules)
    assert result.returncode != 0
    assert "allowedTcpEgress must be a list" in result.stderr


def test_allowed_tcp_egress_is_linux_only() -> None:
    result = nix_eval(platform="darwin", allowed_tcp_egress=[{"cidr": "192.0.2.1", "port": 443}])
    assert result.returncode != 0
    assert "allowedTcpEgress is only supported on Linux" in result.stderr
