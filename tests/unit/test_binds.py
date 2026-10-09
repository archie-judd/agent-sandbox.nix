import os
from pathlib import Path

import pytest

from harness.builders import make_host_linux
from launcher.lib.host_state import _get_declared_paths
from launcher.lib.launch_config.linux.binds import DeclaredBinds, get_declared_binds


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


STORE_FILE = Path(os.path.realpath(os.__file__))
STORE_SIBLING = Path(os.path.realpath(STORE_FILE.with_name("abc.py")))
STORE_DIR = STORE_FILE.parent


@pytest.fixture
def home(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> Path:
    assert Path("/nix/store") in STORE_FILE.parents
    assert STORE_SIBLING.parent == STORE_DIR
    home = Path(os.path.realpath(tmp_path)) / "home"
    (home / ".test-state-dir").mkdir(parents=True)
    monkeypatch.setenv("HOME", str(home))
    return home


def _binds(home: Path, *prefixes: Path) -> DeclaredBinds:
    declared = (
        *_get_declared_paths(["$HOME/.test-state-dir"], "rw", "dir"),
        *_get_declared_paths(["$HOME/.test-state-file"], "rw", "file"),
        *_get_declared_paths(["$HOME/.test-ro-file"], "ro", "file"),
    )
    return get_declared_binds(make_host_linux(declared=declared), [home / ".test-state-dir", *prefixes])


def _every_arg(binds: DeclaredBinds) -> list[str]:
    return [
        *binds.dir_binds,
        *binds.ro_dir_binds,
        *binds.file_binds,
        *binds.ro_file_binds,
        *binds.parent_dirs,
        *binds.symlink_targets,
        *binds.parent_symlinks,
    ]


def _plain_files(home: Path) -> None:
    (home / ".test-state-file").touch()
    (home / ".test-ro-file").touch()


def test_an_rw_file_symlink_out_of_bounds_is_not_bound(home: Path, tmp_path: Path) -> None:
    out_of_bounds = tmp_path / "secret"
    out_of_bounds.touch()
    (home / ".test-state-file").symlink_to(out_of_bounds)
    (home / ".test-ro-file").touch()

    binds = _binds(home)

    assert str(out_of_bounds) not in _every_arg(binds)
    assert len(binds.warnings) == 1
    assert f"ignoring symlink to '{out_of_bounds}'" in binds.warnings[0]


def test_an_rw_file_symlink_into_the_store_is_bound_from_its_target(home: Path) -> None:
    (home / ".test-state-file").symlink_to(STORE_FILE)
    (home / ".test-ro-file").touch()

    binds = _binds(home)

    assert list(binds.file_binds) == ["--bind", str(STORE_FILE), str(home / ".test-state-file")]
    assert list(binds.symlink_targets) == ["--ro-bind", str(STORE_FILE), str(STORE_FILE)]


def test_a_ro_file_symlink_into_the_store_is_bound_read_only(home: Path) -> None:
    (home / ".test-state-file").touch()
    (home / ".test-ro-file").symlink_to(STORE_FILE)

    binds = _binds(home)

    assert list(binds.ro_file_binds) == ["--ro-bind", str(STORE_FILE), str(home / ".test-ro-file")]


def test_a_store_target_already_in_the_closure_gets_no_bind_of_its_own(home: Path) -> None:
    _plain_files(home)
    (home / ".test-state-dir" / "link").symlink_to(STORE_FILE)

    assert _binds(home, STORE_DIR).symlink_targets == ()
    assert list(_binds(home).symlink_targets) == ["--ro-bind", str(STORE_FILE), str(STORE_FILE)]


def test_two_symlinks_to_one_target_bind_it_once(home: Path) -> None:
    _plain_files(home)
    (home / ".test-state-dir" / "first").symlink_to(STORE_FILE)
    (home / ".test-state-dir" / "second").symlink_to(STORE_FILE)

    assert list(_binds(home).symlink_targets) == ["--ro-bind", str(STORE_FILE), str(STORE_FILE)]


def test_a_chain_through_an_out_of_bounds_link_is_not_bound(home: Path, tmp_path: Path) -> None:
    _plain_files(home)
    real = tmp_path / "real"
    real.touch()
    middle = tmp_path / "middle"
    middle.symlink_to(real)
    (home / ".test-state-dir" / "double-link").symlink_to(middle)

    binds = _binds(home)

    assert str(middle) not in _every_arg(binds)
    assert str(real) not in _every_arg(binds)
    assert binds.warnings


def test_out_of_bounds_siblings_are_not_bound(home: Path, tmp_path: Path) -> None:
    _plain_files(home)
    for name in ("a", "b"):
        (tmp_path / name).touch()
        (home / ".test-state-dir" / f"sibling-{name}").symlink_to(tmp_path / name)

    binds = _binds(home)

    assert binds.symlink_targets == ()
    assert len(binds.warnings) == 2


def test_store_siblings_are_both_bound(home: Path) -> None:
    _plain_files(home)
    (home / ".test-state-dir" / "a").symlink_to(STORE_FILE)
    (home / ".test-state-dir" / "b").symlink_to(STORE_SIBLING)

    binds = _binds(home)

    assert list(binds.symlink_targets) == [
        "--ro-bind", str(STORE_FILE), str(STORE_FILE),
        "--ro-bind", str(STORE_SIBLING), str(STORE_SIBLING),
    ]
    assert str(STORE_DIR) in binds.parent_dirs


def test_a_store_symlink_dir_inside_a_bound_parent_is_not_mounted_over(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    home = Path(os.path.realpath(tmp_path)) / "home"
    home.mkdir()
    monkeypatch.setenv("HOME", str(home))
    (home / ".test-state-dir").symlink_to(STORE_DIR)
    declared = tuple(_get_declared_paths(["$HOME/.test-state-dir"], "rw", "dir"))

    binds = get_declared_binds(make_host_linux(declared=declared), [home])

    assert binds.dir_binds == ()
    assert list(binds.symlink_targets) == ["--ro-bind", str(STORE_DIR), str(STORE_DIR)]
