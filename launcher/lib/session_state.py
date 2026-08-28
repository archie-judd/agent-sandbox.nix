import os
import re
import select
import shutil
import signal
import subprocess
import time
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path

from launcher.lib.build_spec import ProxySpec, SandboxBuildSpec
from launcher.lib.constants import (
    CA_CERT,
    ERROR_PREFIX,
    PROXY_LISTEN_HOST,
    PROXY_LOG,
    PROXY_STARTUP_TIMEOUT_SECONDS,
    SESSION_RETENTION,
    STUB_PID,
)

# Deliberately undocumented; used by the test suite. XDG_STATE_HOME is the
# supported knob.
SESSIONS_ROOT_OVERRIDE = "AGENT_SANDBOX_SESSIONS_ROOT"
SESSIONS_ROOT_NAME = "agent-sandbox"
DEFAULT_STATE_HOME = ".local/state"
SESSION_DIR_TIMESTAMP = "%Y%m%d-%H%M%S"
# Must stay in step with the name create_session_dir builds: it is what stops
# the prune from touching anything else in a shared root.
SESSION_DIR_NAME = re.compile(r"\d{8}-\d{6}-\d+-.+")
# Inside the session directory, and 0700: under a shared temp root one
# session could write into a concurrent session's HOME, which the seatbelt
# profile grants process-exec on.
SANDBOX_HOME_NAME = "home"
SANDBOX_TMPDIR_NAME = "tmp"


@dataclass(frozen=True, kw_only=True)
class ProxyState:
    port: int
    pid: int


@dataclass(frozen=True, kw_only=True)
class SessionState:
    session_dir: Path
    proxy: ProxyState | None


@dataclass(frozen=True, kw_only=True)
class SessionStateDarwin(SessionState):
    sandbox_home: Path
    sandbox_tmpdir: Path


def _get_sessions_root() -> Path:
    override = os.environ.get(SESSIONS_ROOT_OVERRIDE)
    if override:
        return Path(override)

    state_home = os.environ.get("XDG_STATE_HOME")
    if state_home:
        return Path(state_home) / SESSIONS_ROOT_NAME

    home = os.environ.get("HOME")
    if not home:
        raise SystemExit(f"{ERROR_PREFIX} HOME is not set")
    return Path(home) / DEFAULT_STATE_HOME / SESSIONS_ROOT_NAME


def _is_session_live(session_dir: Path) -> bool:
    # Both error directions fall towards live: a finished session surviving
    # until the next launch is harmless, deleting a running one is not.
    try:
        pid = int((session_dir / STUB_PID).read_text(encoding="utf-8").strip())
    except (OSError, ValueError):
        return False
    # Zero and negative pids address process groups rather than a process.
    if pid <= 0:
        return False
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def _prune_sessions_root(root: Path) -> None:
    """Keep the newest SESSION_RETENTION sessions, and every running one:
    a running session is still reading its own directory."""
    try:
        sessions = [
            entry
            for entry in root.iterdir()
            if SESSION_DIR_NAME.fullmatch(entry.name) and entry.is_dir()
        ]
    except OSError:
        return

    sessions.sort(key=lambda session: session.name, reverse=True)
    for session in sessions[SESSION_RETENTION:]:
        if _is_session_live(session):
            continue
        shutil.rmtree(session, ignore_errors=True)


def create_session_dir(spec: SandboxBuildSpec, now: datetime) -> Path:
    timestamp = now.strftime(SESSION_DIR_TIMESTAMP)
    name = f"{timestamp}-{os.getpid()}-{spec.out_name}"
    root = _get_sessions_root()
    _prune_sessions_root(root)
    session_dir = root / name
    try:
        session_dir.mkdir(parents=True, exist_ok=True)
    except OSError as error:
        raise SystemExit(
            f"{ERROR_PREFIX} could not create the session directory "
            f"{session_dir}: {error}"
        ) from error
    return Path(os.path.realpath(session_dir))


def _create_sandbox_dir(session_dir: Path, name: str) -> Path:
    directory = session_dir / name
    try:
        directory.mkdir(mode=0o700)
    except OSError as error:
        raise SystemExit(
            f"{ERROR_PREFIX} could not create {directory}: {error}"
        ) from error
    return Path(os.path.realpath(directory))


def create_darwin_sandbox_home(session_dir: Path) -> Path:
    return _create_sandbox_dir(session_dir, SANDBOX_HOME_NAME)


def create_darwin_sandbox_tmpdir(session_dir: Path) -> Path:
    return _create_sandbox_dir(session_dir, SANDBOX_TMPDIR_NAME)


def remove_darwin_sandbox_dir(directory: Path) -> None:
    shutil.rmtree(directory, ignore_errors=True)


def _start_proxy(proxy: ProxySpec, session_dir: Path) -> subprocess.Popen[str]:
    environ = dict(os.environ)
    if proxy.redirects:
        pairs = [f"{host}={address}" for host, address in proxy.redirects.items()]
        environ["SANDBOX_PROXY_REDIRECT"] = ",".join(pairs)

    log = (session_dir / PROXY_LOG).open("a", encoding="utf-8")
    argv = [
        str(proxy.binary),
        str(proxy.allowlist_file),
        str(session_dir / CA_CERT),
        PROXY_LISTEN_HOST,
    ]
    return subprocess.Popen(
        argv, stdout=subprocess.PIPE, stderr=log, text=True, env=environ
    )


def _read_proxy_port(process: subprocess.Popen[str], session_dir: Path) -> int:
    if process.stdout is None:
        raise SystemExit(f"{ERROR_PREFIX} sandbox proxy stdout was not captured")

    log = session_dir / PROXY_LOG
    deadline = time.monotonic() + PROXY_STARTUP_TIMEOUT_SECONDS
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise SystemExit(
                f"{ERROR_PREFIX} sandbox proxy did not report a port within "
                f"{PROXY_STARTUP_TIMEOUT_SECONDS:g}s (see {log})"
            )
        readable, _, _ = select.select([process.stdout], [], [], remaining)
        if readable:
            break
        if process.poll() is not None:
            raise SystemExit(
                f"{ERROR_PREFIX} sandbox proxy exited with status "
                f"{process.returncode} before reporting a port (see {log})"
            )

    # A dead child makes its pipe readable at EOF, so select above cannot
    # tell that case from a port arriving. An empty line is that EOF.
    reported = process.stdout.readline().strip()
    if not reported:
        if process.poll() is None:
            raise SystemExit(
                f"{ERROR_PREFIX} sandbox proxy closed its output without reporting "
                f"a port (see {log})"
            )
        raise SystemExit(
            f"{ERROR_PREFIX} sandbox proxy exited with status {process.returncode} "
            f"before reporting a port (see {log})"
        )
    if not re.fullmatch(r"[0-9]+", reported):
        raise SystemExit(
            f"{ERROR_PREFIX} sandbox proxy reported {reported!r} instead of a port "
            f"(see {log})"
        )
    return int(reported)


def kill_proxy(proxy: ProxyState | None) -> None:
    if proxy is None:
        return
    try:
        os.kill(proxy.pid, signal.SIGKILL)
    except OSError:
        pass


def create_proxy_state(spec: SandboxBuildSpec, session_dir: Path) -> ProxyState | None:
    if spec.proxy is None:
        return None

    process = _start_proxy(spec.proxy, session_dir)
    try:
        port = _read_proxy_port(process, session_dir)
    except BaseException:
        if process.poll() is None:
            process.kill()
        raise
    return ProxyState(port=port, pid=process.pid)
