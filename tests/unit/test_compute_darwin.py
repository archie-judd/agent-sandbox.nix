from pathlib import Path

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


def _profile(workspace_dir: Path = Path("/home/someone/project")) -> list[str]:
    config = compute_launch_config(
        make_spec_darwin(), make_host_darwin(workspace_dir=workspace_dir), make_session_darwin()
    )
    return list(config.seatbelt_profile_lines)


def test_the_data_volume_deny_follows_the_system_allow() -> None:
    lines = _profile()

    allow = lines.index('  (subpath "/System"))')
    deny = lines.index('(deny file-read* (subpath "/System/Volumes"))')
    assert allow < deny


def test_library_preferences_is_never_granted() -> None:
    assert not any("/Library/Preferences" in line for line in _profile())


def test_process_snooping_sysctls_are_denied_after_the_allow() -> None:
    lines = _profile()

    allow = lines.index("(allow sysctl-read)")
    assert lines[allow + 2 : allow + 6] == [
        "(deny sysctl-read",
        '  (sysctl-name "kern.procargs")',
        '  (sysctl-name "kern.procargs2")',
        '  (sysctl-name-regex #"^kern\\.proc\\."))',
    ]


def test_ancestors_between_home_and_workspace_are_stat_only() -> None:
    lines = _profile(Path("/home/someone/a/b/c/d/e"))

    for ancestor in ("a", "a/b", "a/b/c", "a/b/c/d"):
        assert f'(allow file-read-metadata (literal "/home/someone/{ancestor}"))' in lines


def test_nothing_under_usr_bin_is_executable_but_env() -> None:
    exec_lines = [line for line in _profile() if line.startswith("(allow process-exec")]

    assert [line for line in exec_lines if "/usr/bin" in line] == [
        '(allow process-exec (literal "/usr/bin/env"))'
    ]
