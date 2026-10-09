import json
import subprocess
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
PUBLISHED_REPO = "github.com/archie-judd/agent-sandbox.nix"
PUBLISHED_TAG_PREFIX = f"{PUBLISHED_REPO}/archive/refs/tags/v"
VERSION = (REPO_ROOT / "version.txt").read_text().strip()
IMPORT_EXPR = f'(fetchTarball "https://{PUBLISHED_TAG_PREFIX}{VERSION}.tar.gz")'
SHELLS = sorted([*REPO_ROOT.glob("shells/*.nix"), *REPO_ROOT.glob("debug/*.nix")])


def _pinned_nixpkgs_url() -> str:
    lock = json.loads((REPO_ROOT / "flake.lock").read_text())
    locked = lock["nodes"]["nixpkgs"]["locked"]
    return f"https://github.com/{locked['owner']}/{locked['repo']}/archive/{locked['rev']}.tar.gz"


def test_shells_are_found() -> None:
    assert SHELLS


@pytest.mark.parametrize("shell", SHELLS, ids=lambda path: str(path.relative_to(REPO_ROOT)))
def test_shell_evaluates_against_this_checkout(shell: Path, tmp_path: Path) -> None:
    source = shell.read_text()
    if IMPORT_EXPR in source:
        target = tmp_path / shell.name
        target.write_text(source.replace(IMPORT_EXPR, f"({REPO_ROOT})"))
    else:
        assert PUBLISHED_TAG_PREFIX not in source, f"pinned to a release other than v{VERSION}"
        assert PUBLISHED_REPO not in source, "reaches the published tree in a form not rewritten here"
        target = shell
    result = subprocess.run(
        ["nix-instantiate", "-I", f"nixpkgs={_pinned_nixpkgs_url()}", str(target)],
        capture_output=True,
        text=True,
    )
    assert result.returncode == 0, result.stderr
