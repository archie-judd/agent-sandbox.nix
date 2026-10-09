from pathlib import Path
from typing import Literal

from launcher.lib.build_spec import (
    DependenciesDarwin,
    DependenciesLinux,
    SandboxBuildSpecDarwin,
    SandboxBuildSpecLinux,
)
from launcher.lib.host_state import DeclaredPath, HostStateDarwin, HostStateLinux
from launcher.lib.session_state import SessionState, SessionStateDarwin

_HOME = Path("/home/someone")
_SESSION_DIR = Path("/sessions/20260101-000000-1-sandboxed-agent")


def make_spec_linux() -> SandboxBuildSpecLinux:
    return SandboxBuildSpecLinux(
        version="0.0.0",
        platform="linux",
        out_name="sandboxed-agent",
        sandbox_path="/bin",
        pkg_config_path="",
        allow_nix=False,
        allow_unix_sockets=False,
        allow_headless_browsers=(),
        rw_dirs=(),
        rw_files=(),
        ro_dirs=(),
        ro_files=(),
        workspace_dir="$PWD",
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
        hosts_file=Path("/nix/store/hosts"),
        empty_file=Path("/nix/store/empty"),
        dependencies=DependenciesLinux(
            git=Path("/nix/store/git/bin/git"),
            bwrap=Path("/nix/store/bwrap/bin/bwrap"),
            pasta=Path("/nix/store/passt/bin/pasta"),
            nft=Path("/nix/store/nftables/bin/nft"),
            env=Path("/nix/store/coreutils/bin/env"),
            python=Path("/nix/store/python3/bin/python3"),
            nix=None,
            certutil=None,
        ),
    )


def make_spec_darwin(
    *,
    allow_nix: bool = False,
    allow_unix_sockets: bool = False,
    env_keys: tuple[str, ...] = (),
) -> SandboxBuildSpecDarwin:
    return SandboxBuildSpecDarwin(
        version="0.0.0",
        platform="darwin",
        out_name="sandboxed-agent",
        sandbox_path="/bin",
        pkg_config_path="",
        allow_nix=allow_nix,
        allow_unix_sockets=allow_unix_sockets,
        allow_headless_browsers=(),
        rw_dirs=(),
        rw_files=(),
        ro_dirs=(),
        ro_files=(),
        workspace_dir="$PWD",
        env_keys=env_keys,
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
            nix=Path("/nix/store/nix/bin/nix") if allow_nix else None,
        ),
    )


def make_host_darwin(
    *,
    workspace_dir: Path = _HOME / "project",
    real_home: Path = _HOME,
    has_controlling_terminal: bool = False,
    declared: tuple[DeclaredPath, ...] = (),
    nix_daemon_socket: Path | None = None,
    nix_sandbox_setting: Literal["true", "false", "relaxed"] | None = None,
    nix_user_is_trusted: bool | None = None,
) -> HostStateDarwin:
    return HostStateDarwin(
        workspace_dir=workspace_dir,
        workspace_dir_exists=True,
        launch_dir=workspace_dir,
        real_home=real_home,
        uid=501,
        gid=20,
        term="xterm",
        has_controlling_terminal=has_controlling_terminal,
        declared=declared,
        git=None,
        closure_paths=(),
        nix_daemon_socket=nix_daemon_socket,
        nix_sandbox_setting=nix_sandbox_setting,
        nix_user_is_trusted=nix_user_is_trusted,
        tty=None,
    )


def make_host_linux(*, declared: tuple[DeclaredPath, ...] = ()) -> HostStateLinux:
    return HostStateLinux(
        workspace_dir=_HOME / "project",
        workspace_dir_exists=True,
        launch_dir=_HOME / "project",
        real_home=_HOME,
        uid=1000,
        gid=100,
        term="xterm",
        has_controlling_terminal=False,
        declared=declared,
        git=None,
        closure_paths=(),
        nix_daemon_socket=None,
        nix_sandbox_setting=None,
        nix_user_is_trusted=None,
        resolv_conf_names_loopback=False,
        systemd_resolv_conf=None,
        machine="x86_64",
    )


def make_session() -> SessionState:
    return SessionState(session_dir=_SESSION_DIR, proxy=None, nss_db=None, firefox_policies=None)


def make_session_darwin() -> SessionStateDarwin:
    return SessionStateDarwin(
        session_dir=_SESSION_DIR,
        proxy=None,
        nss_db=None,
        firefox_policies=None,
        sandbox_home=_SESSION_DIR / "home",
        sandbox_tmpdir=_SESSION_DIR / "tmp",
    )
