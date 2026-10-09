import os
from pathlib import Path

import pytest

from harness.builders import make_host_linux
from launcher.lib.host_state import _get_declared_paths
from launcher.lib.launch_config.linux.binds import get_declared_binds


def test_a_ro_dir_symlink_out_of_bounds_is_not_bound(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    home = Path(os.path.realpath(tmp_path))
    monkeypatch.setenv("HOME", str(home))
    out_of_bounds = home / "secret"
    out_of_bounds.write_text("out-of-bounds content")
    ro_dir = home / ".test-ro-dir"
    ro_dir.mkdir()
    (ro_dir / "link-to-oob").symlink_to(out_of_bounds)
    declared = tuple(_get_declared_paths(["$HOME/.test-ro-dir"], "ro", "dir"))

    binds = get_declared_binds(make_host_linux(declared=declared), [ro_dir])

    every_arg = [
        *binds.dir_binds,
        *binds.ro_dir_binds,
        *binds.file_binds,
        *binds.ro_file_binds,
        *binds.parent_dirs,
        *binds.symlink_targets,
        *binds.parent_symlinks,
    ]
    assert str(out_of_bounds) not in every_arg
    assert binds.warnings == (
        f"[WARN][agent-sandbox.nix] ignoring symlink to '{out_of_bounds}': outside "
        "permitted paths. Declare it as a rwDir, rwFile, roDir or roFile to allow access.",
    )
