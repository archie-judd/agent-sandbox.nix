import errno
import json
import socket
import sys

_RESOLVER_ERRORS = {
    getattr(socket, name): name for name in dir(socket) if name.startswith("EAI_")
}


def _connect(host: str, port: int) -> None:
    socket.create_connection((host, port), timeout=3).close()


def _send_udp(host: str, port: int) -> None:
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.sendto(b"probe", (host, port))


def _resolve(host: str, port: int) -> None:
    socket.getaddrinfo(host, port)


_OPERATIONS = {"connect": _connect, "send_udp": _send_udp, "resolve": _resolve}


def _outcome(op: str, host: str, port: int) -> str:
    try:
        _OPERATIONS[op](host, port)
    except socket.gaierror as error:
        return _RESOLVER_ERRORS.get(error.errno, str(error.errno))
    except TimeoutError:
        return "timeout"
    except OSError as error:
        if error.errno is None:
            return type(error).__name__
        return errno.errorcode.get(error.errno, str(error.errno))
    return "ok"


def main() -> None:
    checks = json.loads(sys.argv[1])
    print(json.dumps([_outcome(op, host, port) for op, host, port in checks]))


if __name__ == "__main__":
    main()
