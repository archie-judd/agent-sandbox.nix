import os
import pty
import signal
import subprocess
import time
from collections.abc import Callable, Iterator
from contextlib import contextmanager
from pathlib import Path
from typing import Mapping, Protocol


class Launch(Protocol):
    def __call__(
        self,
        binary: Path,
        script: str,
        *,
        cwd: Path | None = None,
        home: Path | None = None,
        env: Mapping[str, str] | None = None,
        tty_reply: str | None = None,
    ) -> subprocess.CompletedProcess[str]: ...


def _launch_env(
    cwd: Path, home: Path, sessions_root: Path, env: Mapping[str, str]
) -> dict[str, str]:
    return {
        **os.environ,
        "PWD": str(cwd),
        "HOME": str(home),
        "AGENT_SANDBOX_SESSIONS_ROOT": str(sessions_root),
        **env,
    }


def _run_on_tty(argv: list[str], cwd: Path, env: dict[str, str], reply: str) -> tuple[int, str]:
    pid, fd = pty.fork()
    if pid == 0:
        os.chdir(cwd)
        os.execve(argv[0], argv, env)
    os.write(fd, f"{reply}\n".encode())
    chunks: list[bytes] = []
    while True:
        try:
            data = os.read(fd, 4096)
        except OSError:
            break
        if not data:
            break
        chunks.append(data)
    os.close(fd)
    _, status = os.waitpid(pid, 0)
    output = b"".join(chunks).decode(errors="replace").replace("\r\n", "\n")
    return os.waitstatus_to_exitcode(status), output


def launch_sandbox(
    binary: Path,
    script: str,
    *,
    cwd: Path,
    home: Path,
    sessions_root: Path,
    env: Mapping[str, str],
    tty_reply: str | None,
) -> subprocess.CompletedProcess[str]:
    argv = [str(binary), "--norc", "--noprofile", "-c", script]
    launch_env = _launch_env(cwd, home, sessions_root, env)
    if tty_reply is not None:
        returncode, output = _run_on_tty(argv, cwd, launch_env, tty_reply)
        return subprocess.CompletedProcess(argv, returncode, output, "")
    return subprocess.run(
        argv,
        cwd=cwd,
        env=launch_env,
        stdin=subprocess.DEVNULL,
        capture_output=True,
        text=True,
        start_new_session=True,
    )


@contextmanager
def launch_background(
    binary: Path,
    script: str,
    *,
    is_ready: Callable[[], bool],
    cwd: Path,
    home: Path,
    sessions_root: Path,
    env: Mapping[str, str] | None = None,
) -> Iterator[subprocess.Popen[str]]:
    process = subprocess.Popen(
        [str(binary), "--norc", "--noprofile", "-c", script],
        cwd=cwd,
        env=_launch_env(cwd, home, sessions_root, {} if env is None else env),
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        start_new_session=True,
    )
    try:
        deadline = time.monotonic() + 30
        while True:
            if process.poll() is not None:
                output = process.stdout.read() if process.stdout else ""
                raise AssertionError(f"background sandbox exited {process.returncode}:\n{output}")
            try:
                if is_ready():
                    break
            except OSError:
                pass
            if time.monotonic() > deadline:
                raise AssertionError("background sandbox was not ready within 30s")
            time.sleep(0.1)
        yield process
    finally:
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
