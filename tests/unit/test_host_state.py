import os
import socket
from pathlib import Path

import pytest

from launcher.lib.host_state import (
    _parse_nix_sandbox_setting,
    _parse_nix_user_is_trusted,
    _path_is_socket,
    get_nix_daemon_socket_path,
)

CONFIG_SHOW = "\n".join(
    [
        "allowed-users = *",
        "sandbox = false",
        "sandbox-fallback = false",
        "store = auto",
        "trusted-users = root",
    ]
)


def test_sandbox_setting_is_read_from_a_config_show_listing() -> None:
    assert _parse_nix_sandbox_setting(CONFIG_SHOW) == "false"


def test_every_sandbox_value_nix_accepts_is_recognised() -> None:
    for value in ("true", "false", "relaxed"):
        assert _parse_nix_sandbox_setting(f"sandbox = {value}\n") == value


def test_sandbox_fallback_is_not_mistaken_for_sandbox() -> None:
    assert _parse_nix_sandbox_setting("sandbox-fallback = true\n") is None


def test_unknown_sandbox_value_reads_as_unknown() -> None:
    # Unknown rather than a default, so a future nix value cannot silently
    # become the permissive answer.
    assert _parse_nix_sandbox_setting("sandbox = someday\n") is None


def test_missing_sandbox_line_reads_as_unknown() -> None:
    assert _parse_nix_sandbox_setting("") is None


def test_trusted_is_read_from_store_info() -> None:
    assert _parse_nix_user_is_trusted('{"trusted":true,"url":"daemon"}') is True
    assert _parse_nix_user_is_trusted('{"trusted":false,"url":"daemon"}') is False


def test_trusted_is_read_from_an_older_daemons_integer() -> None:
    assert _parse_nix_user_is_trusted('{"trusted":1}') is True
    assert _parse_nix_user_is_trusted('{"trusted":0}') is False


def test_absent_trusted_field_reads_as_unknown() -> None:
    assert _parse_nix_user_is_trusted('{"url":"daemon","version":"2.18.1"}') is None


def test_unparseable_store_info_reads_as_unknown() -> None:
    assert _parse_nix_user_is_trusted("error: connection refused") is None
    assert _parse_nix_user_is_trusted("[]") is None


def test_daemon_socket_path_honours_the_override(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    real = Path(os.path.realpath(tmp_path)) / "socket"
    link = tmp_path / "link"
    link.symlink_to(real)
    monkeypatch.setenv("NIX_DAEMON_SOCKET_PATH", str(link))

    assert get_nix_daemon_socket_path() == real


def test_a_missing_path_is_not_a_socket(tmp_path: Path) -> None:
    assert not _path_is_socket(tmp_path / "socket")


def test_a_regular_file_is_not_a_socket(tmp_path: Path) -> None:
    regular = tmp_path / "socket"
    regular.touch()

    assert not _path_is_socket(regular)


def test_a_listening_socket_is_a_socket(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    monkeypatch.chdir(tmp_path)
    with socket.socket(socket.AF_UNIX) as listener:
        listener.bind("socket")

        assert _path_is_socket(tmp_path / "socket")
