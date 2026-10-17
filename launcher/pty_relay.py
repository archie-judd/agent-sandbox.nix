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

    signal.signal(
        signal.SIGWINCH,
        lambda signum, frame: termios.tcsetwinsize(master, termios.tcgetwinsize(0)),
    )

    tty.setraw(0)
    try:
        inputs = [0, master]
        while True:
            readable, _, _ = select.select(inputs, [], [])
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

    _, status = os.waitpid(pid, 0)
    exit_code = os.waitstatus_to_exitcode(status)
    sys.exit(128 - exit_code if exit_code < 0 else exit_code)


if __name__ == "__main__":
    main()
