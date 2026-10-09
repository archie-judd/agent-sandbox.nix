import os
import socket
import sys
import tempfile
from collections.abc import Iterator
from pathlib import Path

import pytest
from harness.launch import Launch
from harness.probes import PathOp, probe_paths

HIDDEN = {"linux": "ENOENT", "darwin": "EPERM"}[sys.platform]


@pytest.fixture
def workspace(tmp_path: Path) -> Path:
    workspace = tmp_path / "workspace"
    workspace.mkdir()
    return workspace


@pytest.fixture
def host_tmp_canary() -> Iterator[Path]:
    with tempfile.NamedTemporaryFile(
        dir="/tmp", prefix="sandbox-host-canary."
    ) as canary:
        yield Path(canary.name)


def test_host_secrets_in_home_are_hidden(
    basic_sandbox: Path, launch: Launch, fake_home: Path
) -> None:
    (fake_home / ".ssh").mkdir()
    (fake_home / ".ssh" / "id_test").write_text("secret")
    (fake_home / ".bash_history").write_text("history")
    (fake_home / ".bashrc").write_text("rc")

    outcomes = probe_paths(
        launch,
        basic_sandbox,
        [
            ("list", fake_home / ".ssh"),
            ("read", fake_home / ".bash_history"),
            ("read", fake_home / ".bashrc"),
            ("read", Path("$HOME/.bashrc")),
        ],
    )

    assert outcomes == {
        ("list", fake_home / ".ssh"): HIDDEN,
        ("read", fake_home / ".bash_history"): HIDDEN,
        ("read", fake_home / ".bashrc"): HIDDEN,
        ("read", Path("$HOME/.bashrc")): "ENOENT",
    }


def test_the_sandbox_home_holds_only_the_declared_paths(
    basic_sandbox: Path, launch: Launch, fake_home: Path
) -> None:
    (fake_home / ".bashrc").write_text("rc")

    result = launch(basic_sandbox, 'ls -A "$HOME"')

    assert result.returncode == 0, result.stderr
    assert set(result.stdout.split()) == {".test-state-dir", ".test-state-file"}


def test_the_workspace_tmpdir_and_home_are_writable(
    basic_sandbox: Path, launch: Launch, workspace: Path
) -> None:
    outcomes = probe_paths(
        launch,
        basic_sandbox,
        [
            ("create", workspace / "new"),
            ("create", Path("$TMPDIR/new")),
            ("create", Path("$HOME/new")),
            ("read", Path("/etc/resolv.conf")),
        ],
        cwd=workspace,
    )

    assert set(outcomes.values()) == {"ok"}


def test_declared_env_arrives_and_host_env_does_not(
    basic_sandbox: Path, launch: Launch
) -> None:
    result = launch(
        basic_sandbox,
        'printf "%s|%s" "$TEST_VAR" "${_TEST_HOST_VAR-unset}"',
        env={"_TEST_HOST_VAR": "should-not-propagate"},
    )

    assert result.stdout == "test-value|unset"


def test_usr_bin_env_resolves_a_shebang(
    basic_sandbox: Path, launch: Launch, workspace: Path
) -> None:
    script = workspace / "env-shebang.sh"
    script.write_text("#!/usr/bin/env sh\necho hello\n")
    script.chmod(0o755)

    result = launch(basic_sandbox, "./env-shebang.sh", cwd=workspace)

    assert result.stdout == "hello\n", result.stderr


@pytest.mark.linux
def test_root_is_hidden(basic_sandbox: Path, launch: Launch) -> None:
    assert Path("/root").exists()

    outcomes = probe_paths(launch, basic_sandbox, [("stat", Path("/root"))])

    assert outcomes == {("stat", Path("/root")): "ENOENT"}


@pytest.mark.linux
def test_etc_and_tmp_are_private(
    basic_sandbox: Path, launch: Launch, host_tmp_canary: Path
) -> None:
    assert Path("/etc/shadow").exists()

    outcomes = probe_paths(
        launch,
        basic_sandbox,
        [
            ("create", Path("/etc/test")),
            ("read", Path("/etc/shadow")),
            ("create", Path("/tmp/sandbox-test")),
            ("stat", host_tmp_canary),
        ],
    )

    assert outcomes == {
        ("create", Path("/etc/test")): "ok",
        ("read", Path("/etc/shadow")): "ENOENT",
        ("create", Path("/tmp/sandbox-test")): "ok",
        ("stat", host_tmp_canary): "ENOENT",
    }


@pytest.mark.linux
def test_proc_1_environ_holds_no_host_env(basic_sandbox: Path, launch: Launch) -> None:
    result = launch(
        basic_sandbox,
        'tr "\\0" "\\n" < /proc/1/environ',
        env={"SANDBOX_TEST_HOST_ONLY": "canary-must-not-leak"},
    )

    assert result.returncode == 0, result.stderr
    assert "SANDBOX_TEST_HOST_ONLY" not in result.stdout


@pytest.mark.linux
def test_the_hostname_is_neutralised(basic_sandbox: Path, launch: Launch) -> None:
    result = launch(basic_sandbox, "uname -n")

    assert result.stdout == "sandbox\n"
    assert socket.gethostname() != "sandbox"


@pytest.mark.linux
def test_passwd_is_the_single_fabricated_user(
    basic_sandbox: Path, launch: Launch, fake_home: Path
) -> None:
    result = launch(basic_sandbox, "cat /etc/passwd")

    assert result.stdout == (
        f"user:x:{os.getuid()}:{os.getgid()}:sandbox user:{fake_home}:/bin/sh\n"
    )


@pytest.mark.linux
def test_host_fingerprints_in_proc_are_empty(
    basic_sandbox: Path, launch: Launch
) -> None:
    result = launch(
        basic_sandbox, "wc -c < /proc/cmdline; wc -c < /proc/sys/kernel/random/boot_id"
    )

    assert result.stdout.split() == ["0", "0"], result.stderr


@pytest.mark.darwin
def test_host_paths_are_traversable_but_not_listable(
    basic_sandbox: Path, launch: Launch, fake_home: Path
) -> None:
    real_home = fake_home

    outcomes = probe_paths(
        launch,
        basic_sandbox,
        [
            ("create", Path("/etc/test")),
            ("read", Path("/etc/passwd")),
            ("exec", Path("/bin/sh")),
            ("list", Path("/Users")),
            ("stat", Path("/Users")),
            ("list", real_home),
            ("stat", real_home),
        ],
    )

    assert outcomes == {
        ("create", Path("/etc/test")): "EPERM",
        ("read", Path("/etc/passwd")): "EPERM",
        ("exec", Path("/bin/sh")): "ok",
        ("list", Path("/Users")): "EPERM",
        ("stat", Path("/Users")): "ok",
        ("list", real_home): "EPERM",
        ("stat", real_home): "ok",
    }


@pytest.mark.darwin
def test_host_temp_roots_are_denied(
    basic_sandbox: Path, launch: Launch, host_tmp_canary: Path
) -> None:
    private_canary = Path("/private") / host_tmp_canary.relative_to("/")
    checks: list[tuple[PathOp, Path]] = [
        ("create", Path("/tmp/sandbox-test")),
        ("create", Path("/private/tmp/sandbox-test")),
        ("read", host_tmp_canary),
        ("read", private_canary),
        ("list", Path("/tmp")),
    ]

    outcomes = probe_paths(launch, basic_sandbox, checks)

    assert set(outcomes.values()) == {"EPERM"}


@pytest.mark.darwin
def test_tmpdir_and_home_live_in_the_sessions_root(
    basic_sandbox: Path, launch: Launch, sessions_root: Path
) -> None:
    result = launch(
        basic_sandbox, 'printf "%s\\n%s\\n%s" "$TMPDIR" "$HOME" "$CLAUDE_CODE_TMPDIR"'
    )

    tmpdir, home, claude_code_tmpdir = result.stdout.splitlines()
    root = os.path.realpath(sessions_root)
    assert tmpdir.startswith(f"{root}/")
    assert home.startswith(f"{root}/")
    assert claude_code_tmpdir == tmpdir


@pytest.mark.darwin
def test_the_terminal_cannot_be_written(basic_sandbox: Path, launch: Launch) -> None:
    result = launch(
        basic_sandbox,
        "echo STARTED; printf '\\a' > /dev/tty && echo WROTE",
        tty_reply="",
    )

    assert "STARTED" in result.stdout
    assert "WROTE" not in result.stdout
