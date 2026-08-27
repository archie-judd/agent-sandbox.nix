"""The only step that knows a file format.

Separate from shared.py because it has to see both platform configurations, and
both of those import the base from shared: putting the writer there would make
the imports circular.

Every separator is chosen here and nowhere else. The argv files and both cleanup
lists are NUL-separated, because a path may contain a newline and nothing
downstream re-splits a NUL-separated field. The bubblewrap arguments are the one
exception, for the reason given where they are written.
"""

import json
import os
from dataclasses import asdict
from pathlib import Path
from typing import Sequence

from launcher.lib.constants import (
    ARGV_AFTER_ENV,
    ARGV_BEFORE_ENV,
    BWRAP_ARGS,
    CA_BUNDLE,
    CLEANUP,
    CLEANUP_IF_EMPTY,
    NETWORK,
    PASSWD,
    PROXY_PID,
    SEATBELT_PROFILE,
    SECCOMP_FILTER,
)
from launcher.lib.launch_config.darwin.compute import SandboxLaunchConfigDarwin
from launcher.lib.launch_config.linux.compute import SandboxLaunchConfigLinux
from launcher.lib.launch_config.shared import SandboxLaunchConfig
from launcher.lib.session_state import SessionState, SessionStateDarwin


def _as_json_value(value: object) -> str:
    """Serialise a Path, and refuse anything else.

    json.dumps accepts any callable here, and `default=str` would work today,
    because every non-primitive field of NetworkConfig is a Path. It would also
    silently turn a field of some future type into its repr and write that into
    the artifact, so this refuses instead.
    """
    if isinstance(value, Path):
        return str(value)
    raise TypeError(f"cannot serialise {type(value).__name__} into {NETWORK}")


def _write_nul_separated(path: Path, values: Sequence[str]) -> None:
    path.write_bytes(b"".join(value.encode() + b"\0" for value in values))


def _write_newline_separated(path: Path, lines: Sequence[str]) -> None:
    path.write_text("".join(f"{line}\n" for line in lines), encoding="utf-8")


def _write_concatenated(path: Path, sources: Sequence[Path]) -> None:
    """Bytes, not text: these are certificates, and re-encoding could alter them."""
    path.write_bytes(b"".join(source.read_bytes() for source in sources))


def _write_common(config: SandboxLaunchConfig, session: SessionState) -> None:
    session_dir = session.session_dir
    _write_nul_separated(session_dir / ARGV_BEFORE_ENV, config.argv_before_env)
    _write_nul_separated(session_dir / ARGV_AFTER_ENV, config.argv_after_env)
    _write_newline_separated(session_dir / PASSWD, [config.passwd.rstrip("\n")])
    _write_nul_separated(session_dir / CLEANUP, [str(path) for path in config.cleanup])
    _write_nul_separated(
        session_dir / CLEANUP_IF_EMPTY, [str(path) for path in config.cleanup_if_empty]
    )

    # One of the sources is written by the proxy, into this same directory, so
    # this cannot run before the proxy has reported its port.
    if config.ca_bundle:
        _write_concatenated(session_dir / CA_BUNDLE, config.ca_bundle)

    # Recorded because the process that starts the proxy and the process that
    # kills it never share memory: prepare exits, the proxy is reparented, and
    # cleanup runs later from the stub's EXIT trap.
    if session.proxy is not None:
        (session_dir / PROXY_PID).write_text(f"{session.proxy.pid}\n", encoding="utf-8")


def write_launch_config_linux(
    config: SandboxLaunchConfigLinux, session: SessionState
) -> None:
    _write_common(config, session)

    # For reading, not for bubblewrap, which gets these inline in argv-after-env.
    # Written from the same tuple, so the two cannot disagree, and worth its own
    # file because the bind list on its own is what you want to look at when a
    # path is missing inside the sandbox.
    #
    # Newline-separated, unlike everything else here holding paths. Nothing
    # re-splits this file, so the separator answers to the reader rather than to
    # a parser, and NUL makes it one run-on line under cat. An argument holding
    # a newline is ambiguous here as a result; argv-after-env is the copy that
    # has to be right about that, and it is.
    _write_newline_separated(session.session_dir / BWRAP_ARGS, config.bwrap_args)

    # Bytes: it is a compiled BPF program, read back by apply_network_rules
    # at the path network.json carries.
    if config.seccomp_program is not None:
        (session.session_dir / SECCOMP_FILTER).write_bytes(config.seccomp_program)
    (session.session_dir / NETWORK).write_text(
        json.dumps(asdict(config.network), default=_as_json_value, indent=2) + "\n",
        encoding="utf-8",
    )


def write_launch_config_darwin(
    config: SandboxLaunchConfigDarwin, session: SessionStateDarwin
) -> None:
    _write_common(config, session)
    _write_newline_separated(
        session.session_dir / SEATBELT_PROFILE, config.seatbelt_profile_lines
    )
    for link, target in config.home_symlinks:
        link.parent.mkdir(parents=True, exist_ok=True)
        os.symlink(target, link)
