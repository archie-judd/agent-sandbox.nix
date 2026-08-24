"""First entry point. Prints the session directory and nothing else.

The order is load-bearing. The session directory is created before anything can
refuse the launch, so a refused run still has somewhere to record why. Session
state is established before the configuration is computed, because the computed
argv and profile quote its paths and its port.
"""

import sys
from datetime import datetime
from pathlib import Path

from launcher.build_spec import (
    SandboxBuildSpecDarwin,
    SandboxBuildSpecLinux,
    load_build_spec,
)
from launcher.constants import ERROR_PREFIX
from launcher.host_state import HostStateDarwin, HostStateLinux, host_state_from_spec
from launcher.launch_checks import get_launch_refusals
from launcher.launch_config import darwin, linux
from launcher.launch_config.darwin import SandboxLaunchConfigDarwin
from launcher.launch_config.linux import SandboxLaunchConfigLinux
from launcher.launch_config.write import write_launch_config
from launcher.session_state import (
    SessionStateDarwin,
    SessionStateLinux,
    create_session_dir,
    create_session_state,
    teardown_session_state,
)


def _compute_launch_config(
    spec: SandboxBuildSpecLinux | SandboxBuildSpecDarwin,
    host: HostStateLinux | HostStateDarwin,
    session: SessionStateLinux | SessionStateDarwin,
) -> SandboxLaunchConfigLinux | SandboxLaunchConfigDarwin:
    """Dispatch to the platform that produced all three.

    The three unions are independent as far as the type checker is concerned,
    so the platform has to be re-established here rather than narrowed once.
    """
    if (
        isinstance(spec, SandboxBuildSpecLinux)
        and isinstance(host, HostStateLinux)
        and isinstance(session, SessionStateLinux)
    ):
        return linux.compute_launch_config(spec, host, session)
    if (
        isinstance(spec, SandboxBuildSpecDarwin)
        and isinstance(host, HostStateDarwin)
        and isinstance(session, SessionStateDarwin)
    ):
        return darwin.compute_launch_config(spec, host, session)
    raise SystemExit(f"{ERROR_PREFIX} internal: platform types do not agree")


def prepare_launch(spec_path: Path, now: datetime) -> Path:
    spec = load_build_spec(spec_path)
    session_dir = create_session_dir(spec, now)

    host = host_state_from_spec(spec)
    refusals = get_launch_refusals(spec, host)
    if refusals:
        for refusal in refusals:
            print(f"{ERROR_PREFIX} {refusal}", file=sys.stderr)
        raise SystemExit(1)

    session = create_session_state(spec, session_dir)
    try:
        # Nothing below creates anything, but it can still raise, and by now a
        # proxy may be running that only this process knows about. The stub's
        # EXIT trap is not armed until this function has returned.
        config = _compute_launch_config(spec, host, session)
        write_launch_config(config, session)
    except BaseException:
        teardown_session_state(session)
        raise

    for warning in config.warnings:
        print(warning, file=sys.stderr)
    return session.session_dir


def main() -> None:
    print(prepare_launch(Path(sys.argv[1]), datetime.now()))


if __name__ == "__main__":
    main()
