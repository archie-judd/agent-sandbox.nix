from typing import Sequence

from harness.builders import make_host_linux, make_session, make_spec_linux
from launcher.lib.launch_config.linux.compute import compute_launch_config


def _contains_run(args: Sequence[str], run: Sequence[str]) -> bool:
    return any(list(args[i : i + len(run)]) == list(run) for i in range(len(args)))


def test_the_hostname_is_neutralised() -> None:
    config = compute_launch_config(make_spec_linux(), make_host_linux(), make_session())

    assert _contains_run(config.bwrap_args, ["--hostname", "sandbox"])


def test_host_fingerprints_in_proc_are_masked() -> None:
    spec = make_spec_linux()

    config = compute_launch_config(spec, make_host_linux(), make_session())

    empty = str(spec.empty_file)
    assert _contains_run(config.bwrap_args, ["--ro-bind", empty, "/proc/cmdline"])
    assert _contains_run(
        config.bwrap_args, ["--ro-bind", empty, "/proc/sys/kernel/random/boot_id"]
    )


def test_passwd_is_a_single_fabricated_user() -> None:
    host = make_host_linux()

    config = compute_launch_config(make_spec_linux(), host, make_session())

    assert config.passwd == f"user:x:{host.uid}:{host.gid}:sandbox user:{host.real_home}:/bin/sh\n"
