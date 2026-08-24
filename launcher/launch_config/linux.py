"""What to launch on Linux, and the bubblewrap arguments that constrain it.

Pure. Reads no files, runs no subprocesses, prints nothing.

Order is load-bearing here too, for a different reason than on macOS.
Bubblewrap mount destinations overlay, so a bind emitted later can cover one
emitted earlier, and it resolves destinations against its own intermediate root
rather than the host's filesystem. That second property is why some of the
apparent repetition in the resolve logic is real: a declared path that is itself
a symlink cannot be a mount destination once an enclosing bind has exposed it,
and no ordering of the binds avoids that.
"""

from dataclasses import dataclass
from pathlib import Path
from typing import Mapping, Sequence

from launcher.build_spec import SandboxBuildSpecLinux
from launcher.constants import (
    BWRAP_ARGS,
    CA_BUNDLE,
    CA_CERT,
    NETWORK,
    PASSWD,
    WARN_PREFIX,
)
from launcher.host_state import DeclaredDir, DeclaredPath, GitState, HostStateLinux
from launcher.launch_config.shared import SandboxLaunchConfig
from launcher.session_state import SessionStateLinux

NIX_STORE = Path("/nix/store")
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

# Bound unconditionally, so a symlink target under any of them is already
# reachable and needs no bind of its own.
ETC_PREFIXES = (
    Path("/etc/resolv.conf"),
    Path("/etc/passwd"),
    Path("/etc/ssl/certs"),
    Path("/etc/static"),
    Path("/etc/pki"),
)


@dataclass(frozen=True, kw_only=True)
class _DeclaredBinds:
    """The six accumulators the bash built, kept apart because their emission
    order in the argument list differs from the order they are computed in."""

    dir_binds: tuple[str, ...]
    ro_dir_binds: tuple[str, ...]
    file_binds: tuple[str, ...]
    ro_file_binds: tuple[str, ...]
    parent_dirs: tuple[str, ...]
    symlink_targets: tuple[str, ...]
    warnings: tuple[str, ...]


@dataclass(frozen=True, kw_only=True)
class SandboxLaunchConfigLinux(SandboxLaunchConfig):
    bwrap_args: tuple[str, ...]
    # Applied inside pasta's namespace before bubblewrap runs.
    delete_default_route: bool
    sysctls: Mapping[str, str]
    nft_rules: tuple[str, ...]


def _is_already_bound(path: Path, prefixes: Sequence[Path]) -> bool:
    return any(path == prefix or prefix in path.parents for prefix in prefixes)


def _get_bound_prefixes(
    spec: SandboxBuildSpecLinux, host: HostStateLinux, git: GitState | None
) -> list[Path]:
    """Everything already exposed, so nothing gets bound over it twice."""
    prefixes: list[Path] = []
    if spec.allow_nix:
        prefixes.append(NIX_STORE)
    else:
        prefixes += list(host.closure_paths)

    prefixes += [
        declared.expanded_path
        for declared in host.declared
        if isinstance(declared, DeclaredDir)
    ]
    prefixes.append(host.cwd)
    prefixes += list(ETC_PREFIXES)
    if git is not None:
        prefixes.append(git.repo_root)
        prefixes.append(git.common_dir)
    return prefixes


def _get_declared_binds(
    host: HostStateLinux, prefixes: Sequence[Path]
) -> _DeclaredBinds:
    """Bind each declared path, and everything its symlinks lead to.

    Resolved targets are always bound read-only regardless of the declared
    mode, and only when they are in the nix store: a target anywhere else would
    let an agent plant a symlink that expands the sandbox on the next launch.
    Store paths are exempt because they are immutable and agent-unwritable.
    """
    dir_binds: list[str] = []
    ro_dir_binds: list[str] = []
    file_binds: list[str] = []
    ro_file_binds: list[str] = []
    parent_dirs: list[str] = []
    symlink_targets: list[str] = []
    warnings: list[str] = []
    resolved: set[Path] = set()
    seen_parents: set[Path] = set()

    def ensure_parent_dirs(path: Path) -> None:
        """--dir entries for ancestors bubblewrap has not been told about.

        Needed whenever something is bound at a path whose parents do not exist
        in the sandbox yet, such as under the ephemeral HOME tmpfs. These are
        not added to the bound prefixes: --dir creates an empty directory, it
        does not expose its contents, so a sibling still needs its own bind.
        """
        current = path.parent
        while current != Path("/"):
            if _is_already_bound(current, prefixes) or current in seen_parents:
                break
            parent_dirs.extend(["--dir", str(current)])
            seen_parents.add(current)
            current = current.parent

    def add_symlink_target(target: Path) -> None:
        if target in resolved:
            return
        resolved.add(target)
        if _is_already_bound(target, prefixes):
            return
        if NIX_STORE not in target.parents:
            warnings.append(
                f"{WARN_PREFIX} ignoring symlink to '{target}' — target is outside "
                f"permitted paths; declare it as a rwDir, rwFile, roDir or roFile "
                f"to allow access"
            )
            return
        symlink_targets.extend(["--ro-bind", str(target), str(target)])
        ensure_parent_dirs(target)

    def bind_file(declared: DeclaredPath) -> None:
        path = declared.expanded_path
        flag = "--bind" if declared.mode == "rw" else "--ro-bind"
        target = file_binds if declared.mode == "rw" else ro_file_binds
        if not declared.symlink_chain:
            target.extend([flag, str(path), str(path)])
            return
        for hop in declared.symlink_chain:
            add_symlink_target(hop)
        # Skipped when an enclosing bind already exposes the symlink itself:
        # bubblewrap resolves mount destinations against its own intermediate
        # root, where an absolute symlink target does not exist, so it cannot
        # create a mountpoint on top of one and dies. Nothing is lost, since the
        # covering bind exposes the link and its targets are bound above.
        if _is_already_bound(path.parent, prefixes):
            return
        final = declared.symlink_chain[-1]
        if NIX_STORE in final.parents:
            target.extend([flag, str(final), str(path)])
            ensure_parent_dirs(path)

    def bind_dir(declared: DeclaredPath) -> None:
        path = declared.expanded_path
        flag = "--bind" if declared.mode == "rw" else "--ro-bind"
        target = dir_binds if declared.mode == "rw" else ro_dir_binds
        if not declared.symlink_chain:
            target.extend([flag, str(path), str(path)])
            return
        for hop in declared.symlink_chain:
            add_symlink_target(hop)
        # Same unmountable-destination case as above. A non-symlink directory is
        # always bound, so a roDir keeps its read-only mode inside a rw parent.
        if not _is_already_bound(path.parent, prefixes):
            target.extend([flag, str(path), str(path)])

    files = [d for d in host.declared if not isinstance(d, DeclaredDir)]
    dirs = [d for d in host.declared if isinstance(d, DeclaredDir)]
    for declared in files:
        bind_file(declared)
    for declared in dirs:
        bind_dir(declared)
    for declared in dirs:
        for chain in declared.inner_symlinks:
            for hop in chain:
                add_symlink_target(hop)

    return _DeclaredBinds(
        dir_binds=tuple(dir_binds),
        ro_dir_binds=tuple(ro_dir_binds),
        file_binds=tuple(file_binds),
        ro_file_binds=tuple(ro_file_binds),
        parent_dirs=tuple(parent_dirs),
        symlink_targets=tuple(symlink_targets),
        warnings=tuple(warnings),
    )


def _get_git_binds(
    spec: SandboxBuildSpecLinux, git: GitState | None
) -> tuple[list[str], list[Path]]:
    """The gitdir read-write, with the code-execution paths bound back read-only.

    A protected path that does not exist yet would otherwise simply be created.
    Binding an empty file over it makes it read-only instead. Bubblewrap
    materialises the mount point on the host, so those get removed at exit if
    they are still empty.
    """
    if git is None:
        return [], []
    args = ["--bind", str(git.common_dir), str(git.common_dir)]
    masked: list[Path] = []
    for protected in git.protected_dirs:
        args.extend(["--ro-bind", str(protected), str(protected)])
    for protected, exists in git.protected_files.items():
        if exists:
            args.extend(["--ro-bind", str(protected), str(protected)])
        else:
            args.extend(["--ro-bind", str(spec.empty_file), str(protected)])
            masked.append(protected)
    return args, masked


def _get_nft_rules(
    proxy_port: int | None, allowed_local_ports: Sequence[int] | None
) -> list[str]:
    """The ruleset applied inside pasta's namespace, in `nft -f` syntax.

    Restricted mode drops everything by default and permits only in-namespace
    loopback and TCP to the proxy. Open mode keeps the default route and drops
    only traffic addressed to the pasta gateway, which is what blocks host
    loopback services without touching internet traffic, whose destinations are
    real server addresses rather than the gateway.
    """
    if allowed_local_ports is None:
        # allowedLocalPorts is TCP-only; null means every host-local TCP port.
        matches = ["meta l4proto tcp"]
    else:
        matches = [f"tcp dport {port}" for port in allowed_local_ports]

    rules = ["add table ip sandbox_filter"]
    if proxy_port is None:
        rules.append(
            "add chain ip sandbox_filter output "
            "{ type filter hook output priority 0 ; policy accept ; }"
        )
    else:
        rules.append(
            "add chain ip sandbox_filter output "
            "{ type filter hook output priority 0 ; policy drop ; }"
        )
        rules.append("add rule ip sandbox_filter output oif lo accept")

    if matches:
        # DNAT from sandbox loopback needs route_localnet, and the translated
        # flow needs SNAT so pasta sees it as coming from the namespace address.
        rules += [
            "add table ip sandbox_nat",
            "add chain ip sandbox_nat output "
            "{ type nat hook output priority -100 ; policy accept ; }",
            "add chain ip sandbox_nat postrouting "
            "{ type nat hook postrouting priority 100 ; policy accept ; }",
        ]
        rules += [
            f"add rule ip sandbox_nat output ip daddr 127.0.0.1 {match} "
            f"dnat to {PASTA_GATEWAY_IP}"
            for match in matches
        ]
        rules += [
            f"add rule ip sandbox_nat postrouting ip saddr 127.0.0.1 "
            f"ip daddr {PASTA_GATEWAY_IP} {match} masquerade"
            for match in matches
        ]

    if proxy_port is not None:
        rules.append(
            f"add rule ip sandbox_filter output ip daddr {PASTA_GATEWAY_IP} "
            f"tcp dport {proxy_port} accept"
        )
    rules += [
        f"add rule ip sandbox_filter output ip daddr {PASTA_GATEWAY_IP} {match} accept"
        for match in matches
    ]
    if proxy_port is None:
        rules.append(
            f"add rule ip sandbox_filter output ip daddr {PASTA_GATEWAY_IP} drop"
        )
    return rules


def _get_computed_env(
    spec: SandboxBuildSpecLinux, host: HostStateLinux, session: SessionStateLinux
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
    session: SessionStateLinux,
    git: GitState | None,
    binds: _DeclaredBinds,
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
    args += list(git_args)

    if session.proxy is not None:
        bundle = session.session_dir / CA_BUNDLE
        cert = session.session_dir / CA_CERT
        args += ["--ro-bind", str(bundle), str(SANDBOX_CA_BUNDLE)]
        args += ["--ro-bind", str(cert), str(SANDBOX_CA_CERT)]

    args += ["--symlink", str(spec.shell), "/bin/sh"]
    args += ["--symlink", str(spec.dependencies.env), "/usr/bin/env"]
    args += ["--unshare-all", "--hostname", "sandbox"]
    args += ["--uid", str(host.uid), "--gid", str(host.gid)]
    args += ["--share-net", "--die-with-parent"]
    args += ["--chdir", str(host.cwd)]
    return args


def compute_launch_config(
    spec: SandboxBuildSpecLinux,
    host: HostStateLinux,
    session: SessionStateLinux,
) -> SandboxLaunchConfigLinux:
    git = host.git
    prefixes = _get_bound_prefixes(spec, host, git)
    binds = _get_declared_binds(host, prefixes)
    git_args, masked = _get_git_binds(spec, git)

    proxy_port = session.proxy.port if session.proxy is not None else None
    sysctls: dict[str, str] = {}
    if spec.allowed_local_ports is None or spec.allowed_local_ports:
        sysctls = {path: "1" for path in ROUTE_LOCALNET_SYSCTLS}

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
    argv_after_env = [
        str(spec.dependencies.bwrap),
        "--args",
        "3",
        str(spec.pre_entry_script),
        str(spec.sandboxed_binary),
    ]

    return SandboxLaunchConfigLinux(
        argv_before_env=tuple(argv_before_env),
        argv_after_env=tuple(argv_after_env),
        passwd=f"user:x:{host.uid}:{host.gid}:sandbox user:{host.real_home}:/bin/sh\n",
        cleanup=(),
        cleanup_if_empty=tuple(masked),
        warnings=binds.warnings,
        bwrap_args=tuple(
            _get_bwrap_args(spec, host, session, git, binds, git_args)
        ),
        delete_default_route=session.proxy is not None,
        sysctls=sysctls,
        nft_rules=tuple(_get_nft_rules(proxy_port, spec.allowed_local_ports)),
    )
