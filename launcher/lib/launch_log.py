"""Appends to launch.log. Best effort throughout, unlike every other write in
the launcher: failing to log must never be why a sandbox does not start."""

import traceback
from datetime import datetime
from pathlib import Path
from typing import Sequence

from launcher.lib.build_spec import SandboxBuildSpecDarwin, SandboxBuildSpecLinux
from launcher.lib.host_state import DeclaredDir, DeclaredPath, HostState
from launcher.lib.session_state import SessionState, SessionStateDarwin

_TIMESTAMP = "%Y-%m-%dT%H:%M:%S"
_NONE = "(none)"
_LABEL_WIDTH = 18


def _append(log_file: Path, lines: Sequence[str]) -> None:
    # backslashreplace because a path read from the host can hold bytes that
    # are not valid UTF-8, and a log is not worth a UnicodeEncodeError.
    try:
        with log_file.open("a", encoding="utf-8", errors="backslashreplace") as log:
            log.write("".join(f"{line}\n" for line in lines))
    except OSError:
        pass


def _heading(now: datetime | None, title: str) -> str:
    if now is None:
        return f"=== {title} ==="
    return f"=== {now.strftime(_TIMESTAMP)} {title} ==="


def _field(label: str, value: str) -> str:
    return f"{label + ':':<{_LABEL_WIDTH}} {value}".rstrip()


def _list_field(label: str, values: Sequence[str]) -> str:
    return _field(label, ", ".join(values) if values else _NONE)


def _get_declared_label(declared: DeclaredPath) -> str:
    if isinstance(declared, DeclaredDir):
        return f"{declared.mode}Dir"
    return f"{declared.mode}File"


def write_launch_request(
    log_file: Path,
    session_dir: Path,
    spec: SandboxBuildSpecLinux | SandboxBuildSpecDarwin,
    cwd: Path,
    now: datetime,
) -> None:
    """Written before the host is read, so it survives everything after it."""
    if spec.allowed_host_ports is None:
        host_ports = "all host-local TCP ports"
    elif spec.allowed_host_ports:
        host_ports = ", ".join(str(port) for port in spec.allowed_host_ports)
    else:
        host_ports = _NONE

    if spec.published_ports:
        published_ports = ", ".join(
            f"{forward.bind_addr}/{forward.port}"
            for forward in spec.published_ports
        )
    else:
        published_ports = _NONE

    if spec.proxy is None:
        network = "unrestricted"
    else:
        network = f"restricted (allowlist {spec.proxy.allowlist_file})"

    _append(
        log_file,
        [
            _heading(now, f"{spec.out_name} launch requested"),
            _field("session", str(session_dir)),
            _field("launch directory", str(cwd)),
            _field("version", spec.version),
            _field("platform", spec.platform),
            _field("network", network),
            _field("allowNix", str(spec.allow_nix).lower()),
            _field("allowUnixSockets", str(spec.allow_unix_sockets).lower()),
            _field("allowedHostPorts", host_ports),
            _field("publishedPorts", published_ports),
            # Keys only. The values must never land here: keeping them out is
            # what makes a session directory safe to attach to an issue.
            _list_field("env keys", spec.env_keys),
            _list_field("rwDirs", spec.rw_dirs),
            _list_field("rwFiles", spec.rw_files),
            _list_field("roDirs", spec.ro_dirs),
            _list_field("roFiles", spec.ro_files),
            "",
        ],
    )


def write_launch_refusals(log_file: Path, refusals: Sequence[str]) -> None:
    _append(
        log_file,
        [_heading(None, "launch refused")]
        + [f"  {refusal}" for refusal in refusals]
        + [""],
    )


def write_launch_outcome(
    log_file: Path,
    host: HostState,
    session: SessionState,
    warnings: Sequence[str],
) -> None:
    lines = [
        _heading(None, "launch prepared"),
        _field("home", str(host.real_home)),
        _field("uid/gid", f"{host.uid}/{host.gid}"),
    ]

    if host.git is None:
        lines.append(_field("git repository", _NONE))
    else:
        lines.append(
            _field(
                "git repository",
                f"{host.git.repo_root} (git dir {host.git.common_dir})",
            )
        )

    if session.proxy is None:
        lines.append(_field("proxy", _NONE))
    else:
        lines.append(
            _field("proxy", f"port {session.proxy.port} (pid {session.proxy.pid})")
        )

    if isinstance(session, SessionStateDarwin):
        lines.append(_field("sandbox home", str(session.sandbox_home)))
        lines.append(_field("sandbox tmpdir", str(session.sandbox_tmpdir)))

    lines.append(_field("declared paths", _NONE if not host.declared else ""))
    for declared in host.declared:
        lines.append(
            f"  {_get_declared_label(declared):<7}"
            f"{declared.unexpanded_path} -> {declared.expanded_path}"
        )

    if warnings:
        lines.append(_field("warnings", ""))
        lines += [f"  {warning}" for warning in warnings]

    _append(log_file, lines + [""])


def write_launch_crash(log_file: Path, error: BaseException) -> None:
    # format_exception renders source lines and exception reprs, not local
    # variables, so nothing secret lands here.
    lines = "".join(traceback.format_exception(error)).splitlines()
    _append(log_file, [_heading(None, "launch failed unexpectedly")] + lines + [""])


def write_sandbox_exit(log_file: Path, exit_status: int, now: datetime) -> None:
    _append(log_file, [_heading(now, f"sandbox exited with status {exit_status}"), ""])
