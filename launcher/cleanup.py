"""Second entry point, called from the stub's EXIT trap.

Runs in a different process from the one that built the session, so everything
it needs comes off disk. Best effort throughout: the sandbox has already exited
by the time this runs, and failing here would turn a successful run into a
failed one for no gain.

The session directory itself survives. It holds the computed configuration and
the proxy log, which is the point of having it.
"""

import os
import shutil
import signal
import sys
from pathlib import Path

from launcher.lib.constants import CLEANUP, CLEANUP_IF_EMPTY, PROXY_PID


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


def cleanup_launch(session_dir: Path) -> None:
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
    cleanup_launch(Path(sys.argv[1]))


if __name__ == "__main__":
    main()
