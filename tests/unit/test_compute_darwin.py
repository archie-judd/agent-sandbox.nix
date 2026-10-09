from harness.builders import make_host_darwin, make_session_darwin, make_spec_darwin
from launcher.lib.launch_config.darwin.compute import compute_launch_config


def _env() -> dict[str, str]:
    session = make_session_darwin()
    config = compute_launch_config(make_spec_darwin(), make_host_darwin(), session)
    pairs = [arg.split("=", 1) for arg in config.argv_before_env if "=" in arg]
    return {name: value for name, value in pairs}


def test_home_and_tmpdir_live_in_the_session_directory() -> None:
    session = make_session_darwin()

    env = _env()

    assert env["HOME"] == str(session.sandbox_home)
    assert env["TMPDIR"] == str(session.sandbox_tmpdir)


def test_claude_code_tmpdir_follows_tmpdir() -> None:
    env = _env()

    assert env["CLAUDE_CODE_TMPDIR"] == env["TMPDIR"]
