"""First entry point. Prints the session directory and nothing else: the stub
captures stdout."""

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
    create_darwin_sandbox_tmpdir,
    create_proxy_state,
    create_session_dir,
    kill_proxy,
    remove_darwin_sandbox_dir,
)


def _refuse_launch(session_dir: Path, refusals: tuple[str, ...]) -> None:
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
        # Committed: from here the proxy is cleanup_launch's to kill, off the
        # pid just written to the session directory.
        stack.pop_all()

    write_launch_outcome(session_dir / LAUNCH_LOG, host, session, config.warnings)
    _print_warnings(config.warnings)
    return session_dir


def _prepare_launch_darwin(spec: SandboxBuildSpecDarwin, session_dir: Path) -> Path:
    host = read_host_state_darwin(spec)
    _refuse_launch(session_dir, get_launch_refusals(spec, host))

    with ExitStack() as stack:
        sandbox_home = create_darwin_sandbox_home(session_dir)
        stack.callback(remove_darwin_sandbox_dir, sandbox_home)
        sandbox_tmpdir = create_darwin_sandbox_tmpdir(session_dir)
        stack.callback(remove_darwin_sandbox_dir, sandbox_tmpdir)
        proxy = create_proxy_state(spec, session_dir)
        stack.callback(kill_proxy, proxy)

        session = SessionStateDarwin(
            session_dir=session_dir,
            proxy=proxy,
            sandbox_home=sandbox_home,
            sandbox_tmpdir=sandbox_tmpdir,
        )
        config = darwin_compute.compute_launch_config(spec, host, session)
        write_launch_config_darwin(config, session)
        stack.pop_all()

    write_launch_outcome(session_dir / LAUNCH_LOG, host, session, config.warnings)
    _print_warnings(config.warnings)
    return session_dir


def prepare_launch(spec_path: Path, now: datetime) -> Path:
    spec = load_build_spec(spec_path)
    # Created before anything can refuse the launch, so a refused run still
    # has somewhere to record why.
    session_dir = create_session_dir(spec, now)
    log_file = session_dir / LAUNCH_LOG
    write_launch_request(log_file, session_dir, spec, Path(os.getcwd()), now)

    # SystemExit passes through unrecorded: a refusal has already written its
    # own section, and the proxy failures name proxy.log.
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
