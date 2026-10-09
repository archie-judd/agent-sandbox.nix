import errno
import json
import os
import subprocess
import sys


def _read(path: str) -> None:
    with open(path, "rb") as handle:
        handle.read(1)


def _list(path: str) -> None:
    os.listdir(path)


def _stat(path: str) -> None:
    os.stat(path)


def _write(path: str) -> None:
    with open(path, "ab"):
        pass


def _create(path: str) -> None:
    os.close(os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY))
    os.unlink(path)


def _delete(path: str) -> None:
    os.unlink(path)


def _exec(path: str) -> None:
    subprocess.run(
        [path],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        timeout=10,
    )


_OPERATIONS = {
    "read": _read,
    "list": _list,
    "stat": _stat,
    "write": _write,
    "create": _create,
    "delete": _delete,
    "exec": _exec,
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
