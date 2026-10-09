import json
import shlex
from pathlib import Path
from typing import Literal, Sequence

from harness.launch import Launch

PathOp = Literal["read", "list", "stat", "write", "create", "delete", "exec"]

_PAYLOAD = Path(__file__).resolve().parent.parent / "integration" / "payloads" / "probe_paths.py"


def probe_paths(
    launch: Launch,
    binary: Path,
    checks: Sequence[tuple[PathOp, Path]],
    *,
    cwd: Path | None = None,
    home: Path | None = None,
) -> dict[tuple[PathOp, Path], str]:
    request = json.dumps([[op, str(path)] for op, path in checks])
    script = f"python3 -c {shlex.quote(_PAYLOAD.read_text())} {shlex.quote(request)}"
    result = launch(binary, script, cwd=cwd, home=home)
    if result.returncode != 0:
        raise AssertionError(
            f"path probe exited {result.returncode}\n"
            f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}"
        )
    try:
        outcomes = json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise AssertionError(
            f"path probe printed no JSON\nstdout:\n{result.stdout}\nstderr:\n{result.stderr}"
        ) from error
    if not isinstance(outcomes, list) or len(outcomes) != len(checks):
        raise AssertionError(f"path probe answered {outcomes!r} for {len(checks)} checks")
    return {check: str(outcome) for check, outcome in zip(checks, outcomes)}
