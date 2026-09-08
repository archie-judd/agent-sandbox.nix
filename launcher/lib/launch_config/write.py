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
from launcher.lib.launch_config.shared import NIX_STORE, SandboxLaunchConfig
from launcher.lib.session_state import SessionState, SessionStateDarwin

NIX_STORE_TMPFS_LINE = f"--tmpfs {NIX_STORE}"
CLOSURE_HEADER = "# nix store closure"
CLOSURE_FOOTER = "# end nix store closure"


def _as_json_value(value: object) -> str:
    # `default=str` would silently serialise a future non-Path field as its
    # repr; refusing is safer.
    if isinstance(value, Path):
        return str(value)
    raise TypeError(f"cannot serialise {type(value).__name__} into {NETWORK}")


def _write_nul_separated(path: Path, values: Sequence[str]) -> None:
    # NUL rather than newline: a path may contain a newline.
    path.write_bytes(b"".join(value.encode() + b"\0" for value in values))


def _write_newline_separated(path: Path, lines: Sequence[str]) -> None:
    path.write_text("".join(f"{line}\n" for line in lines), encoding="utf-8")


def _write_concatenated(path: Path, sources: Sequence[Path]) -> None:
    # Bytes, not text: these are certificates, and re-encoding could alter
    # them.
    path.write_bytes(b"".join(source.read_bytes() for source in sources))


def _group_by_option(args: Sequence[str]) -> list[str]:
    """One bubblewrap option and its operands per line."""
    lines: list[str] = []
    for arg in args:
        if not lines or arg.startswith("--"):
            lines.append(arg)
        else:
            lines[-1] += f" {arg}"
    return lines


def _is_closure_bind(line: str) -> bool:
    """A store path bound read-only at itself, and nothing else."""
    parts = line.split(" ")
    return (
        len(parts) == 3
        and parts[0] == "--ro-bind"
        and parts[1] == parts[2]
        and parts[1].startswith(f"{NIX_STORE}/")
    )


def format_bwrap_args(args: Sequence[str]) -> list[str]:
    """The argument list as something worth scrolling through.

    The closure binds are the great majority of the list and almost never what
    is being looked for, so they are marked off to be skipped past.
    """
    lines = _group_by_option(args)
    if NIX_STORE_TMPFS_LINE not in lines:
        return lines

    start = lines.index(NIX_STORE_TMPFS_LINE) + 1
    end = start
    while end < len(lines) and _is_closure_bind(lines[end]):
        end += 1
    if end == start:
        return lines

    return [
        *lines[:start],
        f"{CLOSURE_HEADER} ({end - start} paths)",
        *lines[start:end],
        CLOSURE_FOOTER,
        *lines[end:],
    ]


def _write_common(config: SandboxLaunchConfig, session: SessionState) -> None:
    session_dir = session.session_dir
    _write_nul_separated(session_dir / ARGV_BEFORE_ENV, config.argv_before_env)
    _write_nul_separated(session_dir / ARGV_AFTER_ENV, config.argv_after_env)
    _write_newline_separated(session_dir / PASSWD, [config.passwd.rstrip("\n")])
    _write_nul_separated(session_dir / CLEANUP, [str(path) for path in config.cleanup])
    _write_nul_separated(
        session_dir / CLEANUP_IF_EMPTY, [str(path) for path in config.cleanup_if_empty]
    )

    # One of the sources is written by the proxy, into this same directory,
    # so this cannot run before the proxy has reported its port.
    if config.ca_bundle:
        _write_concatenated(session_dir / CA_BUNDLE, config.ca_bundle)

    if session.proxy is not None:
        (session_dir / PROXY_PID).write_text(f"{session.proxy.pid}\n", encoding="utf-8")


def write_launch_config_linux(
    config: SandboxLaunchConfigLinux, session: SessionState
) -> None:
    _write_common(config, session)

    # For a person to read, not for bubblewrap, which gets these inline in
    # argv-after-env. Written from the same tuple, so the two cannot
    # disagree.
    _write_newline_separated(
        session.session_dir / BWRAP_ARGS, format_bwrap_args(config.bwrap_args)
    )

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
