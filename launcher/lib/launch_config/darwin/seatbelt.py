"""The seatbelt profile, as ordered sections.

Data, not decisions: compute.py assembles these in order and owns that order,
which is load-bearing. Seatbelt is last-match-wins, so a reordering that
preserves the rule set can still change what is enforced.

Ported from lib/darwin/seatbelt-profile.nix. The rationale that file carried as
;; comments inside the profile lives here as Python comments instead: the reader
who needs it is the one editing these rules, and a comment that is itself
profile syntax breaks the profile if its ;; is ever lost. What stays in the
emitted file is one-line section headers, so it remains navigable, plus the two
denies whose absence would otherwise look like an oversight.

Every (param "X") from the Nix version is gone. Seatbelt params are string-only,
which is why variable-length lists had to be appended to the file at runtime;
computing the whole profile here removes the constraint. It also removes the
sentinels: a session with no repository omits the repo rules rather than
pointing them at /nonexistent-repo-root, and a session with no tty omits the
pty rule rather than /nonexistent-tty.
"""

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

# Broad sysctl read, with explicit denies for the process-snooping OIDs. Without
# them, sysctl({1, 49, pid}) (KERN_PROCARGS2) returns the full argv+envp of any
# host-UID process, which is a complete exfil path for env-var secrets the host
# shell has set (CLAUDE_CODE_OAUTH_TOKEN, GITHUB_TOKEN, AWS_*) before launching.
# The integer-MIB form of sysctl(2) resolves to the same canonical names
# internally, so the name-deny catches both sysctl() and sysctlbyname() callers.
#
# Host-identifying single OIDs (kern.hostname, kern.uuid, hw.model,
# kern.boottime) are deliberately not denied: seatbelt does not appear to
# intercept them through this filter, and denying kern.hostname breaks uname(2),
# which reads the hostname as part of a single struct. An accepted leak.
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

# /Library/Preferences is deliberately absent: its plists leak host identity
# (hostname, MAC addresses, paired Bluetooth devices, recent users, WiFi
# private-MAC rotation key material).
#
# The /System/Volumes deny matters more than it looks. On Catalina and later the
# data volume mounts at /System/Volumes/Data, with /Library, /Users and
# /private/var firmlinked from there, so the broad /System allow above would
# otherwise expose the entire data volume by its canonical address, bypassing
# every narrower deny on the synthetic paths.
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

# Full read so symlinks into the store (home-manager-managed config files, for
# instance) are followable. Execution stays restricted to the closure.
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
    """Device nodes and terminal I/O.

    /dev/tty, the controlling-terminal alias, is deliberately not allowed: it
    lets a process bypass piped stdin to prompt the human directly, and opens
    the door to escape-sequence and TIOCSTI injection into the parent shell. The
    legacy BSD pty families (/dev/pty*, /dev/ttyp*, /dev/ttyq*, /dev/ttyr*) are
    likewise omitted, since modern macOS allocates via /dev/ptmx and /dev/ttysNNN
    exclusively.

    Access to the pty slave is pinned to the single terminal the wrapper was
    launched on, which stops a sandboxed process opening another Terminal, iTerm
    or tmux pane's pty owned by the same UID: escape-sequence injection, TIOCSTI
    input injection, keystroke eavesdropping.

    When stdin is not a terminal the rule is omitted entirely, so no slave is
    reachable. The Nix version could not omit it, because a param reference has
    to resolve to something, so it pointed at a path that does not exist.
    """
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
    """macOS uses /private/etc as the real location, with /etc as a symlink.

    The session directory files are granted by name, never by subpath. Granting
    the directory would also hand over proxy.pid, and the profile deliberately
    denies kern.proc.* so the sandbox cannot enumerate host processes, while
    (allow signal) is granted and macOS has no PID namespace. A readable pid
    file reconstructs by hand the thing those denies exist to prevent.
    """
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
    # Only in restricted mode: without these the sandbox cannot read the CA it
    # was told to trust, and every TLS handshake through the proxy fails.
    if ca_bundle is not None and ca_cert is not None:
        lines += [
            "(allow file-read*",
            f'  (literal "{ca_bundle}")',
            f'  (literal "{ca_cert}"))',
        ]
    return lines


def temp_dirs(tmpdir: Path) -> list[str]:
    """Temp directories.

    /private/var/folders, the per-user tree confstr(_CS_DARWIN_USER_*) returns,
    is deliberately not allowed: it holds 0400/0600 user secrets reachable via
    the host UID. Tools must respect $TMPDIR.

    The blanket file-write* on /tmp and /private/tmp is wider than it needs to
    be and is a known finding for unit 5. See the note there.
    """
    return [
        "",
        ";; Temp directories",
        "(allow file-read* file-write*",
        '  (subpath "/tmp")',
        '  (subpath "/private/tmp")',
        f'  (subpath "{tmpdir}"))',
    ]


def traversal(
    real_home: Path, sandbox_home: Path, repo_root_parent: Path | None
) -> list[str]:
    """stat() on parent directories, for path resolution.

    "/" needs file-read* because process startup requires readdir on root.
    Everything else gets file-read-metadata only, so stat() works for path
    resolution while readdir() cannot enumerate contents. Without at least
    metadata access, even reaching an allowed subpath fails with EPERM during
    traversal.
    """
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
    """Traversal metadata for each directory between the real home and the repo.

    Appended to the file at runtime in the Nix version, because the list is
    variable-length and a seatbelt param is a single string.
    """
    if not ancestors:
        return []
    return ["", ";; Ancestor directories, for traversal only"] + [
        f'(allow file-read-metadata (literal "{ancestor}"))' for ancestor in ancestors
    ]


def sandbox_home(home: Path) -> list[str]:
    """Read and exec: copilot stores spawn helper binaries in its home."""
    return [
        "",
        ";; Sandbox HOME",
        f'(allow file-read* process-exec (subpath "{home}"))',
    ]


def workspace(cwd: Path, repo_root: Path | None, git_dir: Path | None) -> list[str]:
    """The launch directory, and the repository if there is one.

    The repo rules are omitted rather than pointed at a sentinel when there is
    no repository, or when git was refused for this session because its root
    resolved to the real home.
    """
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
    """Per-declared-path allows, in declaration order.

    roDirs and roFiles get no process-exec: the plan rejects a per-bind exec
    axis, and callers needing to exec from a path should use allowedPackages or
    rwDirs.

    A roDir nested inside an rwDir stays writable, because seatbelt matches per
    operation and the enclosing file-write* allow is the only rule matching a
    write. Fixing that needs explicit denies, not reordering. Unit 5.
    """
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
    """Paths inside the gitdir a sandboxed process must not write.

    These are the paths that would let it run code on the host the next time the
    user runs git in this repo: hooks, core.hooksPath, alias.* = !cmd,
    gpg.program, filter.*.smudge in config or config.worktree, and the commondir
    and .git pointers that redirect git at a gitdir it controls.

    Emitted after the declared-path allows so a declared rwDir containing the
    gitdir cannot re-grant writes. Reads stay allowed, so git still runs the
    hooks and reads the config it already has; commits and fetches still work
    because they write objects/ and refs/, not these.
    """
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
    """Nix daemon socket and full-store exec, only when allowNix is set.

    Emitted after the network rules so the socket allow wins over the blanket
    (deny network-outbound (remote unix-socket)) in unrestricted mode, and
    supplies the missing permission in restricted mode. The process-exec grant
    covers the whole store so the agent can exec results the daemon builds after
    sandbox start, which are not in the allowedPackages closure.

    The socket path must be physical: the kernel resolves symlinks before the
    seatbelt hook, and Determinate Nix on macOS exposes the upstream path as a
    symlink, so an unresolved path-literal matches nothing and the connect is
    denied with EPERM.
    """
    return [
        "",
        ";; Nix daemon support",
        '(allow file-read-metadata (subpath "/nix/var"))',
        '(allow file-read-metadata (subpath "/etc/nix") (subpath "/private/etc/nix"))',
        "(allow network-outbound",
        f'  (remote unix-socket (path-literal "{daemon_socket}")))',
        '(allow process-exec (subpath "/nix/store"))',
    ]


def _local_port_rules(allowed_local_ports: Sequence[int] | None) -> list[str]:
    """allowedLocalPorts is TCP-only; None means every host-local TCP port."""
    if allowed_local_ports is None:
        return ['(allow network-outbound (remote ip "localhost:*"))']
    return [
        f'(allow network-outbound (remote ip "localhost:{port}"))'
        for port in allowed_local_ports
    ]


def network_restricted(
    proxy_port: int, allowed_local_ports: Sequence[int] | None
) -> list[str]:
    """Localhost only, pinned to the proxy's port.

    Pinning to the port stops the sandbox reaching other loopback services
    (local databases, dev servers) directly and bypassing the proxy's domain and
    method filtering.

    UNIX-socket egress is deliberately not allowed: an unrestricted
    (remote unix-socket) allow lets the sandboxed process connect() to any UNIX
    socket the host UID can reach, including terminal-emulator IPC, per-user
    launchd listeners under /private/tmp, and ssh-agent. The proxy speaks TCP,
    so nothing legitimate needs it.

    The Nix version appended this rule to the file at runtime, once the port was
    known. Session state is established before the profile is computed, so the
    port is simply available here.
    """
    return [
        "",
        ";; Network — localhost only, pinned to the proxy port",
        '(allow network-bind (local ip "localhost:*"))',
        "(allow system-socket)",
        f'(allow network-outbound (remote ip "localhost:{proxy_port}"))',
    ] + _local_port_rules(allowed_local_ports)


def network_open(allowed_local_ports: Sequence[int] | None) -> list[str]:
    """Open internet, narrowed by explicit denies for loopback and AF_UNIX.

    (allow network*) is permissive across bind, inbound and outbound, and across
    IP families and protocols including AF_UNIX outbound. Two scoped denies
    narrow it to match the README's "no local services" promise:

    The IP-loopback deny blocks connect() to 127.0.0.0/8 and ::1, one rule
    covering both, so host loopback services (Postgres, dev servers, an SSH
    agent over TCP, local API mocks) are unreachable.

    The unix-socket deny blocks AF_UNIX connect() to host sockets. Nothing the
    sandbox ships needs UNIX-socket egress.

    (allow system-socket) is kept: it gates socket(PF_SYSTEM, ...), meaning
    kernel-control sockets and utun, not AF_UNIX, and matches what the
    restricted branch grants.

    The mDNSResponder re-allow is required: macOS getaddrinfo() resolves names
    over that AF_UNIX socket, so the blanket deny would otherwise kill all
    in-sandbox DNS. The restricted branch needs no such exception, because the
    proxy resolves names and the sandbox only dials TCP to the proxy port.
    """
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
