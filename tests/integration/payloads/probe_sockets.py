import errno
import json
import os
import socket
import sys


def _create(path: str) -> None:
    socket.socket(socket.AF_UNIX, socket.SOCK_STREAM).close()


def _create_dgram(path: str) -> None:
    socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM).close()


def _socketpair(path: str) -> None:
    first, second = socket.socketpair()
    with first, second:
        first.sendall(b"x")
        if second.recv(1) != b"x":
            raise OSError(errno.EIO, "socketpair lost a byte")


def _inet(path: str) -> None:
    socket.socket(socket.AF_INET, socket.SOCK_STREAM).close()


def _roundtrip(path: str) -> None:
    if os.path.lexists(path):
        os.unlink(path)
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        server.bind(path)
        server.listen(1)
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
            client.connect(path)
            connection, _ = server.accept()
            with connection:
                client.sendall(b"x")
                if connection.recv(1) != b"x":
                    raise OSError(errno.EIO, "round trip lost a byte")
    finally:
        server.close()
        if os.path.lexists(path):
            os.unlink(path)


def _bind(path: str) -> None:
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
        sock.bind(path)
    os.unlink(path)


def _connect(path: str) -> None:
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
        sock.connect(path)


_OPERATIONS = {
    "create": _create,
    "create_dgram": _create_dgram,
    "socketpair": _socketpair,
    "inet": _inet,
    "roundtrip": _roundtrip,
    "bind": _bind,
    "connect": _connect,
}


def _outcome(op: str, path: str) -> str:
    try:
        _OPERATIONS[op](os.path.expandvars(path))
    except OSError as error:
        if error.errno is None:
            return type(error).__name__
        return errno.errorcode.get(error.errno, str(error.errno))
    return "ok"


def main() -> None:
    checks = json.loads(sys.argv[1])
    print(json.dumps([_outcome(op, path) for op, path in checks]))


if __name__ == "__main__":
    main()
