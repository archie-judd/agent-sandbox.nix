import subprocess
from pathlib import Path

import pytest

from harness.build import BuildSandbox
from harness.launch import Launch

NO_IDENTITY_WARNING = "no git identity declared"
COMMIT = 'git commit --allow-empty -q -m sandbox-commit && git log -1 --format="%an <%ae>|%cn <%ce>"'


@pytest.fixture
def repo(tmp_path: Path) -> Path:
    repo = tmp_path / "repo"
    repo.mkdir()
    subprocess.run(["git", "init", "-q", str(repo)], check=True)
    return repo


def _write_global_config(home: Path, name: str, email: str) -> None:
    (home / ".config" / "git").mkdir(parents=True)
    (home / ".config" / "git" / "config").write_text(f"[user]\n\tname = {name}\n\temail = {email}\n")


def _commit_count(repo: Path) -> int:
    result = subprocess.run(
        ["git", "-C", str(repo), "rev-list", "--all", "--count"], capture_output=True, text=True
    )
    return int(result.stdout.strip() or 0)


def test_without_an_identity_commits_fail_closed_and_the_launch_warns(
    build_sandbox: BuildSandbox, launch: Launch, repo: Path
) -> None:
    result = launch(build_sandbox("git-topologies"), COMMIT, cwd=repo)

    assert NO_IDENTITY_WARNING in result.stderr
    assert "auto-detection is disabled" in result.stderr
    assert result.returncode == 128
    assert _commit_count(repo) == 0


def test_an_identity_declared_in_env_is_used_without_a_warning(
    build_sandbox: BuildSandbox, launch: Launch, repo: Path
) -> None:
    result = launch(build_sandbox("git-identity"), COMMIT, cwd=repo)

    assert result.stdout == (
        "Sandbox Tester <sandbox-tester@example.com>|Sandbox Tester <sandbox-tester@example.com>\n"
    ), result.stderr
    assert NO_IDENTITY_WARNING not in result.stderr


def test_a_read_only_bound_gitconfig_supplies_the_identity_and_stays_read_only(
    build_sandbox: BuildSandbox, launch: Launch, repo: Path, fake_home: Path
) -> None:
    _write_global_config(fake_home, "Bound RO", "bound-ro@example.com")
    config_before = (fake_home / ".config" / "git" / "config").read_text()
    sandbox = build_sandbox("bound-git-config-ro")

    committed = launch(sandbox, COMMIT, cwd=repo)
    appended = launch(sandbox, 'echo "[core]" >> "$HOME/.config/git/config"', cwd=repo)

    assert committed.stdout == (
        "Bound RO <bound-ro@example.com>|Bound RO <bound-ro@example.com>\n"
    ), committed.stderr
    assert appended.returncode == 1
    assert (fake_home / ".config" / "git" / "config").read_text() == config_before


def test_a_read_write_bound_gitconfig_supplies_the_identity(
    build_sandbox: BuildSandbox, launch: Launch, repo: Path, fake_home: Path
) -> None:
    _write_global_config(fake_home, "Bound RW", "bound-rw@example.com")

    result = launch(build_sandbox("bound-git-config-rw"), COMMIT, cwd=repo)

    assert result.stdout == (
        "Bound RW <bound-rw@example.com>|Bound RW <bound-rw@example.com>\n"
    ), result.stderr
