"""Computes the macOS launch: the argv and the seatbelt profile. Seatbelt is
last-match-wins, so the order the sections are assembled in is what is
enforced."""

from dataclasses import dataclass
from pathlib import Path

from launcher.lib.build_spec import SandboxBuildSpecDarwin
from launcher.lib.constants import CA_BUNDLE, CA_CERT, PASSWD, SEATBELT_PROFILE
from launcher.lib.host_state import DeclaredDir, GitState, HostStateDarwin
from launcher.lib.launch_config.darwin import seatbelt
from launcher.lib.launch_config.shared import (
    SandboxLaunchConfig,
    get_sessions_root_warnings,
    get_usable_git_state,
)
from launcher.lib.session_state import SessionStateDarwin

SANDBOX_EXEC = Path("/usr/bin/sandbox-exec")
SYSTEM_ENV = Path("/usr/bin/env")


@dataclass(frozen=True, kw_only=True)
class SandboxLaunchConfigDarwin(SandboxLaunchConfig):
    seatbelt_profile_lines: tuple[str, ...]
    # (link inside the sandbox home, real path it points at)
    home_symlinks: tuple[tuple[Path, Path], ...]


def _get_ancestors(start: Path, stop: Path) -> list[Path]:
    # Seatbelt needs file-read-metadata on every intermediate directory, or
    # reaching an allowed subpath fails with EPERM during path resolution.
    ancestors: list[Path] = []
    current = start.parent
    while current != stop and current != Path("/"):
        ancestors.append(current)
        current = current.parent
    return ancestors


def _get_traversal_ancestors(
    host: HostStateDarwin, session: SessionStateDarwin, git: GitState | None
) -> list[Path]:
    walk_from = git.repo_root if git is not None else host.cwd
    ancestors = _get_ancestors(walk_from, host.real_home)
    for declared in host.declared:
        ancestors += _get_ancestors(declared.expanded_path, host.real_home)

    # The sandbox HOME and TMPDIR sit inside the session directory, so the
    # walk down to them has to be stat-able the whole way. It runs to "/"
    # rather than stopping at the real home: the sessions root is
    # relocatable, and may not be under the home at all.
    ancestors.append(session.session_dir)
    ancestors += _get_ancestors(session.session_dir, Path("/"))

    seen: set[Path] = set()
    unique: list[Path] = []
    for ancestor in ancestors:
        if ancestor not in seen:
            seen.add(ancestor)
            unique.append(ancestor)
    return unique


def _get_home_symlinks(
    host: HostStateDarwin, sandbox_home: Path
) -> list[tuple[Path, Path]]:
    # Only paths under the real home need a link; anything else is reachable
    # at its own absolute path. Overlapping declarations are refused before
    # this runs.
    planted: list[tuple[Path, Path]] = []
    for declared in host.declared:
        path = declared.expanded_path
        if not path.is_relative_to(host.real_home):
            continue
        planted.append((sandbox_home / path.relative_to(host.real_home), path))
    return planted


@dataclass(frozen=True, kw_only=True)
class _UnixSocketScope:
    # rw files are excluded from writable: bind() refuses an existing path.
    writable: tuple[Path, ...]
    connect_dirs: tuple[Path, ...]
    connect_files: tuple[Path, ...]
    nested_ro_dirs: tuple[Path, ...]
    nested_ro_files: tuple[Path, ...]


def _get_unix_socket_scope(
    host: HostStateDarwin, repo_root: Path | None
) -> _UnixSocketScope:
    # The repository root joins the connect set: build servers keep their
    # rendezvous sockets at the build root (.bsp, .bloop, nailgun), not the
    # module directory the agent was launched in.
    writable = [host.cwd]
    for declared in host.declared:
        if isinstance(declared, DeclaredDir) and declared.mode == "rw":
            writable.append(declared.expanded_path)

    connect_dirs: list[Path] = []
    connect_files: list[Path] = []
    if repo_root is not None:
        connect_dirs.append(repo_root)
    nested_ro_dirs: list[Path] = []
    nested_ro_files: list[Path] = []
    for declared in host.declared:
        if declared.mode != "ro":
            continue
        path = declared.expanded_path
        is_dir = isinstance(declared, DeclaredDir)
        (connect_dirs if is_dir else connect_files).append(path)
        if any(path.is_relative_to(directory) for directory in writable):
            (nested_ro_dirs if is_dir else nested_ro_files).append(path)
    return _UnixSocketScope(
        writable=tuple(writable),
        connect_dirs=tuple(connect_dirs),
        connect_files=tuple(connect_files),
        nested_ro_dirs=tuple(nested_ro_dirs),
        nested_ro_files=tuple(nested_ro_files),
    )


def _get_passwd(host: HostStateDarwin) -> str:
    # A single fabricated user: the host's real /etc/passwd would hand over
    # every account name and home path on the machine.
    return f"user:x:{host.uid}:{host.gid}:sandbox user:{host.real_home}:/bin/sh\n"


def _get_computed_env(
    spec: SandboxBuildSpecDarwin, host: HostStateDarwin, session: SessionStateDarwin
) -> list[str]:
    pairs = [
        f"HOME={session.sandbox_home}",
        f"SHELL={spec.shell}",
        f"PATH={spec.sandbox_path}",
        f"SSL_CERT_DIR={spec.cacert_dir}",
        f"TMPDIR={session.sandbox_tmpdir}",
        "GIT_CONFIG_COUNT=1",
        "GIT_CONFIG_KEY_0=user.useConfigOnly",
        "GIT_CONFIG_VALUE_0=true",
    ]
    if host.term is not None:
        pairs.insert(1, f"TERM={host.term}")

    if session.proxy is None:
        pairs += [
            f"SSL_CERT_FILE={spec.cacert_bundle}",
            f"NIX_SSL_CERT_FILE={spec.cacert_bundle}",
        ]
        return pairs

    bundle = session.session_dir / CA_BUNDLE
    cert = session.session_dir / CA_CERT
    proxy_url = f"http://127.0.0.1:{session.proxy.port}"
    return pairs + [
        f"SSL_CERT_FILE={bundle}",
        f"NIX_SSL_CERT_FILE={bundle}",
        f"NODE_EXTRA_CA_CERTS={cert}",
        f"REQUESTS_CA_BUNDLE={bundle}",
        f"HTTP_PROXY={proxy_url}",
        f"HTTPS_PROXY={proxy_url}",
        f"http_proxy={proxy_url}",
        f"https_proxy={proxy_url}",
    ]


def _get_profile_lines(
    spec: SandboxBuildSpecDarwin,
    host: HostStateDarwin,
    session: SessionStateDarwin,
    git: GitState | None,
) -> list[str]:
    repo_root_parent = git.repo_root.parent if git is not None else None
    git_dir = git.common_dir if git is not None else None
    repo_root = git.repo_root if git is not None else None

    lines: list[str] = []
    lines += seatbelt.HEADER
    lines += seatbelt.PROCESS_CONTROL
    lines += seatbelt.SYSCTLS
    lines += seatbelt.process_exec(host.cwd)
    lines += seatbelt.MACH_IPC

    if session.proxy is None:
        lines += seatbelt.network_open(spec.allowed_local_ports)
    else:
        lines += seatbelt.network_restricted(
            session.proxy.port, spec.allowed_local_ports
        )

    # After the network rules, so the allows outrank open mode's blanket
    # unix-socket deny by last-match. Before nix_support, so the nested-ro
    # denies can never shadow the daemon socket allow.
    if spec.allow_unix_sockets:
        scope = _get_unix_socket_scope(host, repo_root)
        lines += seatbelt.unix_sockets(
            scope.writable,
            scope.connect_dirs,
            scope.connect_files,
            scope.nested_ro_dirs,
            scope.nested_ro_files,
        )

    if host.nix_daemon_socket is not None:
        lines += seatbelt.nix_support(host.nix_daemon_socket)

    lines += seatbelt.device_nodes(host.tty)
    lines += seatbelt.SYSTEM_LIBRARIES
    if session.proxy is None:
        ca_bundle, ca_cert = None, None
    else:
        ca_bundle = session.session_dir / CA_BUNDLE
        ca_cert = session.session_dir / CA_CERT
    lines += seatbelt.dns_tls(session.session_dir / PASSWD, ca_bundle, ca_cert)
    lines += seatbelt.KEYCHAINS
    lines += seatbelt.temp_dirs(session.sandbox_tmpdir)
    lines += seatbelt.NIX_STORE
    lines += seatbelt.traversal(host.real_home, session.sandbox_home, repo_root_parent)
    lines += seatbelt.sandbox_home(session.sandbox_home)
    lines += seatbelt.workspace(host.cwd, repo_root, git_dir)
    lines += seatbelt.TIMEZONE
    lines += seatbelt.declared_paths(host.declared)
    lines += seatbelt.closure(host.closure_paths)
    lines += seatbelt.ancestor_metadata(_get_traversal_ancestors(host, session, git))

    # Last, so they outrank every allow above, including a declared rwDir
    # that happens to contain the gitdir.
    if git is not None:
        lines += seatbelt.git_protection(
            git.protected_dirs, tuple(git.protected_files.keys())
        )
    return lines


def compute_launch_config(
    spec: SandboxBuildSpecDarwin,
    host: HostStateDarwin,
    session: SessionStateDarwin,
) -> SandboxLaunchConfigDarwin:
    git, warnings = get_usable_git_state(host)
    warnings += get_sessions_root_warnings(host, session.session_dir)

    argv_before_env = [str(SYSTEM_ENV), "-i"] + _get_computed_env(spec, host, session)
    argv_after_env = [
        str(SANDBOX_EXEC),
        "-f",
        str(session.session_dir / SEATBELT_PROFILE),
        str(spec.pre_entry_script),
        str(spec.sandboxed_binary),
    ]

    ca_bundle = (
        ()
        if session.proxy is None
        else (spec.cacert_bundle, session.session_dir / CA_CERT)
    )

    return SandboxLaunchConfigDarwin(
        argv_before_env=tuple(argv_before_env),
        argv_after_env=tuple(argv_after_env),
        passwd=_get_passwd(host),
        ca_bundle=ca_bundle,
        cleanup=(session.sandbox_home, session.sandbox_tmpdir),
        cleanup_if_empty=(),
        warnings=tuple(warnings),
        seatbelt_profile_lines=tuple(_get_profile_lines(spec, host, session, git)),
        home_symlinks=tuple(_get_home_symlinks(host, session.sandbox_home)),
    )
