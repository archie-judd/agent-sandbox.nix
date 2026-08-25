"""What to launch on macOS, and the seatbelt profile that constrains it.

Pure. Reads no files, runs no subprocesses, prints nothing. Ordering decisions
live here: seatbelt is last-match-wins, so the order these sections are
assembled in is what is enforced, not merely how it reads.
"""

from dataclasses import dataclass
from pathlib import Path

from launcher.lib.build_spec import SandboxBuildSpecDarwin
from launcher.lib.constants import CA_BUNDLE, CA_CERT, PASSWD, SEATBELT_PROFILE
from launcher.lib.host_state import GitState, HostStateDarwin
from launcher.lib.launch_config.darwin import seatbelt
from launcher.lib.launch_config.shared import SandboxLaunchConfig, get_usable_git_state
from launcher.lib.session_state import SessionStateDarwin

SANDBOX_EXEC = Path("/usr/bin/sandbox-exec")
SYSTEM_ENV = Path("/usr/bin/env")
# TMPDIR inside the sandbox. See the /tmp note in seatbelt.temp_dirs.
SANDBOX_TMPDIR = Path("/tmp")


@dataclass(frozen=True, kw_only=True)
class SandboxLaunchConfigDarwin(SandboxLaunchConfig):
    seatbelt_profile_lines: tuple[str, ...]
    # Link path inside the sandbox home, and the real path it points at. Planted
    # so that $HOME-relative lookups inside the sandbox reach the real paths
    # through the seatbelt-allowed targets.
    home_symlinks: tuple[tuple[Path, Path], ...]


def _get_ancestors(start: Path, stop: Path) -> list[Path]:
    """Directories between start and stop, exclusive of both.

    Seatbelt needs file-read-metadata on each, or reaching an allowed subpath
    fails with EPERM partway through path resolution.
    """
    ancestors: list[Path] = []
    current = start.parent
    while current != stop and current != Path("/"):
        ancestors.append(current)
        current = current.parent
    return ancestors


def _get_traversal_ancestors(host: HostStateDarwin, git: GitState | None) -> list[Path]:
    """Every directory needing traversal metadata, in order, without repeats.

    From the repository root, or the launch directory when there is no usable
    repository, up to the real home; then from each declared path up to the real
    home, so symlink targets planted in the sandbox home are reachable.

    The bash emitted one rule per visit and so repeated itself; the rule set is
    the same either way.
    """
    walk_from = git.repo_root if git is not None else host.cwd
    ancestors = _get_ancestors(walk_from, host.real_home)
    for declared in host.declared:
        ancestors += _get_ancestors(declared.expanded_path, host.real_home)

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
    """Where each declared path under the real home appears in the sandbox home.

    Only paths under the real home get one: anything else is reachable at its
    own absolute path already. Overlapping declarations are refused before this
    runs, by get_launch_refusals, so nothing here can plant through an earlier
    link and out into the real home.
    """
    planted: list[tuple[Path, Path]] = []
    for declared in host.declared:
        path = declared.expanded_path
        if not path.is_relative_to(host.real_home):
            continue
        planted.append((sandbox_home / path.relative_to(host.real_home), path))
    return planted


def _get_passwd(host: HostStateDarwin) -> str:
    """A single fabricated user.

    Binding the host's real /etc/passwd would hand over every account name and
    home path on the machine. The x means the hash lives in the shadow file, so
    no credential is here. The uid and gid are real because the process really
    does run as them.
    """
    return f"user:x:{host.uid}:{host.gid}:sandbox user:{host.real_home}:/bin/sh\n"


def _get_computed_env(
    spec: SandboxBuildSpecDarwin, host: HostStateDarwin, session: SessionStateDarwin
) -> list[str]:
    """The environment the launcher decides, as K=V arguments to env -i.

    The declared environment follows these, inserted by the stub, so a declared
    HOME or PATH still overrides the computed one. That is what both backends do
    today, and reversing it would be a behaviour change this port does not make.
    """
    pairs = [
        f"HOME={session.sandbox_home}",
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
    """Assemble the profile. The order is the enforcement."""
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

    # After the network rules, so the socket allow outranks the blanket
    # unix-socket deny in open mode.
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
    lines += seatbelt.temp_dirs(SANDBOX_TMPDIR)
    lines += seatbelt.NIX_STORE
    lines += seatbelt.traversal(host.real_home, session.sandbox_home, repo_root_parent)
    lines += seatbelt.sandbox_home(session.sandbox_home)
    lines += seatbelt.workspace(host.cwd, repo_root, git_dir)
    lines += seatbelt.TIMEZONE
    lines += seatbelt.declared_paths(host.declared)
    lines += seatbelt.closure(host.closure_paths)
    lines += seatbelt.ancestor_metadata(_get_traversal_ancestors(host, git))

    # Last, so they outrank every allow above, including a declared rwDir that
    # happens to contain the gitdir.
    if git is not None:
        # Existence is irrelevant here: a deny on a path that does not exist
        # yet is harmless, and becomes effective the moment it appears.
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
        # The session directory survives for debugging, and everything at a
        # fixed name inside it survives with it. Only the sandbox home goes.
        cleanup=(session.sandbox_home,),
        # macOS binds nothing, so nothing is materialised to clean up.
        cleanup_if_empty=(),
        warnings=tuple(warnings),
        seatbelt_profile_lines=tuple(_get_profile_lines(spec, host, session, git)),
        home_symlinks=tuple(_get_home_symlinks(host, session.sandbox_home)),
    )
