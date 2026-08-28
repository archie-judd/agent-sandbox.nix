"""The seatbelt profile, as ordered sections. compute.py assembles these and
owns the order, which is load-bearing: seatbelt is last-match-wins."""

from pathlib import Path
from typing import Sequence

from launcher.lib.host_state import DeclaredDir, DeclaredPath

HEADER = (
    "(version 1)",
    "(deny default)",
)

PROCESS_CONTROL = (
    "",
    ";; Process control",
    "(allow process-fork)",
    "(allow signal)",
)

# sysctl({1, 49, pid}) (KERN_PROCARGS2) returns the argv+envp of any host-UID
# process; the name-deny catches integer-MIB callers too, because the kernel
# resolves those to the same canonical names. Host-identifying OIDs
# (kern.hostname, kern.uuid, hw.model) are deliberately not denied: seatbelt
# does not intercept them through this filter, and denying kern.hostname
# breaks uname(2).
SYSCTLS = (
    "",
    ";; sysctls",
    "(allow sysctl-read)",
    ";; These three are the env-var exfil path. Do not remove.",
    "(deny sysctl-read",
    '  (sysctl-name "kern.procargs")',
    '  (sysctl-name "kern.procargs2")',
    '  (sysctl-name-regex #"^kern\\.proc\\."))',
)

MACH_IPC = (
    "",
    ";; Mach IPC — system services, security framework, FSEvents",
    '(allow mach-lookup (global-name-prefix "com.apple.system."))',
    '(allow mach-lookup (global-name-prefix "com.apple.SystemConfiguration."))',
    '(allow mach-lookup (global-name "com.apple.securityd.xpc"))',
    '(allow mach-lookup (global-name "com.apple.SecurityServer"))',
    '(allow mach-lookup (global-name "com.apple.trustd.agent"))',
    '(allow mach-lookup (global-name "com.apple.FSEvents"))',
    '(allow mach-lookup (global-name "com.apple.diagnosticd"))',
    "(allow mach-register)",
    "(allow ipc-posix-shm-read-data)",
    "(allow ipc-posix-shm-write-data)",
    "(allow ipc-posix-shm-write-create)",
)

# /Library/Preferences is deliberately absent: its plists leak host identity.
# The /System/Volumes deny is load-bearing: /Library, /Users and /private/var
# are firmlinked from /System/Volumes/Data, so the /System allow would
# otherwise expose the entire data volume by its canonical address.
SYSTEM_LIBRARIES = (
    "",
    ";; System libraries & frameworks",
    "(allow file-read*",
    '  (subpath "/usr/lib")',
    '  (subpath "/usr/bin")',
    '  (subpath "/usr/share")',
    '  (subpath "/bin")',
    '  (subpath "/System"))',
    ";; ...but not the data volume, which is reachable through /System/Volumes",
    ";; and would bypass every narrower deny below. Do not remove.",
    '(deny file-read* (subpath "/System/Volumes"))',
)

# Without /private/var/db/mds, SecTrustEvaluate can fail with
# errSecInternalComponent and every TLS connection breaks.
KEYCHAINS = (
    "",
    ";; Security framework — system keychains & trust databases",
    "(allow file-read*",
    '  (subpath "/private/var/db/mds")',
    '  (subpath "/Library/Keychains")',
    '  (literal "/private/var/run/systemkeychaincheck.done"))',
)

NIX_STORE = (
    "",
    ";; Nix store — read all, exec only the closure below",
    "(allow file-read-metadata",
    '  (literal "/nix")',
    '  (literal "/nix/store"))',
    '(allow file-read* (subpath "/nix/store"))',
)

TIMEZONE = (
    "",
    ";; Timezone",
    '(allow file-read* (subpath "/private/var/db/timezone"))',
)


def process_exec(cwd: Path) -> list[str]:
    return [
        "",
        ";; Process execution — per-store-path rules come from the closure below",
        f'(allow process-exec (subpath "{cwd}"))',
        '(allow process-exec (literal "/bin/sh"))',
        '(allow process-exec (literal "/bin/bash"))',
        '(allow process-exec (literal "/usr/bin/env"))',
    ]


def device_nodes(tty: Path | None) -> list[str]:
    # /dev/tty (the controlling-terminal alias) is deliberately absent: it
    # bypasses piped stdin to prompt the human, and opens TIOCSTI injection
    # into the parent shell. Pty slave access is pinned to the one terminal
    # the wrapper was launched on, or omitted entirely when stdin is not a
    # terminal.
    lines = [
        "",
        ";; Device nodes & terminal I/O",
        "(allow file-read*",
        '  (literal "/dev/null")',
        '  (literal "/dev/urandom")',
        '  (literal "/dev/random")',
        '  (literal "/dev/zero")',
        '  (literal "/dev/ptmx")',
        '  (literal "/private/var/select/sh"))',
        '(allow file-write* (literal "/dev/null"))',
    ]
    if tty is None:
        lines += [
            "(allow file-read* file-write*",
            '  (literal "/dev/ptmx")',
            '  (regex #"^/dev/fd/"))',
            '(allow file-ioctl (literal "/dev/ptmx"))',
        ]
    else:
        lines += [
            "(allow file-read* file-write*",
            '  (literal "/dev/ptmx")',
            '  (regex #"^/dev/fd/")',
            f'  (literal "{tty}"))',
            "(allow file-ioctl",
            '  (literal "/dev/ptmx")',
            f'  (literal "{tty}"))',
        ]
    lines += [
        "(allow file-read-metadata",
        '  (literal "/dev/stdout")',
        '  (literal "/dev/stderr")',
        '  (literal "/dev/stdin")',
        '  (literal "/dev/dtracehelper"))',
    ]
    return lines


def dns_tls(
    passwd: Path, ca_bundle: Path | None, ca_cert: Path | None
) -> list[str]:
    # Session directory files are granted by name, never by subpath: the
    # directory also holds proxy.pid, and a readable pid file reconstructs
    # the process enumeration the kern.proc.* denies exist to prevent.
    lines = [
        "",
        ";; DNS, TLS & name resolution",
        "(allow file-read*",
        '  (literal "/private/etc/resolv.conf")',
        '  (literal "/private/var/run/resolv.conf")',
        '  (subpath "/private/etc/ssl")',
        f'  (literal "{passwd}")',
        '  (literal "/private/etc/localtime")',
        '  (subpath "/private/etc/static")',
        '  (literal "/private/etc/hosts"))',
    ]
    if ca_bundle is not None and ca_cert is not None:
        lines += [
            "(allow file-read*",
            f'  (literal "{ca_bundle}")',
            f'  (literal "{ca_cert}"))',
        ]
    return lines


def temp_dirs(tmpdir: Path) -> list[str]:
    # The host temp roots are deliberately absent. /tmp and /private/tmp are
    # shared with every other user of the machine, and /private/var/folders
    # holds 0400/0600 user secrets reachable via the host UID. Tools must
    # respect $TMPDIR.
    return [
        "",
        ";; Temp directory",
        f'(allow file-read* file-write* (subpath "{tmpdir}"))',
    ]


def traversal(
    real_home: Path, sandbox_home: Path, repo_root_parent: Path | None
) -> list[str]:
    # "/" gets file-read* because process startup requires readdir on root.
    lines = [
        "",
        ";; Filesystem traversal — stat() only, no readdir()",
        '(allow file-read* (literal "/"))',
        "(allow file-read-metadata",
        '  (literal "/var")',
        '  (literal "/dev")',
        '  (literal "/private")',
        '  (literal "/private/var")',
        '  (literal "/etc")',
        '  (literal "/private/etc")',
        '  (literal "/private/var/db")',
        '  (literal "/Users")',
        f'  (literal "{real_home}")',
        f'  (literal "{sandbox_home / ".local"}")',
        f'  (literal "{sandbox_home / ".cache"}")',
        f'  (literal "{sandbox_home / ".local/share"}")',
        f'  (literal "{sandbox_home / ".local/state"}")',
    ]
    if repo_root_parent is None:
        lines[-1] = lines[-1] + ")"
    else:
        lines.append(f'  (literal "{repo_root_parent}"))')
    return lines


def ancestor_metadata(ancestors: Sequence[Path]) -> list[str]:
    if not ancestors:
        return []
    return ["", ";; Ancestor directories, for traversal only"] + [
        f'(allow file-read-metadata (literal "{ancestor}"))' for ancestor in ancestors
    ]


def sandbox_home(home: Path) -> list[str]:
    # Exec too: copilot stores spawn helper binaries in its home.
    return [
        "",
        ";; Sandbox HOME",
        f'(allow file-read* file-write* process-exec (subpath "{home}"))',
    ]


def workspace(cwd: Path, repo_root: Path | None, git_dir: Path | None) -> list[str]:
    lines = [
        "",
        ";; Working directory & repository",
        f'(allow file-read* file-write* (subpath "{cwd}"))',
    ]
    if repo_root is not None:
        lines.append(f'(allow file-read* (subpath "{repo_root}"))')
    if git_dir is not None:
        lines.append(f'(allow file-read* file-write* (subpath "{git_dir}"))')
    return lines


def declared_paths(declared: Sequence[DeclaredPath]) -> list[str]:
    # A roDir nested inside an rwDir stays writable: seatbelt matches per
    # operation, so fixing that needs explicit denies, not reordering.
    if not declared:
        return []
    lines = ["", ";; Declared directories & files"]
    for entry in declared:
        path = entry.expanded_path
        is_dir = isinstance(entry, DeclaredDir)
        if entry.mode == "rw" and is_dir:
            lines.append(f'(allow file-read* file-write* (subpath "{path}"))')
            lines.append(f'(allow process-exec (subpath "{path}"))')
        elif entry.mode == "rw":
            lines.append(f'(allow file-read* file-write* (literal "{path}"))')
        elif is_dir:
            lines.append(f'(allow file-read* (subpath "{path}"))')
        else:
            lines.append(f'(allow file-read* (literal "{path}"))')
    return lines


def git_protection(
    protected_dirs: Sequence[Path], protected_files: Sequence[Path]
) -> list[str]:
    # Emitted after the declared-path allows, so a declared rwDir containing
    # the gitdir cannot re-grant writes.
    if not protected_dirs and not protected_files:
        return []
    lines = ["", ";; Git protected paths — deny writes, keep reads"]
    lines += [f'(deny file-write* (subpath "{path}"))' for path in protected_dirs]
    lines += [f'(deny file-write* (literal "{path}"))' for path in protected_files]
    return lines


def closure(store_paths: Sequence[Path]) -> list[str]:
    lines = ["", ";; Nix store — only the closure of the allowed packages"]
    for store_path in store_paths:
        lines.append(f'(allow file-read* (subpath "{store_path}"))')
        lines.append(f'(allow process-exec (subpath "{store_path}"))')
    return lines


def nix_support(daemon_socket: Path) -> list[str]:
    # Full-store exec so the agent can run results the daemon builds after
    # sandbox start, which are not in the closure.
    return [
        "",
        ";; Nix daemon support",
        '(allow file-read-metadata (subpath "/nix/var"))',
        '(allow file-read-metadata (subpath "/etc/nix") (subpath "/private/etc/nix"))',
        "(allow network-outbound",
        f'  (remote unix-socket (path-literal "{daemon_socket}")))',
        '(allow process-exec (subpath "/nix/store"))',
    ]


def unix_sockets(
    writable_dirs: Sequence[Path],
    connect_dirs: Sequence[Path],
    connect_files: Sequence[Path],
    nested_ro_dirs: Sequence[Path],
    nested_ro_files: Sequence[Path],
) -> list[str]:
    # The nested-ro denies exist because the enclosing writable subpath allow
    # would otherwise let the sandbox bind inside a directory declared
    # read-only; only the nested paths get them, so a writable dir inside a
    # read-only one keeps its grant.
    if not writable_dirs:
        return []
    lines = ["", ";; AF_UNIX sockets — rw grants bind+connect (allowUnixSockets)"]
    for directory in writable_dirs:
        lines.append(
            f'(allow network-bind (local unix-socket (subpath "{directory}")))'
        )
        lines.append(
            f'(allow network-outbound (remote unix-socket (subpath "{directory}")))'
        )
    if connect_dirs or connect_files:
        lines.append(";; ...and ro grants connect")
    for directory in connect_dirs:
        lines.append(
            f'(allow network-outbound (remote unix-socket (subpath "{directory}")))'
        )
    for file in connect_files:
        lines.append(
            f'(allow network-outbound (remote unix-socket (path-literal "{file}")))'
        )
    if nested_ro_dirs or nested_ro_files:
        lines.append(";; ...but never bind in the read-only paths nested inside")
    for directory in nested_ro_dirs:
        lines.append(f'(deny network-bind (local unix-socket (subpath "{directory}")))')
    for file in nested_ro_files:
        lines.append(f'(deny network-bind (local unix-socket (path-literal "{file}")))')
    return lines


def _local_port_rules(allowed_local_ports: Sequence[int] | None) -> list[str]:
    # TCP-only; None means every host-local TCP port.
    if allowed_local_ports is None:
        return ['(allow network-outbound (remote ip "localhost:*"))']
    return [
        f'(allow network-outbound (remote ip "localhost:{port}"))'
        for port in allowed_local_ports
    ]


def network_restricted(
    proxy_port: int, allowed_local_ports: Sequence[int] | None
) -> list[str]:
    # Pinned to the proxy port so other loopback services cannot be reached
    # directly, bypassing the proxy's filtering. UNIX-socket egress is
    # deliberately absent: it would reach any host socket the UID can
    # (terminal IPC, ssh-agent), and the proxy speaks TCP.
    return [
        "",
        ";; Network — localhost only, pinned to the proxy port",
        '(allow network-bind (local ip "localhost:*"))',
        "(allow system-socket)",
        f'(allow network-outbound (remote ip "localhost:{proxy_port}"))',
    ] + _local_port_rules(allowed_local_ports)


def network_open(allowed_local_ports: Sequence[int] | None) -> list[str]:
    # system-socket gates socket(PF_SYSTEM, ...), meaning kernel-control
    # sockets and utun, not AF_UNIX.
    return [
        "",
        ";; Network — open, with loopback and AF_UNIX denied",
        "(allow network*)",
        "(allow system-socket)",
        '(deny network-outbound (remote ip "localhost:*"))',
        "(deny network-outbound (remote unix-socket))",
        ";; Required for DNS: getaddrinfo() resolves over this socket.",
        "(allow network-outbound",
        '  (remote unix-socket (path-literal "/private/var/run/mDNSResponder")))',
    ] + _local_port_rules(allowed_local_ports)
