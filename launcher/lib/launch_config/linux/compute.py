"""What to launch on Linux, and the order the arguments constraining it go in.

Pure. Reads no files, runs no subprocesses, prints nothing.

Order is load-bearing here, the way it is in darwin/compute.py, for a different
reason. Bubblewrap mount destinations overlay, so a bind emitted later can cover
one emitted earlier. binds.py works out which binds each path needs and groups
them; this module decides the sequence they are emitted in, and that sequence is
what is enforced.
"""

from dataclasses import dataclass
from pathlib import Path
from typing import Mapping, Sequence

from launcher.lib.build_spec import SandboxBuildSpecLinux
from launcher.lib.constants import (
    CA_BUNDLE,
    CA_CERT,
    NETWORK,
    PASSWD,
    SECCOMP_FD,
    SECCOMP_FILTER,
)
from launcher.lib.host_state import GitState, HostStateLinux
from launcher.lib.launch_config.linux.binds import (
    NIX_STORE,
    DeclaredBinds,
    get_bound_prefixes,
    get_declared_binds,
    get_git_binds,
)
from launcher.lib.launch_config.linux.nftables import get_nft_rules
from launcher.lib.launch_config.linux.seccomp import get_unix_deny_filter
from launcher.lib.launch_config.shared import (
    SandboxLaunchConfig,
    get_sessions_root_warnings,
    get_usable_git_state,
)
from launcher.lib.session_state import SessionState

SANDBOX_TMPDIR = Path("/tmp")
# Where the sandbox sees its certificates and identity. Fixed paths rather than
# the session directory's own, so nothing inside learns where that is.
SANDBOX_CA_BUNDLE = Path("/tmp/sandbox-ca-bundle.pem")
SANDBOX_CA_CERT = Path("/tmp/sandbox-ca-cert.pem")
SANDBOX_PASSWD = Path("/etc/passwd")

# pasta forwards <gateway>:<port> to 127.0.0.1:<port> on the host, which is both
# how the sandbox reaches the proxy and why the gateway has to be firewalled in
# open mode.
PASTA_GATEWAY_IP = "10.0.2.2"
PASTA_NAMESPACE_IP = "10.0.2.1"
PASTA_NETMASK = "255.255.255.0"
PASTA_FLAGS = (
    "-4",
    "--config-net",
    "-a",
    PASTA_NAMESPACE_IP,
    "-g",
    PASTA_GATEWAY_IP,
    "-n",
    PASTA_NETMASK,
    "-t",
    "none",
    "-u",
    "none",
    "-T",
    "none",
    "-U",
    "none",
    "--",
)

ROUTE_LOCALNET_SYSCTLS = (
    "/proc/sys/net/ipv4/conf/all/route_localnet",
    "/proc/sys/net/ipv4/conf/default/route_localnet",
)


@dataclass(frozen=True, kw_only=True)
class NetworkConfig:
    """Everything the in-namespace entry point applies, as one artifact.

    It carries the binary paths too, so that entry point holds no policy and no
    hardcoded paths: it reads this, does what it says, and execs onwards.
    """

    nft: Path
    ip: Path
    # Only in restricted mode. Belt and braces over the drop policy, but it is a
    # security control and turning it into a no-op is not this port's call.
    delete_default_route: bool
    # /proc/sys writes an nft ruleset cannot express.
    sysctls: Mapping[str, str]
    rules: tuple[str, ...]
    # The AF_UNIX-denying BPF program to leave open on SECCOMP_FD for
    # bubblewrap, or None with allowUnixSockets. In here rather than beside
    # the bwrap args because the entry point is the only process that can
    # open a descriptor bubblewrap inherits: pasta does not pass one to its
    # child.
    seccomp_filter: Path | None


@dataclass(frozen=True, kw_only=True)
class SandboxLaunchConfigLinux(SandboxLaunchConfig):
    bwrap_args: tuple[str, ...]
    network: NetworkConfig
    # The program network.seccomp_filter points at, carried as a value so the
    # whole launch stays assertable without a filesystem. write.py writes it.
    seccomp_program: bytes | None


def _get_computed_env(
    spec: SandboxBuildSpecLinux, host: HostStateLinux, session: SessionState
) -> list[str]:
    """The environment the launcher decides, as K=V arguments to env -i.

    Bubblewrap passes its own environment through, so these reach the sandbox
    without --setenv. Dropping --clearenv and --setenv also keeps the declared
    values off /proc/<pid>/cmdline, which is world-readable, and puts them in
    /proc/<pid>/environ, which is not.
    """
    pairs = [
        f"HOME={host.real_home}",
        f"SHELL={spec.shell}",
        f"PATH={spec.sandbox_path}",
        f"SSL_CERT_DIR={spec.cacert_dir}",
        f"TMPDIR={SANDBOX_TMPDIR}",
        "GIT_CONFIG_COUNT=1",
        "GIT_CONFIG_KEY_0=user.useConfigOnly",
        "GIT_CONFIG_VALUE_0=true",
    ]
    if host.term is not None:
        pairs.insert(1, f"TERM={host.term}")
    if host.nix_daemon_socket is not None:
        pairs.append(f"NIX_DAEMON_SOCKET_PATH={host.nix_daemon_socket}")

    if session.proxy is None:
        return pairs + [
            f"SSL_CERT_FILE={spec.cacert_bundle}",
            f"NIX_SSL_CERT_FILE={spec.cacert_bundle}",
        ]

    proxy_url = f"http://{PASTA_GATEWAY_IP}:{session.proxy.port}"
    return pairs + [
        f"SSL_CERT_FILE={SANDBOX_CA_BUNDLE}",
        f"NIX_SSL_CERT_FILE={SANDBOX_CA_BUNDLE}",
        f"NODE_EXTRA_CA_CERTS={SANDBOX_CA_CERT}",
        f"REQUESTS_CA_BUNDLE={SANDBOX_CA_BUNDLE}",
        f"HTTP_PROXY={proxy_url}",
        f"HTTPS_PROXY={proxy_url}",
        f"http_proxy={proxy_url}",
        f"https_proxy={proxy_url}",
    ]


def _get_bwrap_args(
    spec: SandboxBuildSpecLinux,
    host: HostStateLinux,
    session: SessionState,
    git: GitState | None,
    binds: DeclaredBinds,
    git_args: Sequence[str],
) -> list[str]:
    """Everything bubblewrap reads from the args file, in emission order."""
    args: list[str] = []

    if session.proxy is None:
        # systemd-resolved points /etc/resolv.conf at a stub listener on the
        # host's own loopback, which inside pasta's namespace is a different
        # loopback with nothing on it. The systemd file holds the real upstream
        # addresses, which are routable from the namespace.
        if host.resolv_conf_names_loopback and host.systemd_resolv_conf is not None:
            resolv_conf = host.systemd_resolv_conf
        else:
            resolv_conf = Path("/etc/resolv.conf")
        args += ["--ro-bind", str(resolv_conf), "/etc/resolv.conf"]
    else:
        # DNS is the proxy's job in restricted mode; the sandbox resolves nothing.
        args += ["--ro-bind", "/dev/null", "/etc/resolv.conf"]

    if spec.allow_nix:
        args += ["--ro-bind", str(NIX_STORE), str(NIX_STORE)]
        args += ["--ro-bind-try", "/nix/var", "/nix/var"]
    else:
        args += ["--tmpfs", str(NIX_STORE)]
        for store_path in host.closure_paths:
            args += ["--ro-bind", str(store_path), str(store_path)]

    args += ["--ro-bind", str(session.session_dir / PASSWD), str(SANDBOX_PASSWD)]
    args += ["--ro-bind", str(spec.hosts_file), "/etc/hosts"]
    args += ["--ro-bind-try", "/etc/ssl/certs", "/etc/ssl/certs"]
    args += ["--ro-bind-try", "/etc/static", "/etc/static"]
    args += ["--ro-bind-try", "/etc/pki", "/etc/pki"]
    args += ["--proc", "/proc"]
    args += ["--ro-bind", str(spec.empty_file), "/proc/cmdline"]
    args += ["--ro-bind", str(spec.empty_file), "/proc/sys/kernel/random/boot_id"]
    args += ["--dev", "/dev"]
    args += ["--tmpfs", str(SANDBOX_TMPDIR)]
    args += ["--tmpfs", str(host.real_home)]

    if git is not None:
        args += ["--ro-bind", str(git.repo_root), str(git.repo_root)]
    args += ["--bind", str(host.cwd), str(host.cwd)]

    args += list(binds.dir_binds)
    args += list(binds.ro_dir_binds)
    args += list(binds.file_binds)
    args += list(binds.ro_file_binds)
    args += list(binds.parent_dirs)
    args += list(binds.symlink_targets)
    # Last of the declared-path arguments. Bubblewrap cannot mount onto a
    # symlink it has already planted, and it works through this list in order,
    # so anything wanting a destination under one of these has to come first.
    args += list(binds.parent_symlinks)
    args += list(git_args)

    if session.proxy is not None:
        bundle = session.session_dir / CA_BUNDLE
        cert = session.session_dir / CA_CERT
        args += ["--ro-bind", str(bundle), str(SANDBOX_CA_BUNDLE)]
        args += ["--ro-bind", str(cert), str(SANDBOX_CA_CERT)]

    args += ["--symlink", str(spec.shell), "/bin/sh"]
    args += ["--symlink", str(spec.dependencies.env), "/usr/bin/env"]
    # The descriptor apply_network_rules leaves open, holding the program in
    # network.seccomp_filter. Denies socket(AF_UNIX, ...) with EPERM; see
    # seccomp.py for why the platform needs a syscall filter at all.
    if not spec.allow_unix_sockets:
        args += ["--seccomp", str(SECCOMP_FD)]
    args += ["--unshare-all", "--hostname", "sandbox"]
    args += ["--uid", str(host.uid), "--gid", str(host.gid)]
    args += ["--share-net", "--die-with-parent"]
    args += ["--chdir", str(host.cwd)]
    return args


def compute_launch_config(
    spec: SandboxBuildSpecLinux,
    host: HostStateLinux,
    session: SessionState,
) -> SandboxLaunchConfigLinux:
    # Not host.git: a repository whose root is the home directory, or above it,
    # is refused here and git disabled for the session. Everything below takes
    # the usable state, so nothing binds a root this rejected.
    git, warnings = get_usable_git_state(host)
    warnings += get_sessions_root_warnings(host, session.session_dir)
    prefixes = get_bound_prefixes(spec, host, git)
    binds = get_declared_binds(host, prefixes)
    git_args, masked = get_git_binds(spec, git)

    proxy_port = session.proxy.port if session.proxy is not None else None
    sysctls: dict[str, str] = {}
    if spec.allowed_local_ports is None or spec.allowed_local_ports:
        sysctls = {path: "1" for path in ROUTE_LOCALNET_SYSCTLS}

    if spec.allow_unix_sockets:
        seccomp_program = None
        seccomp_filter = None
    else:
        # launch_checks has already refused any machine the filter cannot be
        # built for, so this cannot raise here.
        seccomp_program = get_unix_deny_filter(host.machine)
        seccomp_filter = session.session_dir / SECCOMP_FILTER

    bwrap_args = _get_bwrap_args(spec, host, session, git, binds, git_args)

    argv_before_env = (
        [str(spec.dependencies.pasta)]
        + list(PASTA_FLAGS)
        + [
            str(spec.dependencies.python),
            "-P",
            "-s",
            "-S",
            "-m",
            "launcher.apply_network_rules",
            str(session.session_dir / NETWORK),
            "--",
            str(spec.dependencies.env),
            "-i",
        ]
        + _get_computed_env(spec, host, session)
    )
    # Bubblewrap's arguments are inline rather than read from the args file it
    # also gets written to. --args needs a descriptor, and pasta does not pass
    # an inherited one to its child, so the only place left to open it is the
    # network entry point, which would put bubblewrap's argument passing inside
    # the module that configures the namespace. Inline costs nothing: these are
    # argv entries the whole way, NUL-separated in the artifact and expanded as
    # a quoted array by the stub, so a path containing a space or a newline
    # stays one argument. What it does not do is hide the paths, and nothing was
    # hiding them anyway: they are in the spec, in the world-readable store.
    argv_after_env = (
        [str(spec.dependencies.bwrap)]
        + bwrap_args
        + [str(spec.pre_entry_script), str(spec.sandboxed_binary)]
    )

    ca_bundle = (
        ()
        if session.proxy is None
        else (spec.cacert_bundle, session.session_dir / CA_CERT)
    )

    return SandboxLaunchConfigLinux(
        argv_before_env=tuple(argv_before_env),
        argv_after_env=tuple(argv_after_env),
        passwd=f"user:x:{host.uid}:{host.gid}:sandbox user:{host.real_home}:/bin/sh\n",
        ca_bundle=ca_bundle,
        cleanup=(),
        cleanup_if_empty=tuple(masked),
        warnings=tuple(warnings) + binds.warnings,
        bwrap_args=tuple(bwrap_args),
        network=NetworkConfig(
            nft=spec.dependencies.nft,
            ip=spec.dependencies.ip,
            delete_default_route=session.proxy is not None,
            sysctls=sysctls,
            rules=tuple(
                get_nft_rules(PASTA_GATEWAY_IP, proxy_port, spec.allowed_local_ports)
            ),
            seccomp_filter=seccomp_filter,
        ),
        seccomp_program=seccomp_program,
    )
