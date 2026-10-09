import shutil
import sys
import tempfile
from collections.abc import Iterator
from pathlib import Path

import pytest

from harness.build import BuildSandbox
from harness.launch import Launch
from harness.probes import PathOp, probe_paths

HIDDEN = {"linux": "ENOENT", "darwin": "EPERM"}[sys.platform]
READ_ONLY_MODE = {"linux": "EACCES", "darwin": "EPERM"}[sys.platform]


@pytest.fixture
def parent_link_dir(monkeypatch: pytest.MonkeyPatch) -> Iterator[Path]:
    directory = Path(tempfile.mkdtemp(dir="/tmp", prefix="test-parent-link-dir."))
    monkeypatch.setenv("SANDBOX_TEST_PARENT_LINK_DIR", str(directory))
    yield directory
    shutil.rmtree(directory)


@pytest.fixture
def symlinks(build_sandbox: BuildSandbox, fake_home: Path, parent_link_dir: Path) -> Path:
    (fake_home / ".test-state-dir").mkdir()
    (fake_home / ".test-state-file").touch()
    (fake_home / ".test-ro-file").touch()
    return build_sandbox("symlinks-sandbox")


@pytest.fixture
def store(symlinks: Path, launch: Launch) -> dict[str, Path]:
    names = ["CLOSURE_STORE_FILE", "NONCLOSURE_STORE_FILE", "NONCLOSURE_STORE_FILE2"]
    script = "; ".join(f'echo "${name}"' for name in names)
    result = launch(symlinks, script)
    assert result.returncode == 0, result.stderr
    return dict(zip(names, (Path(line) for line in result.stdout.splitlines())))


@pytest.fixture
def out_of_bounds(tmp_path: Path) -> Path:
    secret = tmp_path / "outside" / "secret"
    secret.parent.mkdir()
    secret.write_text("out-of-bounds content")
    return secret


def test_declared_rw_paths_are_writable(
    symlinks: Path, launch: Launch, parent_link_dir: Path
) -> None:
    checks: list[tuple[PathOp, Path]] = [
        ("write", Path("$HOME/.test-state-file")),
        ("create", Path("$HOME/.test-state-dir/new")),
        ("create", parent_link_dir / "new"),
    ]

    outcomes = probe_paths(launch, symlinks, checks)

    assert outcomes == {check: "ok" for check in checks}


def test_store_paths_outside_the_closure_are_hidden_unless_named(
    symlinks: Path, launch: Launch, store: dict[str, Path]
) -> None:
    checks: list[tuple[PathOp, Path]] = [
        ("read", store["CLOSURE_STORE_FILE"]),
        ("read", store["NONCLOSURE_STORE_FILE"]),
    ]

    outcomes = probe_paths(launch, symlinks, checks)

    assert outcomes == {checks[0]: "ok", checks[1]: HIDDEN}


def test_a_ro_file_symlink_grants_only_its_store_target_read_only(
    symlinks: Path, launch: Launch, store: dict[str, Path], fake_home: Path
) -> None:
    target = store["NONCLOSURE_STORE_FILE"]
    (fake_home / ".test-ro-file").unlink()
    (fake_home / ".test-ro-file").symlink_to(target)
    checks: list[tuple[PathOp, Path]] = [
        ("read", target),
        ("write", target),
        ("read", store["NONCLOSURE_STORE_FILE2"]),
    ]
    expected = {checks[0]: "ok", checks[1]: READ_ONLY_MODE, checks[2]: HIDDEN}
    if sys.platform == "linux":
        checks += [("read", Path("$HOME/.test-ro-file")), ("write", Path("$HOME/.test-ro-file"))]
        expected |= {checks[3]: "ok", checks[4]: "EACCES"}
    else:
        checks.append(("exec", target))
        expected |= {checks[3]: "EPERM"}

    outcomes = probe_paths(launch, symlinks, checks)

    assert outcomes == expected


def test_an_rw_dir_symlink_grants_only_its_store_target(
    symlinks: Path, launch: Launch, store: dict[str, Path], fake_home: Path
) -> None:
    (fake_home / ".test-state-dir" / "link").symlink_to(store["NONCLOSURE_STORE_FILE"])
    checks: list[tuple[PathOp, Path]] = [
        ("read", store["NONCLOSURE_STORE_FILE"]),
        ("write", store["NONCLOSURE_STORE_FILE"]),
        ("read", store["NONCLOSURE_STORE_FILE2"]),
    ]

    outcomes = probe_paths(launch, symlinks, checks)

    assert outcomes == {checks[0]: "ok", checks[1]: READ_ONLY_MODE, checks[2]: HIDDEN}


def test_an_out_of_bounds_symlink_is_ignored_with_a_warning(
    symlinks: Path, launch: Launch, fake_home: Path, out_of_bounds: Path
) -> None:
    (fake_home / ".test-state-dir" / "link").symlink_to(out_of_bounds)

    started = launch(symlinks, "true")
    outcomes = probe_paths(launch, symlinks, [("read", out_of_bounds)])

    assert started.returncode == 0, started.stderr
    assert f"ignoring symlink to '{out_of_bounds}'" in started.stderr
    assert outcomes == {("read", out_of_bounds): HIDDEN}


@pytest.mark.darwin
def test_a_declared_dir_under_a_symlinked_parent_is_reachable_alone(
    symlinks: Path, launch: Launch, parent_link_dir: Path
) -> None:
    physical = Path("/private") / parent_link_dir.relative_to("/")
    with tempfile.NamedTemporaryFile(dir="/tmp", prefix="sandbox-test-tmp-oob.") as sibling:
        checks: list[tuple[PathOp, Path]] = [
            ("create", parent_link_dir / "via-tmp"),
            ("create", physical / "via-private-tmp"),
            ("list", Path("/tmp")),
            ("read", Path(sibling.name)),
        ]

        outcomes = probe_paths(launch, symlinks, checks)

    assert outcomes == {
        checks[0]: "ok",
        checks[1]: "ok",
        checks[2]: "EPERM",
        checks[3]: "EPERM",
    }


@pytest.mark.linux
def test_a_store_symlink_rw_dir_is_readable_from_a_home_launch(
    symlinks: Path, launch: Launch, store: dict[str, Path], fake_home: Path
) -> None:
    (fake_home / ".test-state-dir").rmdir()
    (fake_home / ".test-state-dir").symlink_to(store["NONCLOSURE_STORE_FILE"].parent)

    result = launch(
        symlinks,
        'ls "$HOME/.test-state-dir" >/dev/null && echo SYMLINK-DIR-OK',
        cwd=fake_home,
        tty_reply="y",
    )

    assert result.returncode == 0, result.stdout
    assert "SYMLINK-DIR-OK" in result.stdout
