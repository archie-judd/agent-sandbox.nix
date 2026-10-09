import json

import pytest

from harness.nix_eval import nix_eval


@pytest.mark.parametrize(
    "workspace_dir",
    [
        pytest.param("$PWD", id="the default"),
        pytest.param("/tmp/workspace", id="absolute path"),
        pytest.param("$HOME/project", id="variable reference"),
        pytest.param("~/project", id="tilde path"),
    ],
)
def test_accepted(workspace_dir: str) -> None:
    result = nix_eval(workspace_dir=workspace_dir)
    assert result.returncode == 0, result.stderr
    assert json.loads(result.stdout)["workspace_dir"] == workspace_dir


@pytest.mark.parametrize(
    "workspace_dir",
    [
        pytest.param(".", id="relative path"),
        pytest.param("project", id="bare name"),
        pytest.param("", id="empty string"),
    ],
)
def test_non_absolute_is_rejected(workspace_dir: str) -> None:
    result = nix_eval(workspace_dir=workspace_dir)
    assert result.returncode != 0
    assert "workspaceDir must be an absolute path" in result.stderr


def test_null_is_rejected() -> None:
    result = nix_eval(workspace_dir=None)
    assert result.returncode != 0
    assert "workspaceDir must be a string holding an absolute path" in result.stderr
