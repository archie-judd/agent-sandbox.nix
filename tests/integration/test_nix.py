import json
import os
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
from collections.abc import Iterator
from pathlib import Path

import pytest

from harness.build import BuildSandbox
from harness.launch import Launch
from harness.probes import PathOp, probe_paths

HIDDEN = {"linux": "ENOENT", "darwin": "EPERM"}[sys.platform]
NIX_COMMANDS = """
nix build "path:$NIXPKGS_SRC#hello" --no-link && echo build
[ "$(nix run "path:$NIXPKGS_SRC#hello")" = "Hello, world!" ] && echo run
nix develop "path:$NIXPKGS_SRC#hello" -c true && echo develop
"""
NIX_COMMANDS_DENIED = """
command -v nix >/dev/null && echo has-nix
nix build "path:$NIXPKGS_SRC#hello" --no-link || echo no-build
nix run "path:$NIXPKGS_SRC#hello" || echo no-run
nix develop "path:$NIXPKGS_SRC#hello" -c true || echo no-develop
"""


def _markers(output: str, expected: list[str]) -> list[str]:
    plain = re.sub(r"\x1b\[[0-9;?]*[A-Za-z]|\r", " ", output)
    return [token for token in plain.split() if token in expected]


@pytest.fixture
def nix_support(build_sandbox: BuildSandbox) -> Path:
    return build_sandbox("nix-support")


@pytest.fixture
def store_isolation(build_sandbox: BuildSandbox) -> Path:
    return build_sandbox("nix-store-isolation")


def test_nix_commands_work_with_allow_nix(nix_support: Path, launch: Launch) -> None:
    result = launch(nix_support, NIX_COMMANDS, tty_reply="y")

    expected = ["build", "run", "develop"]
    assert _markers(result.stdout, expected) == expected, repr(result.stdout)


def test_nix_commands_fail_without_allow_nix(store_isolation: Path, launch: Launch) -> None:
    result = launch(store_isolation, NIX_COMMANDS_DENIED)

    assert result.stdout.split() == ["has-nix", "no-build", "no-run", "no-develop"]
    assert "experimental" not in result.stderr


def test_allow_nix_exposes_the_whole_store(nix_support: Path, launch: Launch) -> None:
    script = """
        cat "$NON_CLOSURE_STORE_PATH/bin/hello" >/dev/null && echo read
        "$NON_CLOSURE_STORE_PATH/bin/hello" >/dev/null && echo exec
    """
    if sys.platform == "linux":
        script += '[ -S "$NIX_DAEMON_SOCKET_PATH" ] && echo socket\n'
        expected = ["read", "exec", "socket"]
    else:
        script += "[ -d /nix/var ] && echo nix-var\n[ -d /etc/nix ] && echo etc-nix\n"
        expected = ["read", "exec", "nix-var", "etc-nix"]

    result = launch(nix_support, script, tty_reply="y")

    assert _markers(result.stdout, expected) == expected, repr(result.stdout)


def test_without_allow_nix_the_store_is_closed(store_isolation: Path, launch: Launch) -> None:
    disallowed = Path("$DISALLOWED_STORE_PATH")
    checks: list[tuple[PathOp, Path]] = [
        ("read", disallowed / "bin" / "hello"),
        ("exec", disallowed / "bin" / "hello"),
        ("list", disallowed),
    ]
    expected = {check: HIDDEN for check in checks}
    if sys.platform == "linux":
        socket_check: tuple[PathOp, Path] = ("stat", Path("/nix/var/nix/daemon-socket/socket"))
        checks.append(socket_check)
        expected[socket_check] = "ENOENT"
    else:
        darwin_checks: dict[tuple[PathOp, Path], str] = {
            ("list", Path("/nix/store")): "EPERM",
            ("stat", Path("/nix/store")): "ok",
            ("stat", Path("/nix/var")): "EPERM",
            ("stat", Path("/etc/nix")): "EPERM",
        }
        checks += list(darwin_checks)
        expected |= darwin_checks

    outcomes = probe_paths(launch, store_isolation, checks)

    assert outcomes == expected


@pytest.fixture
def daemon_relay() -> Iterator[Path]:
    directory = Path(tempfile.mkdtemp(dir="/tmp", prefix="nix-daemon-socket."))
    (directory / "host-only").touch()
    path = directory / "socket"
    server = socket.socket(socket.AF_UNIX)
    server.bind(str(path))
    server.listen()

    def pump(source: socket.socket, destination: socket.socket) -> None:
        try:
            while data := source.recv(65536):
                destination.sendall(data)
            destination.shutdown(socket.SHUT_WR)
        except OSError:
            pass

    def serve() -> None:
        while True:
            try:
                client, _ = server.accept()
            except OSError:
                return
            upstream = socket.socket(socket.AF_UNIX)
            upstream.connect("/nix/var/nix/daemon-socket/socket")
            threading.Thread(target=pump, args=(client, upstream), daemon=True).start()
            threading.Thread(target=pump, args=(upstream, client), daemon=True).start()

    threading.Thread(target=serve, daemon=True).start()
    yield path
    server.shutdown(socket.SHUT_RDWR)
    server.close()
    shutil.rmtree(directory)


@pytest.mark.linux
def test_a_daemon_socket_outside_nix_var_is_bound_alone(
    nix_support: Path, launch: Launch, daemon_relay: Path
) -> None:
    script = """
        [ -S "$NIX_DAEMON_SOCKET_PATH" ] && echo socket
        [ -e "$(dirname "$NIX_DAEMON_SOCKET_PATH")/host-only" ] || echo neighbour-hidden
    """

    result = launch(
        nix_support, script, env={"NIX_DAEMON_SOCKET_PATH": str(daemon_relay)}, tty_reply="y"
    )

    expected = ["socket", "neighbour-hidden"]
    assert _markers(result.stdout, expected) == expected, repr(result.stdout)


def _host_nix(*args: str) -> str:
    env = {k: v for k, v in os.environ.items() if k not in ("NIX_CONFIG", "NIX_CONF_DIR")}
    env["NIX_USER_CONF_FILES"] = ""
    env["NIX_REMOTE"] = "daemon"
    result = subprocess.run(
        ["nix", "--extra-experimental-features", "nix-command", *args],
        env=env,
        capture_output=True,
        text=True,
    )
    return result.stdout


def test_the_daemon_sandbox_check_follows_the_host(nix_support: Path, launch: Launch) -> None:
    settings = dict(
        line.split(" = ", 1) for line in _host_nix("config", "show").splitlines() if " = " in line
    )
    host_sandbox = settings.get("sandbox", "unreadable")
    host_trusted = json.loads(_host_nix("store", "info", "--json") or "{}").get("trusted")

    unattended = launch(nix_support, "echo LAUNCHED")

    if host_trusted in (True, 1):
        assert unattended.returncode == 1
        assert "you are a trusted user of the host's nix daemon" in unattended.stderr
        assert "LAUNCHED" not in unattended.stdout
    elif host_sandbox == "true":
        assert unattended.stdout == "LAUNCHED\n", unattended.stderr
        assert "your nix daemon" not in unattended.stderr
    else:
        declined = launch(nix_support, "echo LAUNCHED", tty_reply="n")
        confirmed = launch(nix_support, "echo LAUNCHED", tty_reply="y")
        assert unattended.returncode == 1
        assert f"sandbox = {host_sandbox}" in unattended.stderr
        assert "no terminal to confirm on" in unattended.stderr
        assert "LAUNCHED" not in unattended.stdout
        assert declined.returncode == 1
        assert "your nix daemon" in declined.stdout
        assert "set sandbox = true in /etc/nix/nix.conf" in declined.stdout
        assert "LAUNCHED" not in declined.stdout
        assert confirmed.returncode == 0
        assert "LAUNCHED" in confirmed.stdout
