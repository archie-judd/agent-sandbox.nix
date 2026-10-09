"""The allowNix host checks, over every state the host can report.

has_controlling_terminal is False throughout, so the sandbox-setting branch
lands on its no-terminal refusal instead of opening /dev/tty. What is under
test is which branch a given host state reaches, not the prompt itself.
"""

import os
from pathlib import Path
from typing import Literal

import pytest

from harness.builders import make_host_darwin, make_spec_darwin
from launcher.lib.host_state import DeclaredPath, _get_declared_paths
from launcher.lib.launch_checks import get_launch_refusals

SOCKET = Path("/nix/var/nix/daemon-socket/socket")


def _refusals(
    sandbox_setting: Literal["true", "false", "relaxed"] | None,
    user_is_trusted: bool | None,
) -> tuple[str, ...]:
    spec = make_spec_darwin(allow_nix=True, allow_unix_sockets=True)
    host = make_host_darwin(
        nix_daemon_socket=SOCKET,
        nix_sandbox_setting=sandbox_setting,
        nix_user_is_trusted=user_is_trusted,
    )
    return get_launch_refusals(spec, host)


def test_a_sandboxing_daemon_and_an_untrusted_user_launches() -> None:
    assert _refusals("true", False) == ()


def test_a_trusted_user_is_refused() -> None:
    refusals = _refusals("true", True)

    assert len(refusals) == 1
    assert "you are a trusted user of the host's nix daemon" in refusals[0]


def test_an_unverifiable_user_is_refused() -> None:
    # Fail closed: the thing we could not rule out is root on the host.
    refusals = _refusals("true", None)

    assert len(refusals) == 1
    assert "could not determine whether you are a trusted user" in refusals[0]


def test_a_trusted_user_is_refused_before_being_asked_about_the_sandbox() -> None:
    # One refusal, not two: the launch is over, so there is nothing to confirm.
    refusals = _refusals("false", True)

    assert len(refusals) == 1
    assert "you are a trusted user of the host's nix daemon" in refusals[0]


def test_an_unsandboxed_daemon_needs_a_terminal() -> None:
    refusals = _refusals("false", False)

    assert len(refusals) == 1
    assert "sandbox = false" in refusals[0]
    assert "no terminal to confirm on" in refusals[0]


def test_a_relaxed_daemon_needs_a_terminal() -> None:
    # relaxed lets a derivation set __noChroot, and the agent writes them.
    refusals = _refusals("relaxed", False)

    assert len(refusals) == 1
    assert "sandbox = relaxed" in refusals[0]


def test_an_unreadable_sandbox_setting_needs_a_terminal() -> None:
    refusals = _refusals(None, False)

    assert len(refusals) == 1
    assert "sandbox = unreadable" in refusals[0]


def test_neither_check_runs_without_allow_nix() -> None:
    assert get_launch_refusals(make_spec_darwin(), make_host_darwin()) == ()


def test_allow_nix_without_a_daemon_socket_is_refused(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    missing = Path(os.path.realpath(tmp_path)) / "no-daemon-here" / "socket"
    monkeypatch.setenv("NIX_DAEMON_SOCKET_PATH", str(missing))
    spec = make_spec_darwin(allow_nix=True, allow_unix_sockets=True)

    refusals = get_launch_refusals(spec, make_host_darwin())

    assert len(refusals) == 1
    assert f"no nix daemon socket at {missing}" in refusals[0]


@pytest.fixture
def home(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> Path:
    home = Path(os.path.realpath(tmp_path))
    monkeypatch.setenv("HOME", str(home))
    (home / "binds").mkdir()
    return home


def _declared_binds() -> tuple[DeclaredPath, ...]:
    return (
        *_get_declared_paths(["$HOME/binds/dir"], "rw", "dir"),
        *_get_declared_paths(["$HOME/binds/file"], "rw", "file"),
    )


def _missing(home: Path, name: str, label: str) -> str:
    return (
        f"{home}/binds/{name}: declared as {label} but does not exist "
        f'(declared as "$HOME/binds/{name}")'
    )


def test_every_missing_bind_is_refused(home: Path) -> None:
    host = make_host_darwin(declared=_declared_binds())

    assert get_launch_refusals(make_spec_darwin(), host) == (
        _missing(home, "dir", "rwDir"),
        _missing(home, "file", "rwFile"),
    )


def test_a_missing_rw_dir_alone_is_refused(home: Path) -> None:
    (home / "binds" / "file").touch()
    host = make_host_darwin(declared=_declared_binds())

    assert get_launch_refusals(make_spec_darwin(), host) == (
        _missing(home, "dir", "rwDir"),
    )


def test_a_missing_rw_file_alone_is_refused(home: Path) -> None:
    (home / "binds" / "dir").mkdir()
    host = make_host_darwin(declared=_declared_binds())

    assert get_launch_refusals(make_spec_darwin(), host) == (
        _missing(home, "file", "rwFile"),
    )


def test_existing_binds_launch(home: Path) -> None:
    (home / "binds" / "dir").mkdir()
    (home / "binds" / "file").touch()
    host = make_host_darwin(declared=_declared_binds())

    assert get_launch_refusals(make_spec_darwin(), host) == ()
