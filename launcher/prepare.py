"""First entry point. Prints the session directory and nothing else.

The order is load-bearing. The session directory is created before anything can
refuse the launch, so a refused run still has somewhere to record why. The rest
of the session is acquired before the configuration is computed, because the
computed argv and profile quote its paths and its port.

Owning that order is this module's job, which is why the acquisitions are called
one at a time here rather than bundled behind one function in session_state. It
is also where the rollback lives: each acquisition registers the call that undoes
it, and pop_all discards the lot once the launch is committed. Everything between
the first acquisition and that commit is unwound on any exception, including
KeyboardInterrupt, because nothing else would. The stub's EXIT trap is not armed
until prepare_launch has returned.

The platform is decided once, on the spec, and everything below that fold is one
platform's types throughout. It cannot fold any later: reading the host is
already platform-specific, so a fold after it would have to re-establish the
platform on the spec and the host state together, which is the thing this
replaced.
"""

import os
import sys
from contextlib import ExitStack
from datetime import datetime
from pathlib import Path
from typing import assert_never

from launcher.lib.build_spec import (
    SandboxBuildSpecDarwin,
    SandboxBuildSpecLinux,
    load_build_spec,
)
from launcher.lib.constants import ERROR_PREFIX, LAUNCH_LOG
from launcher.lib.host_state import read_host_state_darwin, read_host_state_linux
from launcher.lib.launch_checks import get_launch_refusals
from launcher.lib.launch_config.darwin import compute as darwin_compute
from launcher.lib.launch_config.linux import compute as linux_compute
from launcher.lib.launch_config.write import (
    write_launch_config_darwin,
    write_launch_config_linux,
)
from launcher.lib.launch_log import (
    write_launch_crash,
    write_launch_outcome,
    write_launch_refusals,
    write_launch_request,
)
from launcher.lib.session_state import (
    SessionState,
    SessionStateDarwin,
    create_darwin_sandbox_home,
    create_proxy_state,
    create_session_dir,
    kill_proxy,
    remove_darwin_sandbox_home,
)


def _refuse_launch(session_dir: Path, refusals: tuple[str, ...]) -> None:
    """Report every reason and exit, or return and let the launch continue.

    The session directory is named on the way out. It is the one moment the
    wrapper mentions it, and the moment someone has a reason to look: nothing
    is printed about it on a successful launch.
    """
    if not refusals:
        return
    write_launch_refusals(session_dir / LAUNCH_LOG, refusals)
    for refusal in refusals:
        print(f"{ERROR_PREFIX} {refusal}", file=sys.stderr)
    print(f"{ERROR_PREFIX} this launch was recorded in {session_dir}", file=sys.stderr)
    raise SystemExit(1)


def _print_warnings(warnings: tuple[str, ...]) -> None:
    for warning in warnings:
        print(warning, file=sys.stderr)


def _prepare_launch_linux(spec: SandboxBuildSpecLinux, session_dir: Path) -> Path:
    host = read_host_state_linux(spec)
    _refuse_launch(session_dir, get_launch_refusals(spec, host))

    with ExitStack() as stack:
        proxy = create_proxy_state(spec, session_dir)
        stack.callback(kill_proxy, proxy)

        session = SessionState(session_dir=session_dir, proxy=proxy)
        config = linux_compute.compute_launch_config(spec, host, session)
        write_launch_config_linux(config, session)
        # Committed: the proxy has to outlive this process, and from here it is
        # cleanup_launch's to kill, off the pid just written to the session
        # directory.
        stack.pop_all()

    write_launch_outcome(session_dir / LAUNCH_LOG, host, session, config.warnings)
    _print_warnings(config.warnings)
    return session_dir


def _prepare_launch_darwin(spec: SandboxBuildSpecDarwin, session_dir: Path) -> Path:
    host = read_host_state_darwin(spec)
    _refuse_launch(session_dir, get_launch_refusals(spec, host))

    with ExitStack() as stack:
        sandbox_home = create_darwin_sandbox_home()
        stack.callback(remove_darwin_sandbox_home, sandbox_home)
        proxy = create_proxy_state(spec, session_dir)
        stack.callback(kill_proxy, proxy)

        session = SessionStateDarwin(
            session_dir=session_dir, proxy=proxy, sandbox_home=sandbox_home
        )
        config = darwin_compute.compute_launch_config(spec, host, session)
        write_launch_config_darwin(config, session)
        # As above. The sandbox home outlives this process too; the config lists
        # it for removal at exit.
        stack.pop_all()

    write_launch_outcome(session_dir / LAUNCH_LOG, host, session, config.warnings)
    _print_warnings(config.warnings)
    return session_dir


def prepare_launch(spec_path: Path, now: datetime) -> Path:
    spec = load_build_spec(spec_path)
    # Ahead of the fold: it has to exist before anything can refuse the launch,
    # and its name is a function of fields both platforms share.
    session_dir = create_session_dir(spec, now)
    log_file = session_dir / LAUNCH_LOG
    # Ahead of the fold too, and of reading the host, so that whatever happens
    # next has somewhere to be recorded against. os.getcwd() rather than
    # host.cwd for the same reason: the host has not been read yet.
    write_launch_request(log_file, session_dir, spec, Path(os.getcwd()), now)

    # SystemExit passes through unrecorded on purpose: a refusal has already
    # written its own section, and the proxy failures name proxy.log. What is
    # left is a bug here, a host that could not be read, or an interrupt, none
    # of which is recorded anywhere but the terminal.
    try:
        match spec:
            case SandboxBuildSpecLinux():
                return _prepare_launch_linux(spec, session_dir)
            case SandboxBuildSpecDarwin():
                return _prepare_launch_darwin(spec, session_dir)
            case _:
                assert_never(spec)
    except (Exception, KeyboardInterrupt) as error:
        write_launch_crash(log_file, error)
        raise


def main() -> None:
    print(prepare_launch(Path(sys.argv[1]), datetime.now()))


if __name__ == "__main__":
    main()
