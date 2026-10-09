import json

from harness.nix_eval import nix_eval


def test_defaults_to_false() -> None:
    result = nix_eval()
    assert result.returncode == 0, result.stderr
    assert json.loads(result.stdout)["allow_unix_sockets"] is False


def test_true_is_accepted() -> None:
    result = nix_eval(allow_unix_sockets=True)
    assert result.returncode == 0, result.stderr
    assert json.loads(result.stdout)["allow_unix_sockets"] is True


def test_allow_nix_with_unix_sockets_is_accepted() -> None:
    result = nix_eval(allow_nix=True, allow_unix_sockets=True)
    assert result.returncode == 0, result.stderr


def test_allow_nix_without_unix_sockets_is_rejected() -> None:
    result = nix_eval(allow_nix=True)
    assert result.returncode != 0
    assert "allowNix = true requires allowUnixSockets = true" in result.stderr


def test_allow_nix_with_unix_sockets_false_is_rejected() -> None:
    result = nix_eval(allow_nix=True, allow_unix_sockets=False)
    assert result.returncode != 0
    assert "allowNix = true requires allowUnixSockets = true" in result.stderr


def test_non_boolean_is_rejected() -> None:
    result = nix_eval(allow_unix_sockets="yes")
    assert result.returncode != 0
    assert "allowUnixSockets must be a boolean" in result.stderr
