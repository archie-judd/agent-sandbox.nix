"""Second entry point, called from the stub's EXIT trap.

Runs in a different process from the one that built the session, so everything
it needs comes off disk. Best effort throughout: the sandbox has already exited
by the time this runs, and failing here would turn a successful run into a
failed one for no gain.

The session directory itself survives. It holds the computed configuration and
both logs, which is the point of having it.
"""

import os
import shutil
import signal
import sys
from datetime import datetime
from pathlib import Path

from launcher.lib.constants import CLEANUP, CLEANUP_IF_EMPTY, LAUNCH_LOG, PROXY_PID
from launcher.lib.launch_log import write_sandbox_exit


def _read_nul(path: Path) -> list[Path]:
    try:
        raw = path.read_bytes()
    except OSError:
        return []
    return [Path(entry.decode()) for entry in raw.split(b"\0") if entry]


def _kill_proxy(session_dir: Path) -> None:
    try:
        pid = int((session_dir / PROXY_PID).read_text(encoding="utf-8").strip())
    except (OSError, ValueError):
        return
    try:
        os.kill(pid, signal.SIGKILL)
    except OSError:
        # Already gone, most often because Ctrl-C reached the whole process
        # group, which includes the proxy.
        pass


def cleanup_launch(session_dir: Path, exit_status: int | None, now: datetime) -> None:
    """Tear the session down, and record what the sandbox exited with.

    The status comes from the stub's EXIT trap, which is the only thing that
    sees it: this process is started by the trap, so it cannot observe the
    sandbox itself. None means nobody passed one, which is a cleanup run by
    hand rather than by the trap.
    """
    if exit_status is not None:
        write_sandbox_exit(session_dir / LAUNCH_LOG, exit_status, now)

    _kill_proxy(session_dir)

    for path in _read_nul(session_dir / CLEANUP):
        shutil.rmtree(path, ignore_errors=True)
        try:
            path.unlink()
        except OSError:
            pass

    # Bubblewrap materialises a mount destination on the host, so a path bound
    # over to make it read-only has to go. If something wrote real content there
    # in the meantime, it is not ours to delete.
    for path in _read_nul(session_dir / CLEANUP_IF_EMPTY):
        try:
            if path.stat().st_size == 0:
                path.unlink()
        except OSError:
            pass


def main() -> None:
    # A status that is not a number is treated as absent rather than fatal:
    # this runs from an EXIT trap, where raising would replace the sandbox's
    # own exit status with a traceback.
    exit_status = None
    if len(sys.argv) > 2:
        try:
            exit_status = int(sys.argv[2])
        except ValueError:
            exit_status = None
    cleanup_launch(Path(sys.argv[1]), exit_status, datetime.now())


if __name__ == "__main__":
    main()
