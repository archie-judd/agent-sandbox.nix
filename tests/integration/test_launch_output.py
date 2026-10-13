from pathlib import Path

from harness.launch import Launch

VERSION = (Path(__file__).resolve().parent.parent.parent / "version.txt").read_text().strip()


def test_the_version_is_reported_on_stderr(basic_sandbox: Path, launch: Launch) -> None:
    result = launch(basic_sandbox, "true")

    assert result.returncode == 0, result.stderr
    assert f"version: {VERSION}" in result.stderr
    assert "version:" not in result.stdout


def test_the_session_directory_is_reported_on_stderr(
    basic_sandbox: Path, launch: Launch, sessions_root: Path
) -> None:
    result = launch(basic_sandbox, "true")

    assert result.returncode == 0, result.stderr
    (session,) = sessions_root.iterdir()
    assert f"session: {session}" in result.stderr
    assert "session:" not in result.stdout
