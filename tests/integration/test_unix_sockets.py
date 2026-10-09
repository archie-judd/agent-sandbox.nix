import subprocess
import sys
from contextlib import ExitStack
from pathlib import Path

import pytest

from harness.build import BuildSandbox
from harness.launch import Launch
from harness.listeners import unix_listener
from harness.probes import SocketOp, probe_sockets

HIDDEN = {"linux": "ENOENT", "darwin": "EPERM"}[sys.platform]
READ_ONLY = {"linux": "EROFS", "darwin": "EPERM"}[sys.platform]
UNUSED = Path("-")


@pytest.fixture
def fake_home(short_tmp: Path) -> Path:
    home = short_tmp / "h"
    home.mkdir()
    return home


@pytest.fixture
def sessions_root(short_tmp: Path) -> Path:
    sessions = short_tmp / "s"
    sessions.mkdir()
    return sessions


@pytest.fixture
def workspace(short_tmp: Path) -> Path:
    workspace = short_tmp / "w"
    (workspace / "nested-ro").mkdir(parents=True)
    return workspace


@pytest.mark.linux
def test_unix_sockets_are_denied_by_default_but_not_socketpair_or_inet(
    build_sandbox: BuildSandbox, launch: Launch, workspace: Path
) -> None:
    checks: list[tuple[SocketOp, Path]] = [
        ("create", UNUSED),
        ("create_dgram", UNUSED),
        ("socketpair", UNUSED),
        ("inet", UNUSED),
    ]

    outcomes = probe_sockets(launch, build_sandbox("unix-socket-default-sandbox"), checks, cwd=workspace)

    assert outcomes == {checks[0]: "EPERM", checks[1]: "EPERM", checks[2]: "ok", checks[3]: "ok"}


@pytest.mark.darwin
def test_host_unix_sockets_are_unreachable_without_the_flag(
    build_sandbox: BuildSandbox, launch: Launch, workspace: Path
) -> None:
    socket_path = workspace / "l.sock"
    check: tuple[SocketOp, Path] = ("connect", socket_path)

    with unix_listener(socket_path):
        outcomes = probe_sockets(launch, build_sandbox("unix-socket-client-sandbox"), [check], cwd=workspace)

    assert outcomes == {check: "EPERM"}


@pytest.mark.parametrize("variant", ["filtered", "open", "nested"])
def test_sockets_work_in_the_workspace_and_tmpdir_and_nowhere_else(
    build_sandbox: BuildSandbox, launch: Launch, short_tmp: Path, workspace: Path, variant: str
) -> None:
    args = {"filtered": {}, "open": {"open": True}, "nested": {"nestedRoDir": True}}[variant]
    sandbox = build_sandbox("unix-socket-allowed-sandbox", args)
    (short_tmp / "out").mkdir()
    outside = short_tmp / "out" / "l.sock"
    checks: list[tuple[SocketOp, Path]] = [
        ("socketpair", UNUSED),
        ("roundtrip", workspace / "check.sock"),
        ("roundtrip", Path("$TMPDIR/t.sock")),
        ("connect", outside),
    ]
    expected = {checks[0]: "ok", checks[1]: "ok", checks[2]: "ok", checks[3]: HIDDEN}
    if variant == "nested":
        nested_bind: tuple[SocketOp, Path] = ("bind", workspace / "nested-ro" / "deny.sock")
        nested_connect: tuple[SocketOp, Path] = ("connect", workspace / "nested-ro" / "l.sock")
        checks += [nested_bind, nested_connect]
        expected |= {nested_bind: READ_ONLY, nested_connect: "ok"}

    with unix_listener(outside), unix_listener(workspace / "nested-ro" / "l.sock"):
        outcomes = probe_sockets(launch, sandbox, checks, cwd=workspace)

    assert outcomes == expected


def test_declared_paths_grant_bind_where_writable_and_connect_where_readable(
    build_sandbox: BuildSandbox,
    launch: Launch,
    monkeypatch: pytest.MonkeyPatch,
    short_tmp: Path,
    workspace: Path,
) -> None:
    rw_dir, ro_dir, ro_file_dir = short_tmp / "rw", short_tmp / "ro", short_tmp / "rof"
    for directory in (rw_dir, ro_dir, ro_file_dir):
        directory.mkdir()
    ro_file = ro_file_dir / "host.sock"
    monkeypatch.setenv("UNIX_TEST_RW", str(rw_dir))
    monkeypatch.setenv("UNIX_TEST_RO", str(ro_dir))
    monkeypatch.setenv("UNIX_TEST_RO_FILE", str(ro_file))
    checks: list[tuple[SocketOp, Path]] = [
        ("roundtrip", rw_dir / "rw.sock"),
        ("bind", ro_dir / "deny.sock"),
        ("connect", ro_dir / "l.sock"),
        ("connect", ro_file),
    ]

    with ExitStack() as stack:
        stack.enter_context(unix_listener(ro_dir / "l.sock"))
        stack.enter_context(unix_listener(ro_file))
        outcomes = probe_sockets(
            launch,
            build_sandbox("unix-socket-allowed-sandbox", {"withDeclaredPaths": True}),
            checks,
            cwd=workspace,
        )

    assert outcomes == {checks[0]: "ok", checks[1]: READ_ONLY, checks[2]: "ok", checks[3]: "ok"}


def test_the_repo_root_above_the_workspace_allows_connect_but_not_bind(
    build_sandbox: BuildSandbox, launch: Launch, short_tmp: Path
) -> None:
    repo = short_tmp / "repo"
    (repo / "sub").mkdir(parents=True)
    subprocess.run(["git", "init", "-q", str(repo)], check=True)
    checks: list[tuple[SocketOp, Path]] = [
        ("connect", repo / "root.sock"),
        ("bind", repo / "deny.sock"),
    ]

    with unix_listener(repo / "root.sock"):
        outcomes = probe_sockets(
            launch, build_sandbox("unix-socket-allowed-sandbox"), checks, cwd=repo / "sub"
        )

    assert outcomes == {checks[0]: "ok", checks[1]: READ_ONLY}
