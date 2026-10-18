import os
import select
import signal
import sys
import termios
import tty


def main() -> None:
    saved_attrs = termios.tcgetattr(0)
    master, slave = os.openpty()
    termios.tcsetattr(slave, termios.TCSANOW, saved_attrs)
    termios.tcsetwinsize(slave, termios.tcgetwinsize(0))

    wake_r, wake_w = os.pipe()
    os.set_blocking(wake_w, False)
    signal.set_wakeup_fd(wake_w)
    signal.signal(signal.SIGCHLD, lambda signum, frame: None)
    signal.signal(
        signal.SIGWINCH,
        lambda signum, frame: termios.tcsetwinsize(master, termios.tcgetwinsize(0)),
    )
    signal.signal(signal.SIGTERM, lambda signum, frame: sys.exit(128 + signum))
    signal.signal(signal.SIGHUP, lambda signum, frame: sys.exit(128 + signum))

    pid = os.fork()
    if pid == 0:
        os.close(master)
        os.login_tty(slave)
        try:
            os.execv(sys.argv[1], sys.argv[1:])
        except OSError as error:
            print(f"{sys.argv[1]}: {error.strerror}", file=sys.stderr)
            os._exit(127)
    os.close(slave)

    status: int | None = None
    tty.setraw(0)
    try:
        inputs = [0, master, wake_r]
        while True:
            readable, _, _ = select.select(inputs, [], [])
            if wake_r in readable:
                os.read(wake_r, 512)
                if status is None:
                    waited, child_status = os.waitpid(pid, os.WNOHANG | os.WUNTRACED)
                    if waited and os.WIFSTOPPED(child_status):
                        termios.tcsetattr(0, termios.TCSAFLUSH, saved_attrs)
                        os.killpg(os.getpgrp(), signal.SIGTSTP)
                        tty.setraw(0)
                        termios.tcsetwinsize(master, termios.tcgetwinsize(0))
                        os.kill(pid, signal.SIGCONT)
                    elif waited:
                        status = child_status
            if master in readable:
                try:
                    data = os.read(master, 65536)
                except OSError:
                    data = b""
                if not data:
                    break
                while data:
                    data = data[os.write(1, data) :]
            if 0 in readable:
                data = os.read(0, 65536)
                if not data:
                    inputs.remove(0)
                while data:
                    data = data[os.write(master, data) :]
    finally:
        termios.tcsetattr(0, termios.TCSAFLUSH, saved_attrs)

    if status is None:
        _, status = os.waitpid(pid, 0)
    exit_code = os.waitstatus_to_exitcode(status)
    sys.exit(128 - exit_code if exit_code < 0 else exit_code)


if __name__ == "__main__":
    main()
