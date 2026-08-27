"""What the launch records about itself, for a person reading it afterwards.

Best effort throughout, and the only module here that is. Every other write in
the launcher is load-bearing: the stub reads the argv files, bubblewrap reads
its binds, the kernel reads the profile. This one is read after something has
already gone wrong, so failing to write it must never be why a sandbox does not
start. That inverts the convention in the surrounding code, where a missing bind
exits 1.

Written in two goes rather than buffered and written once, because prepare has
more than one exit. The request section lands before the host is read, so it
survives a refusal, a proxy that never starts, and a traceback alike; the second
section lands at whichever exit is reached, and is the outcome, the refusals, or
a traceback. The first two carry the same values that were printed to the
terminal, so everything printed is also here and the log holds more besides.

The one exit not covered is the proxy failing to report a port. That is already
recorded in proxy.log, which every one of those messages names.

The third caller is in another process: cleanup, running from the stub's EXIT
trap, records the status the sandbox exited with. Two callers in two entry
points is why the format lives here rather than in either of them.

Nothing written here is secret. Declared environment variables appear as keys
alone, because that is all the spec carries; the values are shell expressions
resolved by the stub and never enter Python. That is what keeps a session
directory safe to attach to an issue.
"""

import traceback
from datetime import datetime
from pathlib import Path
from typing import Sequence

from launcher.lib.build_spec import SandboxBuildSpecDarwin, SandboxBuildSpecLinux
from launcher.lib.host_state import DeclaredDir, DeclaredPath, HostState
from launcher.lib.session_state import SessionState, SessionStateDarwin

_TIMESTAMP = "%Y-%m-%dT%H:%M:%S"
_NONE = "(none)"
# Wide enough for the longest label below, so the values line up in a column.
_LABEL_WIDTH = 18


def _append(log_file: Path, lines: Sequence[str]) -> None:
    """Append, or give up silently.

    OSError covers the reasons this realistically fails: an unwritable or full
    filesystem, a read-only mount, a session directory removed underneath us.
    The encoding error handler covers the other one, since a path read from the
    host can hold bytes that are not valid UTF-8 and a log is not worth a
    UnicodeEncodeError.
    """
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
    """One aligned `label: value` line. Empty values leave no trailing space,
    since a line whose value is a list below it still wants the label."""
    return f"{label + ':':<{_LABEL_WIDTH}} {value}".rstrip()


def _list_field(label: str, values: Sequence[str]) -> str:
    return _field(label, ", ".join(values) if values else _NONE)


def _get_declared_label(declared: DeclaredPath) -> str:
    """The mkSandbox argument this path came from: rwDir, rwFile, roDir, roFile.

    Duplicated from launch_checks rather than shared with it. Importing either
    module into the other would tie a refusal's wording to a log's, and the log
    lists paths in a column where the refusal writes a sentence.
    """
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
    """What was asked for, written before the host is read.

    Limited to the spec and the environment on purpose. Nothing here can fail
    on a host that is about to refuse the launch, which is what makes it the
    section that survives everything after it.

    `session_dir` is recorded rather than written to, like `cwd`: the log's own
    location would answer it for someone reading the file in place, and not for
    someone reading it pasted into an issue.
    """
    if spec.allowed_local_ports is None:
        local_ports = "all host-local TCP ports"
    elif spec.allowed_local_ports:
        local_ports = ", ".join(str(port) for port in spec.allowed_local_ports)
    else:
        local_ports = _NONE

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
            _field("allowedLocalPorts", local_ports),
            # Keys only. The values are the one thing that must never land here.
            _list_field("env keys", spec.env_keys),
            _list_field("rwDirs", spec.rw_dirs),
            _list_field("rwFiles", spec.rw_files),
            _list_field("roDirs", spec.ro_dirs),
            _list_field("roFiles", spec.ro_files),
            "",
        ],
    )


def write_launch_refusals(log_file: Path, refusals: Sequence[str]) -> None:
    """Why the launch stopped, from the same tuple prepare prints."""
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
    """What the host turned out to be, and what was decided from it.

    The declared paths are the reason this section exists: an expansion that
    went somewhere unexpected is invisible in the arguments the user wrote, and
    is the first thing worth checking when a path is missing inside the sandbox.
    """
    lines = [
        _heading(None, "launch prepared"),
        _field("home", str(host.real_home)),
        _field("uid/gid", f"{host.uid}/{host.gid}"),
    ]

    # The repository as read from the host, not the one the sandbox ended up
    # with: a root at the home directory is observed here and refused in the
    # warnings below, and reporting only the decision would hide which
    # repository was refused.
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
    """The one failure nothing else records.

    Every other way out of prepare writes its own reason: a refusal writes its
    section, and the proxy failures name proxy.log. What is left is a bug in the
    launcher, a host that could not be read, or an interrupt during the
    confirmation prompt or the proxy wait, and the evidence for those existed
    only on the terminal until this was added.

    The traceback goes in verbatim rather than indented, so it can be pasted
    into an issue. It costs nothing in secrecy: format_exception renders source
    lines and exception reprs, not local variables.
    """
    lines = "".join(traceback.format_exception(error)).splitlines()
    _append(log_file, [_heading(None, "launch failed unexpectedly")] + lines + [""])


def write_sandbox_exit(log_file: Path, exit_status: int, now: datetime) -> None:
    """The status the sandbox exited with, appended by cleanup.

    It is the one fact about the run itself that the launcher can record. The
    sandboxed process's own output is never captured: it is the user's terminal,
    it holds their source and their prompts, and capturing it would cost the
    property that this directory can be attached to an issue.
    """
    _append(log_file, [_heading(now, f"sandbox exited with status {exit_status}"), ""])
