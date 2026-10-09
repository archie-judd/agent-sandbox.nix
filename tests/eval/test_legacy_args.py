import subprocess
from typing import Callable

import pytest

from harness.nix_eval import nix_eval


def test_valid_config_evaluates() -> None:
    result = nix_eval()
    assert result.returncode == 0, result.stderr


@pytest.mark.parametrize(
    ("evaluate", "hint"),
    [
        pytest.param(lambda: nix_eval(extra_env={}), "Use 'env' instead.", id="extraEnv"),
        pytest.param(lambda: nix_eval(state_dirs=[]), "Use 'rwDirs' instead.", id="stateDirs"),
        pytest.param(lambda: nix_eval(state_files=[]), "Use 'rwFiles' instead.", id="stateFiles"),
        pytest.param(
            lambda: nix_eval(restrict_network=True),
            "'restrictNetwork' argument is deprecated",
            id="restrictNetwork",
        ),
        pytest.param(
            lambda: nix_eval(allowed_local_ports=[]),
            "Use 'allowedHostPorts' instead.",
            id="allowedLocalPorts",
        ),
    ],
)
def test_rejected_with_migration_hint(
    evaluate: Callable[[], subprocess.CompletedProcess[str]], hint: str
) -> None:
    result = evaluate()
    assert result.returncode != 0
    assert hint in result.stderr
