import json

import pytest

from harness.nix_eval import nix_eval


@pytest.mark.parametrize(
    ("ports", "expected"),
    [
        pytest.param([3000], [3000], id="integer port"),
        pytest.param(None, None, id="null allows all ports"),
        pytest.param([3000, 3000], [3000], id="duplicates collapse"),
    ],
)
def test_accepted(ports: object, expected: object) -> None:
    result = nix_eval(allowed_host_ports=ports)
    assert result.returncode == 0, result.stderr
    assert json.loads(result.stdout)["allowed_host_ports"] == expected


@pytest.mark.parametrize(
    "ports",
    [
        pytest.param(["3000"], id="string port"),
        pytest.param(["localhost:3000"], id="colon-delimited string"),
        pytest.param([0], id="zero"),
        pytest.param([65536], id="above range"),
        pytest.param([-1], id="negative"),
    ],
)
def test_rejected(ports: object) -> None:
    result = nix_eval(allowed_host_ports=ports)
    assert result.returncode != 0
    assert "allowedHostPorts must only contain integers" in result.stderr
