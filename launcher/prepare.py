"""First entry point. Prints the session directory and nothing else.

The order is load-bearing. The session directory is created before anything can
refuse the launch, so a refused run still has somewhere to record why. Session
state is established before the configuration is computed, because the computed
argv and profile quote its paths and its port.

The platform is decided once, on the spec, and everything below that fold is one
platform's types throughout. It cannot fold any later: reading the host is
already platform-specific, so a fold after it would have to re-establish the
platform on the spec and the host state together, which is the thing this
replaced.
"""

import sys
from datetime import datetime
from pathlib import Path
from typing import assert_never

from launcher.lib.build_spec import (
    SandboxBuildSpecDarwin,
    SandboxBuildSpecLinux,
    load_build_spec,
)
from launcher.lib.constants import ERROR_PREFIX
from launcher.lib.host_state import read_host_state_darwin, read_host_state_linux
from launcher.lib.launch_checks import get_launch_refusals
from launcher.lib.launch_config.darwin import compute as darwin_compute
from launcher.lib.launch_config.linux import compute as linux_compute
from launcher.lib.launch_config.write import (
    write_launch_config_darwin,
    write_launch_config_linux,
)
from launcher.lib.session_state import (
    create_session_dir,
    create_session_state_darwin,
    create_session_state_linux,
    teardown_session_state_darwin,
    teardown_session_state_linux,
)


def _refuse_launch(refusals: tuple[str, ...]) -> None:
    """Report every reason and exit, or return and let the launch continue."""
    if not refusals:
        return
    for refusal in refusals:
        print(f"{ERROR_PREFIX} {refusal}", file=sys.stderr)
    raise SystemExit(1)


def _print_warnings(warnings: tuple[str, ...]) -> None:
    for warning in warnings:
        print(warning, file=sys.stderr)


def _prepare_launch_linux(spec: SandboxBuildSpecLinux, session_dir: Path) -> Path:
    host = read_host_state_linux(spec)
    _refuse_launch(get_launch_refusals(spec, host))

    session = create_session_state_linux(spec, session_dir)
    try:
        # Nothing below creates anything, but it can still raise, and by now a
        # proxy may be running that only this process knows about. The stub's
        # EXIT trap is not armed until prepare_launch has returned.
        config = linux_compute.compute_launch_config(spec, host, session)
        write_launch_config_linux(config, session)
    except BaseException:
        teardown_session_state_linux(session)
        raise

    _print_warnings(config.warnings)
    return session.session_dir


def _prepare_launch_darwin(spec: SandboxBuildSpecDarwin, session_dir: Path) -> Path:
    host = read_host_state_darwin(spec)
    _refuse_launch(get_launch_refusals(spec, host))

    session = create_session_state_darwin(spec, session_dir)
    try:
        config = darwin_compute.compute_launch_config(spec, host, session)
        write_launch_config_darwin(config, session)
    except BaseException:
        teardown_session_state_darwin(session)
        raise

    _print_warnings(config.warnings)
    return session.session_dir


def prepare_launch(spec_path: Path, now: datetime) -> Path:
    spec = load_build_spec(spec_path)
    # Ahead of the fold: it has to exist before anything can refuse the launch,
    # and its name is a function of fields both platforms share.
    session_dir = create_session_dir(spec, now)

    match spec:
        case SandboxBuildSpecLinux():
            return _prepare_launch_linux(spec, session_dir)
        case SandboxBuildSpecDarwin():
            return _prepare_launch_darwin(spec, session_dir)
        case _:
            assert_never(spec)


def main() -> None:
    print(prepare_launch(Path(sys.argv[1]), datetime.now()))


if __name__ == "__main__":
    main()
