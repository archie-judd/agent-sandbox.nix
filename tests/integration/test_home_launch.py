import os
import subprocess
from pathlib import Path

import pytest

from harness.build import BuildSandbox
from harness.launch import Launch


@pytest.fixture
def store_gitconfig(tmp_path: Path) -> Path:
    source = tmp_path / "test-home-cwd-gitconfig"
    source.write_text("[user]\n\tname = Test\n\temail = test@test.com\n")
    result = subprocess.run(
        ["nix-store", "--add", str(source)], capture_output=True, text=True, check=True
    )
    return Path(result.stdout.strip())


def _link_gitconfig(home: Path, store_gitconfig: Path) -> None:
    (home / ".config" / "git").mkdir(parents=True)
    (home / ".config" / "git" / "config").symlink_to(store_gitconfig)


@pytest.fixture
def home_repo(fake_home: Path, store_gitconfig: Path) -> Path:
    _link_gitconfig(fake_home, store_gitconfig)
    (fake_home / "secret.txt").write_text("home-secret-content\n")
    (fake_home / "project").mkdir()
    subprocess.run(["git", "init", "-q", str(fake_home)], check=True)
    return fake_home


@pytest.fixture
def sandbox(build_sandbox: BuildSandbox) -> Path:
    return build_sandbox("bound-git-config-ro")


def test_a_home_launch_without_a_terminal_is_refused(
    sandbox: Path, launch: Launch, home_repo: Path
) -> None:
    result = launch(sandbox, "echo LAUNCHED", cwd=home_repo)

    assert result.returncode == 1
    assert "no terminal to confirm on" in result.stderr
    assert "LAUNCHED" not in result.stdout


@pytest.mark.parametrize("reply", ["n", ""], ids=["declined", "empty answer"])
def test_a_home_launch_not_confirmed_is_refused(
    sandbox: Path, launch: Launch, home_repo: Path, reply: str
) -> None:
    result = launch(sandbox, "echo LAUNCHED", cwd=home_repo, tty_reply=reply)

    assert result.returncode == 1
    assert "was declined" in result.stdout
    assert "LAUNCHED" not in result.stdout


def test_a_confirmed_home_launch_exposes_the_home(
    sandbox: Path, launch: Launch, home_repo: Path
) -> None:
    script = """
        cat "$HOME/.config/git/config" >/dev/null && echo ROFILE-OK
        cat ./secret.txt >/dev/null && echo HOME-READ-OK
        touch ./written && echo HOME-WRITE-OK
        git var GIT_AUTHOR_IDENT >/dev/null && echo IDENT-OK
    """

    result = launch(sandbox, script, cwd=home_repo, tty_reply="y")

    assert result.returncode == 0, result.stdout
    assert "not masked in this session" in result.stdout
    for marker in ("ROFILE-OK", "HOME-READ-OK", "HOME-WRITE-OK", "IDENT-OK"):
        assert marker in result.stdout


def test_a_home_rooted_repo_keeps_git_with_its_config_read_only(
    sandbox: Path, launch: Launch, home_repo: Path
) -> None:
    script = """
        git rev-parse --show-toplevel
        git --no-pager config core.hooksPath /tmp/evil || echo HOOKS-PATH-DENIED
    """

    result = launch(sandbox, script, cwd=home_repo, tty_reply="y")

    assert result.returncode == 0, result.stdout
    assert "git is disabled" not in result.stdout
    assert os.path.realpath(home_repo) in result.stdout
    assert "HOOKS-PATH-DENIED" in result.stdout


def test_a_launch_above_home_is_refused_even_when_confirmed(
    sandbox: Path, launch: Launch, home_repo: Path, store_gitconfig: Path
) -> None:
    inner_home = home_repo / "inner"
    _link_gitconfig(inner_home, store_gitconfig)

    result = launch(sandbox, "echo LAUNCHED", cwd=home_repo, home=inner_home, tty_reply="y")

    assert result.returncode == 1
    assert "sits above your home directory" in result.stdout
    assert "LAUNCHED" not in result.stdout


def test_a_launch_below_home_is_ordinary(
    sandbox: Path, launch: Launch, home_repo: Path
) -> None:
    script = """
        echo LAUNCHED
        if cat "$HOME/secret.txt" >/dev/null 2>&1; then echo HOME-LEAKED; fi
    """

    result = launch(sandbox, script, cwd=home_repo / "project")

    assert result.returncode == 0, result.stderr
    assert "LAUNCHED" in result.stdout
    assert "not masked in this session" not in result.stderr
    assert "HOME-LEAKED" not in result.stdout
