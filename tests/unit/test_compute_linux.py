from pathlib import Path
from typing import Sequence

from harness.builders import make_host_linux, make_session, make_spec_linux
from launcher.lib.build_spec import PublishedPort
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


def _env(config_argv: Sequence[str]) -> dict[str, str]:
    return dict(arg.split("=", 1) for arg in config_argv if "=" in arg and not arg.startswith("-"))


def test_the_proxy_is_reached_through_the_pasta_gateway() -> None:
    config = compute_launch_config(make_spec_linux(), make_host_linux(), make_session(proxy_port=12345))

    env = _env(config.argv_before_env)
    assert env["HTTP_PROXY"] == env["HTTPS_PROXY"] == "http://10.0.2.2:12345"


def test_no_proxy_is_set_only_when_a_host_port_is_open() -> None:
    closed = compute_launch_config(make_spec_linux(), make_host_linux(), make_session(proxy_port=1))
    opened = compute_launch_config(
        make_spec_linux(allowed_host_ports=(3000,)), make_host_linux(), make_session(proxy_port=1)
    )

    assert "NO_PROXY" not in _env(closed.argv_before_env)
    assert "NO_PROXY" in _env(opened.argv_before_env)


def test_published_ports_become_pasta_forwards() -> None:
    spec = make_spec_linux(
        published_ports=(
            PublishedPort(port=3000, bind_addr="127.0.0.1"),
            PublishedPort(port=4000, bind_addr="0.0.0.0"),
        )
    )

    argv = compute_launch_config(spec, make_host_linux(), make_session()).argv_before_env

    assert _contains_run(argv, ["-t", "127.0.0.1/3000", "-t", "0.0.0.0/4000"])
    assert not _contains_run(argv, ["-t", "none"])


def test_restricted_mode_leaves_dns_to_the_proxy() -> None:
    restricted = compute_launch_config(make_spec_linux(), make_host_linux(), make_session(proxy_port=1))
    open_mode = compute_launch_config(make_spec_linux(), make_host_linux(), make_session())

    assert _contains_run(restricted.bwrap_args, ["--ro-bind", "/dev/null", "/etc/resolv.conf"])
    assert _contains_run(open_mode.bwrap_args, ["--ro-bind", "/etc/resolv.conf", "/etc/resolv.conf"])


def test_the_unix_socket_filter_is_loaded_only_when_sockets_are_off() -> None:
    off = compute_launch_config(make_spec_linux(), make_host_linux(), make_session())
    on = compute_launch_config(make_spec_linux(allow_nix=True), make_host_linux(), make_session())

    assert "--seccomp" in off.bwrap_args
    assert off.seccomp_program is not None
    assert "--seccomp" not in on.bwrap_args
    assert on.seccomp_program is None
