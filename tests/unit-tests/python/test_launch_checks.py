"""The allowNix host checks, over every state the host can report.

has_controlling_terminal is False throughout, so the sandbox-setting branch
lands on its no-terminal refusal instead of opening /dev/tty. What is under
test is which branch a given host state reaches, not the prompt itself.
"""

import dataclasses
from pathlib import Path
from typing import Literal

from launcher.lib.build_spec import DependenciesDarwin, SandboxBuildSpecDarwin
from launcher.lib.host_state import HostStateDarwin
from launcher.lib.launch_checks import get_launch_refusals

HOME = Path("/home/someone")
SOCKET = Path("/nix/var/nix/daemon-socket/socket")

SPEC = SandboxBuildSpecDarwin(
    version="0.0.0",
    platform="darwin",
    out_name="sandboxed-agent",
    sandbox_path="/bin",
    pkg_config_path="",
    allow_nix=True,
    allow_unix_sockets=True,
    rw_dirs=(),
    rw_files=(),
    ro_dirs=(),
    ro_files=(),
    env_keys=(),
    allowed_host_ports=(),
    published_ports=(),
    closure_paths_file=Path("/nix/store/closure"),
    cacert_dir=Path("/nix/store/cacert/etc/ssl/certs"),
    cacert_bundle=Path("/nix/store/cacert/etc/ssl/certs/ca-bundle.crt"),
    shell=Path("/nix/store/bash/bin/bash"),
    pre_entry_script=Path("/nix/store/pre-entry"),
    sandboxed_binary=Path("/nix/store/agent/bin/agent"),
    proxy=None,
    dependencies=DependenciesDarwin(
        git=Path("/nix/store/git/bin/git"),
        nix=Path("/nix/store/nix/bin/nix"),
    ),
)

HOST = HostStateDarwin(
    cwd=HOME / "project",
    real_home=HOME,
    uid=501,
    gid=20,
    term="xterm",
    has_controlling_terminal=False,
    declared=(),
    git=None,
    closure_paths=(),
    nix_daemon_socket=SOCKET,
    nix_sandbox_setting="true",
    nix_user_is_trusted=False,
    tty=None,
)


def _refusals(
    sandbox_setting: Literal["true", "false", "relaxed"] | None,
    user_is_trusted: bool | None,
) -> tuple[str, ...]:
    host = dataclasses.replace(
        HOST,
        nix_sandbox_setting=sandbox_setting,
        nix_user_is_trusted=user_is_trusted,
    )
    return get_launch_refusals(SPEC, host)


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
    spec = dataclasses.replace(SPEC, allow_nix=False)
    host = dataclasses.replace(
        HOST, nix_daemon_socket=None, nix_sandbox_setting=None, nix_user_is_trusted=None
    )

    assert get_launch_refusals(spec, host) == ()
