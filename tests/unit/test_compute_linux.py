from pathlib import Path
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


CLOSURE = (Path("/nix/store/aaa-coreutils"), Path("/nix/store/bbb-bash"))


def test_allow_nix_binds_the_whole_store_and_nix_var() -> None:
    host = make_host_linux(nix_daemon_socket=Path("/nix/var/nix/daemon-socket/socket"))

    args = compute_launch_config(make_spec_linux(allow_nix=True), host, make_session()).bwrap_args

    assert _contains_run(args, ["--ro-bind", "/nix/store", "/nix/store"])
    assert _contains_run(args, ["--ro-bind-try", "/nix/var", "/nix/var"])
    assert not _contains_run(args, ["--tmpfs", "/nix/store"])


def test_a_daemon_socket_outside_nix_var_is_bound_alone() -> None:
    socket = Path("/tmp/relay/socket")
    host = make_host_linux(nix_daemon_socket=socket)

    args = compute_launch_config(make_spec_linux(allow_nix=True), host, make_session()).bwrap_args

    assert _contains_run(args, ["--ro-bind", str(socket), str(socket)])
    assert str(socket.parent) not in args


def test_without_allow_nix_only_the_closure_is_bound() -> None:
    host = make_host_linux(closure_paths=CLOSURE)

    args = compute_launch_config(make_spec_linux(), host, make_session()).bwrap_args

    assert _contains_run(args, ["--tmpfs", "/nix/store"])
    for store_path in CLOSURE:
        assert _contains_run(args, ["--ro-bind", str(store_path), str(store_path)])
    assert "/nix/var" not in args
