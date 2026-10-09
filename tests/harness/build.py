import json
import subprocess
from pathlib import Path
from typing import Mapping, Protocol

_FIXTURES_DIR = Path(__file__).resolve().parent.parent / "integration" / "fixtures"


class BuildSandbox(Protocol):
    def __call__(self, fixture: str, args: Mapping[str, object] | None = None) -> Path: ...


def _nix_string(text: str) -> str:
    escaped = text.replace("\\", "\\\\").replace('"', '\\"').replace("${", "\\${")
    return f'"{escaped}"'


def _nix_build_args(args: Mapping[str, object]) -> list[str]:
    rendered: list[str] = []
    for name, value in args.items():
        if isinstance(value, str):
            rendered += ["--argstr", name, value]
        else:
            expression = f"builtins.fromJSON {_nix_string(json.dumps(value))}"
            rendered += ["--arg", name, expression]
    return rendered


def nix_build_sandbox(fixture: str, args: Mapping[str, object], *, out_link: Path) -> Path:
    result = subprocess.run(
        [
            "nix-build",
            "--out-link",
            str(out_link),
            *_nix_build_args(args),
            str(_FIXTURES_DIR / f"{fixture}.nix"),
        ],
        capture_output=True,
        text=True,
        errors="replace",
    )
    if result.returncode != 0:
        raise RuntimeError(f"nix-build {fixture} failed:\n{result.stderr}")
    binaries = list((out_link / "bin").iterdir())
    if len(binaries) != 1:
        raise RuntimeError(f"{fixture}: expected one binary, found {binaries}")
    return binaries[0]
