"""Reads the host and decides nothing. Every path returned is physical
(parents fully followed, final component left alone), because these paths
become bubblewrap and seatbelt rules and the kernel resolves symlinks before
either is matched, so an unresolved name would match nothing."""

import os
import re
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Literal, Sequence, TypedDict, assert_never

from launcher.lib.build_spec import (
    SandboxBuildSpecDarwin,
    SandboxBuildSpecLinux,
)
from launcher.lib.constants import ERROR_PREFIX, WARN_PREFIX
from launcher.lib.git_state import GitState, read_git_state
from launcher.lib.symlinks import ResolvedPath, Symlink, resolve_path

SYSTEMD_RESOLV_CONF = Path("/run/systemd/resolve/resolv.conf")
RESOLV_CONF = Path("/etc/resolv.conf")
DEFAULT_NIX_DAEMON_SOCKET = Path("/nix/var/nix/daemon-socket/socket")


@dataclass(frozen=True, kw_only=True)
class DeclaredPath:
    unexpanded_path: str
    # A relative path is left exactly as expanded: resolving it would pick a
    # base directory, which is the very choice get_launch_refusals refuses
    # it for.
    expanded_path: Path
    mode: Literal["rw", "ro"]
    exists: bool
    parent_symlinks: tuple[Symlink, ...]
    hops: tuple[Path, ...]


@dataclass(frozen=True, kw_only=True)
class DeclaredFile(DeclaredPath):
    pass


@dataclass(frozen=True, kw_only=True)
class DeclaredDir(DeclaredPath):
    inner_symlinks: tuple[ResolvedPath, ...]


@dataclass(frozen=True, kw_only=True)
class HostState:
    cwd: Path
    real_home: Path
    uid: int
    gid: int
    term: str | None
    has_controlling_terminal: bool
    declared: tuple[DeclaredPath, ...]
    git: GitState | None
    closure_paths: tuple[Path, ...]
    nix_daemon_socket: Path | None


@dataclass(frozen=True, kw_only=True)
class HostStateLinux(HostState):
    resolv_conf_names_loopback: bool
    systemd_resolv_conf: Path | None
    machine: str


@dataclass(frozen=True, kw_only=True)
class HostStateDarwin(HostState):
    tty: Path | None


def _path_exists(path: Path) -> bool:
    try:
        return path.exists()
    except OSError:
        return False


def _path_is_file(path: Path) -> bool:
    try:
        return path.is_file()
    except OSError:
        return False


def _expand_env_var(reference: str, environ: dict[str, str]) -> str:
    _IDENTIFIER = re.compile(r"[A-Za-z_][A-Za-z0-9_]*\Z")
    if reference.startswith("{"):
        name = reference[1:-1]
    else:
        name = reference
    if not _IDENTIFIER.match(name):
        raise ValueError(f"unsupported expansion '${{{name}}}'")
    value = environ.get(name)
    if value is None:
        raise ValueError(f"${name} is not set in the environment")
    return value


def _expand_path(unexpanded: str, environ: dict[str, str]) -> Path:
    """Expand `$VAR`, `${VAR}` and a leading `~`, and nothing else. There is
    no command substitution, and an undefined variable is fatal rather than
    empty."""
    # The braced alternative is permissive on purpose, so unsupported forms
    # like ${VAR:-default} are refused by name rather than passed through.
    _BASH_VAR_EXPANSION = re.compile(r"\$(\{[^}]*\}|[A-Za-z_][A-Za-z0-9_]*)")

    if unexpanded == "~" or unexpanded.startswith("~/"):
        home = environ.get("HOME")
        if not home:
            raise SystemExit(f"{ERROR_PREFIX} {unexpanded}: HOME is not set")
        unexpanded = home + unexpanded[1:]
    elif unexpanded.startswith("~"):
        raise SystemExit(
            f"{ERROR_PREFIX} {unexpanded}: ~user expansion is not supported; "
            f"write the path out or use $HOME"
        )

    parts: list[str] = []
    position = 0
    matches = _BASH_VAR_EXPANSION.finditer(unexpanded)
    try:
        for match in matches:
            literal = unexpanded[position : match.start()]
            reference = match.group(1)
            value = _expand_env_var(reference, environ)
            parts.append(literal)
            parts.append(value)
            position = match.end()
    except ValueError as error:
        raise SystemExit(f"{ERROR_PREFIX} {unexpanded}: {error}") from error
    parts.append(unexpanded[position:])

    expanded = "".join(parts)
    return Path(expanded)


def _get_inner_symlinks(directory: Path) -> tuple[ResolvedPath, ...]:
    try:
        entries = list(directory.iterdir())
    except OSError:
        # An unreadable or missing declared directory is reported by
        # get_launch_refusals.
        return ()

    entries.sort()
    inner_symlinks: list[ResolvedPath] = []

    for entry in entries:
        if entry.is_symlink():
            inner_symlinks.append(resolve_path(entry))

    return tuple(inner_symlinks)


def _get_declared_paths(
    declared: Sequence[str], mode: Literal["rw", "ro"], kind: Literal["dir", "file"]
) -> list[DeclaredPath]:
    environ = dict(os.environ)
    paths: list[DeclaredPath] = []
    for unexpanded in declared:
        expanded = _expand_path(unexpanded, environ)
        parent_symlinks: tuple[Symlink, ...] = ()
        hops: tuple[Path, ...] = ()
        if expanded.is_absolute():
            resolved = resolve_path(expanded)
            expanded = resolved.physical_path
            parent_symlinks = resolved.parent_symlinks
            hops = resolved.hops
        exists = _path_exists(expanded)
        path: DeclaredPath
        match kind:
            case "dir":
                if expanded.is_absolute():
                    inner_symlinks = _get_inner_symlinks(expanded)
                else:
                    inner_symlinks = ()
                path = DeclaredDir(
                    unexpanded_path=unexpanded,
                    expanded_path=expanded,
                    mode=mode,
                    exists=exists,
                    parent_symlinks=parent_symlinks,
                    hops=hops,
                    inner_symlinks=inner_symlinks,
                )
            case "file":
                path = DeclaredFile(
                    unexpanded_path=unexpanded,
                    expanded_path=expanded,
                    mode=mode,
                    exists=exists,
                    parent_symlinks=parent_symlinks,
                    hops=hops,
                )
            case _:
                assert_never(kind)
        paths.append(path)
    return paths


def _has_controlling_terminal() -> bool:
    # /dev/tty rather than stdin, so a piped stdin does not look like an
    # absent terminal.
    try:
        handle = os.open("/dev/tty", os.O_RDONLY)
    except OSError:
        return False
    os.close(handle)
    return True


def _get_stdin_tty() -> Path | None:
    try:
        return Path(os.ttyname(sys.stdin.fileno()))
    except (OSError, ValueError):
        return None


def _read_closure_paths(closure_paths_file: Path) -> tuple[Path, ...]:
    text = closure_paths_file.read_text(encoding="utf-8")
    lines = text.splitlines()
    paths = [Path(line) for line in lines if line]
    return tuple(paths)


def _get_nix_daemon_socket() -> Path:
    # Resolved because Determinate Nix on macOS exposes the upstream path as
    # a symlink, which a seatbelt path-literal would not match.
    override = os.environ.get("NIX_DAEMON_SOCKET_PATH")
    if override:
        socket = Path(override)
    else:
        socket = DEFAULT_NIX_DAEMON_SOCKET
    resolved = os.path.realpath(socket)
    return Path(resolved)


def _resolv_conf_names_loopback() -> bool:
    # systemd-resolved points /etc/resolv.conf at a stub listener on the
    # host's own loopback, which inside pasta's namespace is a different
    # loopback with nothing on it.
    _LOOPBACK_NAMESERVER = re.compile(r"^nameserver[ \t]+(?:127\.|::1)", re.MULTILINE)
    try:
        text = RESOLV_CONF.read_text(encoding="utf-8")
    except OSError:
        return False
    return _LOOPBACK_NAMESERVER.search(text) is not None


class _CommonHostState(TypedDict):
    """The fields both platforms share, typed so `**` is checked by mypy."""

    cwd: Path
    real_home: Path
    uid: int
    gid: int
    term: str | None
    has_controlling_terminal: bool
    declared: tuple[DeclaredPath, ...]
    git: GitState | None
    closure_paths: tuple[Path, ...]
    nix_daemon_socket: Path | None


def _common_host_state(
    spec: SandboxBuildSpecLinux | SandboxBuildSpecDarwin,
) -> _CommonHostState:
    cwd = Path.cwd()
    home = os.environ.get("HOME")
    if not home:
        raise SystemExit(f"{ERROR_PREFIX} HOME is not set")

    declared_paths: list[DeclaredPath] = []
    declared_paths += _get_declared_paths(spec.rw_dirs, "rw", "dir")
    declared_paths += _get_declared_paths(spec.rw_files, "rw", "file")
    declared_paths += _get_declared_paths(spec.ro_dirs, "ro", "dir")
    declared_paths += _get_declared_paths(spec.ro_files, "ro", "file")

    if spec.allow_nix:
        nix_daemon_socket = _get_nix_daemon_socket()
    else:
        nix_daemon_socket = None

    return _CommonHostState(
        cwd=cwd,
        # Resolved in full, unlike declared paths: the home is only compared,
        # never bound, and it has to match what os.getcwd() reports even
        # when $HOME is itself a symlink.
        real_home=Path(os.path.realpath(home)),
        uid=os.getuid(),
        gid=os.getgid(),
        term=os.environ.get("TERM"),
        has_controlling_terminal=_has_controlling_terminal(),
        declared=tuple(declared_paths),
        git=read_git_state(spec.dependencies.git, cwd),
        closure_paths=_read_closure_paths(spec.closure_paths_file),
        nix_daemon_socket=nix_daemon_socket,
    )


def _is_git_root_the_home(host: HostState, git: GitState) -> bool:
    # A home-rooted repo's object store holds the history of tracked
    # dotfiles. Launching from the home directory itself is the exception:
    # the user has already confirmed that the whole home is exposed.
    if host.real_home == git.repo_root:
        return host.cwd != host.real_home
    return git.repo_root in host.real_home.parents


def get_usable_git_state(host: HostState) -> tuple[GitState | None, list[str]]:
    if host.git is None:
        return None, []
    if _is_git_root_the_home(host, host.git):
        return None, [
            f"{WARN_PREFIX} git root resolves to your home directory "
            f"({host.real_home}), which the sandbox will not expose. "
            f"git is disabled for this session."
        ]
    return host.git, []


def get_grantable_repo_root(host: HostState, git: GitState | None) -> Path | None:
    # The work tree root, when granting it adds access the launch directory
    # does not already have. Below a work tree root it is what lets git report
    # on files above the launch directory, so withholding it would make git
    # status and git diff call them deleted rather than fail.
    #
    # `git` is what get_usable_git_state returned, not host.git: a home-rooted
    # repo has git disabled, and nothing should be granted on its behalf.
    if git is None:
        return None
    if git.work_tree_root == host.cwd:
        return None
    return git.work_tree_root


def read_host_state_linux(spec: SandboxBuildSpecLinux) -> HostStateLinux:
    if _path_is_file(SYSTEMD_RESOLV_CONF):
        systemd_resolv_conf = SYSTEMD_RESOLV_CONF
    else:
        systemd_resolv_conf = None
    return HostStateLinux(
        **_common_host_state(spec),
        resolv_conf_names_loopback=_resolv_conf_names_loopback(),
        systemd_resolv_conf=systemd_resolv_conf,
        machine=os.uname().machine,
    )


def read_host_state_darwin(spec: SandboxBuildSpecDarwin) -> HostStateDarwin:
    return HostStateDarwin(**_common_host_state(spec), tty=_get_stdin_tty())
