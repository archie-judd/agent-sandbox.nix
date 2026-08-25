"""What the launcher creates for this launch.

Every path here is physical, for the same reason as in host_state: these paths
become seatbelt rules and bubblewrap mount destinations, and the kernel resolves
symlinks before either is matched.

The only step with side effects. Everything here exists because we made it, which
is what distinguishes it from SandboxLaunchConfig: that is a description and owns
nothing.

The session directory is created separately and first, by create_session_dir, so
it exists before anything can refuse the launch. The per-platform
create_session_state runs only once the launch is known to be allowed, because
it starts a process.

If it fails partway it removes what it made before re-raising. The stub's EXIT
trap is only armed after prepare has printed the session directory, so nothing
else would clean up a half-built session.
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

from launcher.build_spec import (
    ProxySpec,
    SandboxBuildSpec,
    SandboxBuildSpecDarwin,
    SandboxBuildSpecLinux,
)
from launcher.constants import (
    CA_BUNDLE,
    CA_CERT,
    ERROR_PREFIX,
    PROXY_LISTEN_HOST,
    PROXY_LOG,
    PROXY_STARTUP_TIMEOUT_SECONDS,
)

SESSIONS_ROOT_OVERRIDE = "AGENT_SANDBOX_LOG_DIR"
SESSIONS_ROOT_NAME = "agent-sandbox"
DEFAULT_STATE_HOME = ".local/state"
SESSION_DIR_TIMESTAMP = "%Y%m%d-%H%M%S"
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
    session_dir: Path
    proxy: ProxyState | None


@dataclass(frozen=True, kw_only=True)
class SessionStateLinux(SessionState):
    pass


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


def create_session_dir(spec: SandboxBuildSpec, now: datetime) -> Path:
    """Create this launch's directory, before anything can refuse the launch."""
    timestamp = now.strftime(SESSION_DIR_TIMESTAMP)
    name = f"{timestamp}-{os.getpid()}-{spec.out_name}"
    session_dir = _get_sessions_root() / name
    session_dir.mkdir(parents=True, exist_ok=True)
    return Path(os.path.realpath(session_dir))


def _create_darwin_sandbox_home() -> Path:
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


def _write_ca_bundle(spec: SandboxBuildSpec, session_dir: Path) -> None:
    """System certificates plus the proxy's ephemeral CA, in one file."""
    system = spec.cacert_bundle.read_bytes()
    proxy_ca = (session_dir / CA_CERT).read_bytes()
    (session_dir / CA_BUNDLE).write_bytes(system + proxy_ca)


def _kill_proxy(proxy: ProxyState | None) -> None:
    if proxy is None:
        return
    try:
        os.kill(proxy.pid, signal.SIGKILL)
    except OSError:
        pass


def teardown_session_state_linux(session: SessionStateLinux) -> None:
    """Undo what create_session_state_linux made, from the state itself.

    Used when prepare fails after the session exists. cleanup_launch does the
    same job from the session directory instead, because by then it is a
    different process.
    """
    _kill_proxy(session.proxy)


def teardown_session_state_darwin(session: SessionStateDarwin) -> None:
    """As above, plus the ephemeral home that only macOS creates."""
    _kill_proxy(session.proxy)
    shutil.rmtree(session.sandbox_home, ignore_errors=True)


def _create_proxy_state(spec: SandboxBuildSpec, session_dir: Path) -> ProxyState | None:
    """Start the proxy and wait for the port it chose, when there is one.

    None means an unrestricted wrapper, whose spec names no proxy at all.
    """
    if spec.proxy is None:
        return None

    process = _start_proxy(spec.proxy, session_dir)
    try:
        port = _read_proxy_port(process, session_dir)
        _write_ca_bundle(spec, session_dir)
    except BaseException:
        if process.poll() is None:
            process.kill()
        raise
    return ProxyState(port=port, pid=process.pid)


def create_session_state_linux(
    spec: SandboxBuildSpecLinux, session_dir: Path
) -> SessionStateLinux:
    return SessionStateLinux(
        session_dir=session_dir, proxy=_create_proxy_state(spec, session_dir)
    )


def create_session_state_darwin(
    spec: SandboxBuildSpecDarwin, session_dir: Path
) -> SessionStateDarwin:
    sandbox_home = _create_darwin_sandbox_home()
    try:
        proxy = _create_proxy_state(spec, session_dir)
    except BaseException:
        shutil.rmtree(sandbox_home, ignore_errors=True)
        raise
    return SessionStateDarwin(
        session_dir=session_dir, proxy=proxy, sandbox_home=sandbox_home
    )
