"""What the launcher acquires for this launch, and how to give each piece back.

Every path here is physical, for the same reason as in host_state: these paths
become seatbelt rules and bubblewrap mount destinations, and the kernel resolves
symlinks before either is matched.

The only step with side effects. Everything here exists because we made it, which
is what distinguishes it from SandboxLaunchConfig: that is a description and owns
nothing.

Each acquisition is a function of its own, paired with the one that undoes it:
create_session_dir, create_darwin_sandbox_home / remove_darwin_sandbox_home,
create_proxy_state / kill_proxy. Nothing here decides when they run or in what
order. prepare registers each rollback as it acquires and discards them all once
the launch is committed, which is why no function here unwinds anything but its
own half-finished work.

SessionState is the value those pieces are collected into once they all exist.
It is what compute reads, and it creates nothing itself.

The three do not share a lifecycle. The session directory is created first, by
create_session_dir, so it exists before anything can refuse the launch. The other
two run only once the launch is known to be allowed, because they cost a
directory and a process.

The stub's EXIT trap is only armed after prepare has printed the session
directory, so until then nothing else would clean up a half-built session.

The one exception to all of that is _prune_sessions_root, which gives back what
earlier launches acquired rather than anything belonging to this one. Session
directories survive their own run on purpose, so something has to bound them.
"""

import os
import re
import select
import shutil
import signal
import subprocess
import tempfile
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

# Deliberately undocumented, and used by the test suite to point a launch at a
# scratch root. XDG_STATE_HOME below is the knob a user has, and honouring it is
# what the convention asks for; a second documented one would be a compatibility
# promise bought for a case that convention already covers.
SESSIONS_ROOT_OVERRIDE = "AGENT_SANDBOX_SESSIONS_ROOT"
SESSIONS_ROOT_NAME = "agent-sandbox"
DEFAULT_STATE_HOME = ".local/state"
SESSION_DIR_TIMESTAMP = "%Y%m%d-%H%M%S"
# Has to stay in step with the name create_session_dir builds. It is what stops
# the prune from touching anything else, since the sessions root can be pointed
# at a shared directory through SESSIONS_ROOT_OVERRIDE.
SESSION_DIR_NAME = re.compile(r"\d{8}-\d{6}-\d+-.+")
SANDBOX_HOME_PREFIX = "sandbox-home."
# macOS only, and deliberately not inside the session directory: the sessions
# root lives under the real home, and putting the sandbox HOME there would
# change what (allow file-read* process-exec (subpath (param "HOME"))) grants.
DARWIN_SANDBOX_HOME_PARENT = Path("/private/tmp")


@dataclass(frozen=True, kw_only=True)
class ProxyState:
    # Nested for the same reason as ProxySpec: both fields are present or absent
    # together, and that is the restricted-versus-open distinction.
    port: int
    pid: int


@dataclass(frozen=True, kw_only=True)
class SessionState:
    """What Linux acquires, and the part macOS shares."""

    session_dir: Path
    proxy: ProxyState | None


@dataclass(frozen=True, kw_only=True)
class SessionStateDarwin(SessionState):
    sandbox_home: Path


def _get_sessions_root() -> Path:
    """The directory holding one directory per launch."""
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
    """Whether the stub that created this session is still running.

    The stub does not exec, so it is the sandbox's parent for the whole session
    and its liveness is the session's. Anything written by an older wrapper, or
    left behind by a stub that died before writing, reads as finished.

    Both error directions fall the same way. A pid recycled onto an unrelated
    process makes a finished session look live, so its directory survives until
    the next launch looks again; nothing here can report a running session as
    finished, which is the answer that would do damage.
    """
    try:
        pid = int((session_dir / STUB_PID).read_text(encoding="utf-8").strip())
    except (OSError, ValueError):
        return False
    # Zero and negative pids address process groups rather than a process.
    if pid <= 0:
        return False
    try:
        # Signal 0 delivers nothing: kill(2) performs its existence and
        # permission checks and returns.
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        # It exists and belongs to someone else, which for a same-user sessions
        # root should not happen. Live is the conservative reading.
        return True
    return True


def _prune_sessions_root(root: Path) -> None:
    """Keep the newest SESSION_RETENTION sessions, and every running one.

    Best effort, unlike the rest of this module: an unreadable root or a failed
    removal leaves the launch to continue normally, because losing an old
    directory is not worth refusing to start a sandbox over.

    A running session is skipped rather than counted against the limit, so the
    root can exceed it by however many sandboxes are open at once. Deleting one
    would take the CA bundle out from under a running agent on macOS, where
    SSL_CERT_FILE points into the session directory itself, and would strand the
    proxy and the mount points its EXIT trap reads from disk on both platforms.
    """
    try:
        sessions = [
            entry
            for entry in root.iterdir()
            if SESSION_DIR_NAME.fullmatch(entry.name) and entry.is_dir()
        ]
    except OSError:
        return

    # The timestamp leads the name, so name order is age order.
    sessions.sort(key=lambda session: session.name, reverse=True)
    for session in sessions[SESSION_RETENTION:]:
        if _is_session_live(session):
            continue
        shutil.rmtree(session, ignore_errors=True)


def create_session_dir(spec: SandboxBuildSpec, now: datetime) -> Path:
    """Create this launch's directory, before anything can refuse the launch."""
    timestamp = now.strftime(SESSION_DIR_TIMESTAMP)
    name = f"{timestamp}-{os.getpid()}-{spec.out_name}"
    root = _get_sessions_root()
    # Ahead of the mkdir so this launch's own directory is never a candidate.
    _prune_sessions_root(root)
    session_dir = root / name
    try:
        session_dir.mkdir(parents=True, exist_ok=True)
    except OSError as error:
        # Fatal, unlike the log this directory also holds. The stub reads its
        # argv from here and the kernel reads the profile from here, so an
        # unwritable root is a launch that cannot be assembled rather than a
        # launch that goes unrecorded.
        raise SystemExit(
            f"{ERROR_PREFIX} could not create the session directory "
            f"{session_dir}: {error}. It holds this launch's computed "
            f"configuration, so the sandbox cannot start without it."
        ) from error
    return Path(os.path.realpath(session_dir))


def create_darwin_sandbox_home() -> Path:
    """The ephemeral HOME macOS gives the sandbox.

    Linux gets a tmpfs from bubblewrap and needs nothing here. On macOS the
    rm -rf at exit is the only thing making it ephemeral.

    Resolved because it is compared against and turned into seatbelt rules, and
    /tmp is a symlink to /private/tmp.
    """
    created = tempfile.mkdtemp(
        prefix=SANDBOX_HOME_PREFIX, dir=str(DARWIN_SANDBOX_HOME_PARENT)
    )
    return Path(os.path.realpath(created))


def remove_darwin_sandbox_home(sandbox_home: Path) -> None:
    """Undo create_darwin_sandbox_home. Best effort, like every rollback here:
    it runs while another failure is propagating and must not mask it."""
    shutil.rmtree(sandbox_home, ignore_errors=True)


def _start_proxy(proxy: ProxySpec, session_dir: Path) -> subprocess.Popen[str]:
    """Launch the proxy, with its stderr going to the session directory.

    It binds :0 and prints the port it got, so nothing here hands it one. That
    keeps the port owned by a listening socket from the moment it exists, so the
    localhost grant in the computed profile cannot be claimed by anything else
    between computing it and launching.
    """
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
    """Wait for the proxy to report its port, separating the failure modes.

    A slow start and a dead child are indistinguishable to a plain read timeout,
    which is all the bash could manage. Polling the process tells them apart, so
    the message says which happened.
    """
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

    # A dead child makes its pipe readable at EOF, so select above cannot tell
    # that case from a port arriving. An empty line is that EOF.
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
    """Undo create_proxy_state. None is the unrestricted case and needs nothing.

    cleanup_launch does the same job from the recorded pid instead, because by
    then it is a different process with no ProxyState to read.
    """
    if proxy is None:
        return
    try:
        os.kill(proxy.pid, signal.SIGKILL)
    except OSError:
        pass


def create_proxy_state(spec: SandboxBuildSpec, session_dir: Path) -> ProxyState | None:
    """Start the proxy and wait for the port it chose, when there is one.

    None means an unrestricted wrapper, whose spec names no proxy at all.

    The process it spawns is its own to clean up until it has a ProxyState to
    return, since until then there is nothing for the caller to register a
    rollback against.
    """
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
