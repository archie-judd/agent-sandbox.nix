import json
import shlex
from pathlib import Path
from typing import Literal, Sequence

from harness.launch import Launch

PathOp = Literal["read", "list", "stat", "write", "create", "delete", "exec"]
NetworkOp = Literal["connect", "send_udp", "resolve"]
SocketOp = Literal[
    "create", "create_dgram", "socketpair", "inet", "roundtrip", "bind", "connect"
]

_PAYLOADS = Path(__file__).resolve().parent.parent / "integration" / "payloads"


def _run_probe(
    launch: Launch,
    binary: Path,
    payload: str,
    request: list[list[object]],
    *,
    cwd: Path | None,
    home: Path | None,
) -> list[str]:
    source = (_PAYLOADS / payload).read_text()
    script = f"python3 -c {shlex.quote(source)} {shlex.quote(json.dumps(request))}"
    result = launch(binary, script, cwd=cwd, home=home)
    if result.returncode != 0:
        raise AssertionError(
            f"{payload} exited {result.returncode}\n"
            f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}"
        )
    try:
        outcomes = json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise AssertionError(
            f"{payload} printed no JSON\nstdout:\n{result.stdout}\nstderr:\n{result.stderr}"
        ) from error
    if not isinstance(outcomes, list) or len(outcomes) != len(request):
        raise AssertionError(f"{payload} answered {outcomes!r} for {len(request)} checks")
    return [str(outcome) for outcome in outcomes]


def probe_paths(
    launch: Launch,
    binary: Path,
    checks: Sequence[tuple[PathOp, Path]],
    *,
    cwd: Path | None = None,
    home: Path | None = None,
) -> dict[tuple[PathOp, Path], str]:
    request: list[list[object]] = [[op, str(path)] for op, path in checks]
    outcomes = _run_probe(launch, binary, "probe_paths.py", request, cwd=cwd, home=home)
    return dict(zip(checks, outcomes))


def probe_network(
    launch: Launch,
    binary: Path,
    checks: Sequence[tuple[NetworkOp, str, int]],
    *,
    cwd: Path | None = None,
    home: Path | None = None,
) -> dict[tuple[NetworkOp, str, int], str]:
    request: list[list[object]] = [[op, host, port] for op, host, port in checks]
    outcomes = _run_probe(launch, binary, "probe_network.py", request, cwd=cwd, home=home)
    return dict(zip(checks, outcomes))


def probe_sockets(
    launch: Launch,
    binary: Path,
    checks: Sequence[tuple[SocketOp, Path]],
    *,
    cwd: Path | None = None,
    home: Path | None = None,
) -> dict[tuple[SocketOp, Path], str]:
    request: list[list[object]] = [[op, str(path)] for op, path in checks]
    outcomes = _run_probe(launch, binary, "probe_sockets.py", request, cwd=cwd, home=home)
    return dict(zip(checks, outcomes))
