"""What reading the host returns.

Every path in HostState is physical: parent directories resolved to their
fully-followed form, final component left alone. Two names for one directory
never compare equal as strings, and everything downstream compares these paths
against each other and turns them into bubblewrap and seatbelt rules, where the
kernel resolves before the rule is matched so a shortcut name matches nothing.
The final component keeps its own name because whether it is a symlink is a
distinction the bind decisions depend on.

This module observes and decides nothing. It may read files, resolve symlinks
and run git; it may not create, delete, prompt, or work out what to bind. The
rule that keeps the boundary checkable: a fact belongs here if it can be stated
without naming bubblewrap, seatbelt, binds or rules. So "/etc/resolv.conf names
a loopback nameserver" is observed here, while "use the systemd file instead" is
decided in launch_config.

One consequence is deliberate. The git protected-path enumeration always runs,
even when the launch is about to be refused because the repo root is the real
home, because that refusal is policy and policy lives in launch_checks. It costs
one directory walk and two git calls in a rare case, and it is the price of the
boundary being verifiable by reading signatures.
"""

import os
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Literal, Mapping, Sequence, TypedDict, assert_never

from launcher.lib.build_spec import (
    SandboxBuildSpecDarwin,
    SandboxBuildSpecLinux,
)
from launcher.lib.constants import ERROR_PREFIX

# Matches the bash walk it replaces. Long enough that no legitimate chain hits
# it, short enough that a cycle terminates.
MAX_SYMLINK_HOPS = 40


SYSTEMD_RESOLV_CONF = Path("/run/systemd/resolve/resolv.conf")
RESOLV_CONF = Path("/etc/resolv.conf")
DEFAULT_NIX_DAEMON_SOCKET = Path("/nix/var/nix/daemon-socket/socket")


@dataclass(frozen=True, kw_only=True)
class Symlink:
    """A symlink on the host: where it lives, and where it points.

    points_to is absolute with . and .. removed, but keeps any symlink its own
    text runs through. It is what the link says, not where it ends up.
    """

    path: Path
    points_to: Path


@dataclass(frozen=True, kw_only=True)
class SymlinkHop:
    """One step of a symlink chain: one link, followed once.

    points_to is where this link lands, with every symlink flattened away.

    parent_symlinks are the symlinked directories walked on the way there, and
    the sandbox needs each of them recreated. Bubblewrap builds its filesystem
    from nothing, so a name exists inside only if something put it there; when a
    program opens the original link the kernel walks the name the link literally
    holds, and a missing directory along that name fails the open even though
    the file at the end was bound. After the first, each is a parent of the path
    as flattened so far rather than of the original text.

    For ~/.claude/settings.json under home-manager:

        points_to        /nix/store/xxx-hm-files/home-files/.claude/settings.json
        parent_symlinks  [ ~/.local/state/.../gcroots/current-home
                             -> /nix/store/xxx-hm-files ]
    """

    points_to: Path
    parent_symlinks: tuple[Symlink, ...]


@dataclass(frozen=True, kw_only=True)
class SymlinkChain:
    """Every link followed from a path to the file it finally names.

    hops is empty exactly when the path is not a symlink, so there is no
    is_symlink field beside it: two ways to state one fact is two ways for it to
    disagree with itself.
    """

    hops: tuple[SymlinkHop, ...]


@dataclass(frozen=True, kw_only=True)
class DeclaredPath:
    unexpanded_path: str
    # Expanded, with parent directories resolved to their fully-followed form.
    # The final component is not resolved, so a declared path that is itself a
    # symlink stays one.
    expanded_path: Path
    mode: Literal["rw", "ro"]
    exists: bool
    symlink_chain: SymlinkChain
    # The symlinked directories resolved out of expanded_path above. The
    # sandbox needs them for the same reason a hop's do: expanded_path is the
    # flattened form, and a program still opens the name that was declared.
    parent_symlinks: tuple[Symlink, ...]


@dataclass(frozen=True, kw_only=True)
class DeclaredFile(DeclaredPath):
    pass


@dataclass(frozen=True, kw_only=True)
class DeclaredDir(DeclaredPath):
    # Chains for the symlinks directly inside the directory. A declared file
    # cannot have these, which is why the split is by kind rather than by
    # whether the path is itself a symlink.
    inner_symlinks: tuple[SymlinkChain, ...]


@dataclass(frozen=True, kw_only=True)
class GitState:
    common_dir: Path
    repo_root: Path
    # Paths inside the repo that name commands git will run on the host: hooks
    # directories, config files, and the pointers that redirect git at another
    # gitdir entirely.
    protected_dirs: tuple[Path, ...]
    # Each protected file, mapped to whether it exists on the host. A path that
    # does not exist yet still has to be made read-only rather than merely
    # creatable, so the backends bind an empty file over it. Paired structurally
    # rather than positionally, so the two can never drift apart.
    protected_files: Mapping[Path, bool]


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
    """Resolve one reference, given the text after the `$`: `VAR` or `{VAR}`.

    Raises the bare reason. The caller knows which declared path it came from
    and adds that context, which keeps this directly testable.
    """
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
    """Expand `$VAR`, `${VAR}` and a leading `~`, and nothing else.

    Declared paths used to be interpolated into bash, so the shell expanded
    them, which meant `rwDirs = [ "$(...)" ]` executed. There is no command
    substitution here. A `$` that is not followed by an identifier or a brace
    stays literal, so `$(cat /etc/passwd)` survives as itself and then fails the
    existence check, naming both forms.

    An undefined variable is fatal rather than empty. The shell turned
    `$TYPO/.claude` into `/.claude` and the error named a path the user never
    wrote.
    """
    # Matches $VAR or ${VAR}. The braced alternative is permissive on purpose,
    # so unsupported forms like ${VAR:-default} still match and get refused by
    # name rather than passing through as literal text.
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


def _get_parent_symlinks(path: Path) -> tuple[Symlink, ...]:
    """The symlinked directories above `path`, in the order they are walked.

    The sandbox needs every one of them reproduced. Bubblewrap builds its
    filesystem from nothing, so a name exists inside only if something put it
    there; when a program opens a path the kernel walks the names as written,
    and a missing directory partway along fails the open even though the file at
    the end was bound.

    realpath says where a path ends up but not what it went through, which is
    the only reason this walk exists. It computes no path of its own: callers
    resolve with realpath, and this answers the other half of the question.

    The walk goes component by component from the root. On reaching a symlink it
    records it and restarts from the target, because the target's own components
    may be symlinks too and each of those needs reproducing as well. It follows
    the path as written, so a `..` sitting after a symlink is walked textually
    rather than the way the kernel would; callers normalise before asking.
    """
    parent_symlinks: list[Symlink] = []
    # Absolute so the component walk starts from the root. Declared paths are
    # not checked for being absolute anywhere yet, and a relative one would
    # otherwise silently lose its first component here.
    path = Path(os.path.abspath(path))
    resolved = Path(path.anchor)
    remaining = list(path.parent.parts[1:])
    follows = 0

    while remaining:
        current = resolved / remaining.pop(0)
        if not current.is_symlink():
            resolved = current
            continue
        if follows >= MAX_SYMLINK_HOPS:
            # A loop among the parent directories. Stop collecting; the path
            # itself is the caller's realpath, which leaves a looping link
            # unresolved and so still names what the user wrote.
            break
        follows += 1
        link = Path(os.readlink(current))
        if not link.is_absolute():
            link = current.parent / link
        target = Path(os.path.normpath(link))
        parent_symlinks.append(Symlink(path=current, points_to=target))
        remaining = list(target.parts[1:]) + remaining
        resolved = Path(target.anchor)

    return tuple(parent_symlinks)


def _get_symlink_chain_for_file(path: Path) -> SymlinkChain:
    """Every link followed from `path` to the file it finally names.

    One hop per link, in order, rather than only the final target. Opening the
    path makes the kernel follow every link in the chain, so a sandbox that
    knows only where the chain ends cannot open it: the intermediate names have
    to be reachable too.

    Each hop's target is physical, parents resolved and final component left as
    the link wrote it, and the symlinked directories resolved out of it are
    recorded on the hop. See SymlinkHop.
    """
    hops: list[SymlinkHop] = []
    current = Path(os.path.abspath(path))

    for _ in range(MAX_SYMLINK_HOPS):
        if not current.is_symlink():
            break
        link = Path(os.readlink(current))
        # A relative link is relative to the directory the link itself sits in.
        if not link.is_absolute():
            link = current.parent / link
        # Clean up `.` and `..`, so /tmp/../tmp/foo compares equal to /tmp/foo.
        normalised = Path(os.path.normpath(link))
        points_to = Path(os.path.realpath(normalised.parent)) / normalised.name
        if str(points_to) == "/":
            break
        hops.append(
            SymlinkHop(
                points_to=points_to,
                parent_symlinks=_get_parent_symlinks(normalised),
            )
        )
        current = points_to

    return SymlinkChain(hops=tuple(hops))


def _get_all_symlink_chains_in_dir(directory: Path) -> tuple[SymlinkChain, ...]:
    try:
        entries = list(directory.iterdir())
    except OSError:
        # An unreadable or missing declared directory is not this step's
        # problem; get_launch_refusals reports it.
        return ()

    entries.sort()
    inner_symlinks: list[SymlinkChain] = []

    for entry in entries:
        if entry.is_symlink():
            chain = _get_symlink_chain_for_file(entry)
            inner_symlinks.append(chain)

    return tuple(inner_symlinks)


def _get_declared_paths(
    declared: Sequence[str], mode: Literal["rw", "ro"], kind: Literal["dir", "file"]
) -> list[DeclaredPath]:
    environ = dict(os.environ)
    paths: list[DeclaredPath] = []
    for unexpanded in declared:
        expanded = _expand_path(unexpanded, environ)
        # Follow any symlinks in the directories ABOVE this path, then put the
        # final name back on unchanged. realpath does the whole ancestor chain
        # at any depth in one call, and is a no-op when there are none.
        #
        # Only the ancestors, because two names for one directory never compare
        # equal as strings and everything downstream compares these paths.
        # Whether this path is ITSELF a symlink is a different question, asked
        # two lines below by _get_symlink_chain_for_file, and realpath on the
        # whole path would answer it destructively: a declared ~/.claude
        # pointing into the store would become the store path, losing the name
        # the sandboxed process is going to look for.
        #
        # Asked before the flattening, since that is the form whose symlinks
        # are the ones the sandbox has to reproduce.
        parent_symlinks = _get_parent_symlinks(expanded)
        # Only an absolute path is flattened. realpath would resolve a relative
        # one against the launch directory, which is the very thing
        # get_launch_refusals refuses it for, and doing that here would leave
        # the refusal nothing to see.
        if expanded.is_absolute():
            resolved_parent = Path(os.path.realpath(expanded.parent))
            expanded = resolved_parent / expanded.name
        exists = _path_exists(expanded)
        symlink_chain = _get_symlink_chain_for_file(expanded)
        path: DeclaredPath
        match kind:
            case "dir":
                inner_symlinks = _get_all_symlink_chains_in_dir(expanded)
                path = DeclaredDir(
                    unexpanded_path=unexpanded,
                    expanded_path=expanded,
                    mode=mode,
                    exists=exists,
                    symlink_chain=symlink_chain,
                    parent_symlinks=parent_symlinks,
                    inner_symlinks=inner_symlinks,
                )
            case "file":
                path = DeclaredFile(
                    unexpanded_path=unexpanded,
                    expanded_path=expanded,
                    mode=mode,
                    exists=exists,
                    symlink_chain=symlink_chain,
                    parent_symlinks=parent_symlinks,
                )
            case _:
                assert_never(kind)
        paths.append(path)
    return paths


def _run_git_command(git: Path, *args: str, cwd: Path | None = None) -> str | None:
    try:
        result = subprocess.run(
            [str(git), *args],
            cwd=cwd,
            capture_output=True,
            text=True,
            check=False,
        )
    except OSError:
        return None
    if result.returncode != 0:
        return None
    return result.stdout.strip()


def _get_all_gitdirs(common_dir: Path) -> list[Path]:
    owned = [common_dir]
    modules = common_dir / "modules"
    if not modules.is_dir():
        return owned
    walker = os.walk(modules)
    for parent, directories, _ in walker:
        directories.sort()
        for name in directories:
            candidate = Path(parent) / name
            if (candidate / "HEAD").is_file() and (candidate / "config").is_file():
                owned.append(candidate)
    return owned


def _is_worktree_config_enabled(git: Path, config: Path) -> bool:
    """Whether the repo opts in to per-worktree config.

    git honours extensions.worktreeConfig from the repo config alone, never from
    global config, so a config.worktree written while the extension is off is
    inert. Read per gitdir, because submodules carry their own setting.
    """
    value = _run_git_command(
        git, "config", "--file", str(config), "--get", "extensions.worktreeConfig"
    )
    return value == "true"


def _get_worktree_pointer_files(
    gitdir: Path, worktree_config_enabled: bool
) -> list[Path]:
    """Per-worktree files inside this gitdir that redirect git elsewhere.

    commondir sends the host's git at a different gitdir entirely, so protecting
    the config without the pointers to it closes nothing.
    """
    worktrees = gitdir / "worktrees"
    if not worktrees.is_dir():
        return []

    pointers: list[Path] = []
    for worktree in sorted(worktrees.iterdir()):
        if not worktree.is_dir():
            continue
        pointers.append(worktree / "commondir")
        if worktree_config_enabled:
            pointers.append(worktree / "config.worktree")
    return pointers


def _get_submodule_dot_git(git: Path, gitdir: Path) -> Path | None:
    """The .git file of the submodule this gitdir belongs to, if it is one.

    core.worktree is set only for submodules and is relative to the gitdir. Left
    writable, the .git file it points at would redirect the host's git past the
    hooks and config protected alongside it.
    """
    submodule_worktree = _run_git_command(
        git, "config", "--file", str(gitdir / "config"), "--get", "core.worktree"
    )
    if not submodule_worktree:
        return None

    dot_git = gitdir / submodule_worktree / ".git"
    if not dot_git.is_file():
        return None
    return Path(os.path.realpath(dot_git))


def _get_protected_files_in_gitdir(git: Path, gitdir: Path) -> list[Path]:
    """Files inside one gitdir that must not be writable from the sandbox."""
    config = gitdir / "config"
    protected: list[Path] = []
    if config.is_file():
        protected.append(config)

    worktree_config_enabled = _is_worktree_config_enabled(git, config)
    if worktree_config_enabled:
        protected.append(gitdir / "config.worktree")

    protected += _get_worktree_pointer_files(gitdir, worktree_config_enabled)

    submodule_dot_git = _get_submodule_dot_git(git, gitdir)
    if submodule_dot_git is not None:
        protected.append(submodule_dot_git)

    return protected


def _get_worktree_dot_git_files(git: Path, cwd: Path) -> list[Path]:
    """Worktree .git files, the same pointer vector as commondir.

    Only worktrees at or under cwd are ever reachable from inside the sandbox;
    the rest are never bound, so they are out of scope.
    """
    listing = _run_git_command(git, "worktree", "list", "--porcelain", cwd=cwd)
    if listing is None:
        return []

    dot_git_files: list[Path] = []
    for line in listing.splitlines():
        if not line.startswith("worktree "):
            continue
        worktree_path = Path(line[len("worktree ") :])
        under_cwd = worktree_path == cwd or cwd in worktree_path.parents
        if under_cwd and (worktree_path / ".git").is_file():
            dot_git_files.append(worktree_path / ".git")
    return dot_git_files


def _read_git_state(git: Path, cwd: Path) -> GitState | None:
    common = _run_git_command(
        git, "rev-parse", "--path-format=absolute", "--git-common-dir", cwd=cwd
    )
    if not common:
        return None
    common_dir = Path(common)

    protected_dirs: list[Path] = []
    protected_files: dict[Path, bool] = {}

    for gitdir in _get_all_gitdirs(common_dir):
        hooks = gitdir / "hooks"
        if hooks.is_dir():
            protected_dirs.append(hooks)
        for path in _get_protected_files_in_gitdir(git, gitdir):
            protected_files[path] = _path_exists(path)

    for path in _get_worktree_dot_git_files(git, cwd):
        protected_files[path] = _path_exists(path)

    return GitState(
        common_dir=common_dir,
        repo_root=common_dir.parent,
        protected_dirs=tuple(protected_dirs),
        protected_files=protected_files,
    )


def _has_controlling_terminal() -> bool:
    # Reads /dev/tty rather than stdin so a piped stdin does not look like an
    # absent terminal, which is the distinction the home-directory prompt needs.
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
    # The kernel resolves symlinks before the seatbelt hook, so a rule holding
    # the unresolved path never matches. Determinate Nix on macOS exposes the
    # upstream path as a symlink.
    override = os.environ.get("NIX_DAEMON_SOCKET_PATH")
    if override:
        socket = Path(override)
    else:
        socket = DEFAULT_NIX_DAEMON_SOCKET
    resolved = os.path.realpath(socket)
    return Path(resolved)


def _resolv_conf_names_loopback() -> bool:
    # systemd-resolved points /etc/resolv.conf at a stub listener on the host's
    # own loopback, which inside pasta's namespace is a different loopback with
    # nothing on it.
    _LOOPBACK_NAMESERVER = re.compile(r"^nameserver[ \t]+(?:127\.|::1)", re.MULTILINE)
    try:
        text = RESOLV_CONF.read_text(encoding="utf-8")
    except OSError:
        return False
    return _LOOPBACK_NAMESERVER.search(text) is not None


class _CommonHostState(TypedDict):
    """The fields both platforms share, typed so `**` is checked.

    Duplicates the field list on HostState, which is the cost of this shape.
    mypy validates the unpacked keys against the constructor it is splatted
    into, which it cannot do for a plain dict.
    """

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
        # Resolved in full, unlike declared paths: the home directory is only
        # compared, never bound, and it has to match what os.getcwd() reports
        # even when $HOME is itself a symlink.
        real_home=Path(os.path.realpath(home)),
        uid=os.getuid(),
        gid=os.getgid(),
        term=os.environ.get("TERM"),
        has_controlling_terminal=_has_controlling_terminal(),
        declared=tuple(declared_paths),
        git=_read_git_state(spec.dependencies.git, cwd),
        closure_paths=_read_closure_paths(spec.closure_paths_file),
        nix_daemon_socket=nix_daemon_socket,
    )


def read_host_state_linux(spec: SandboxBuildSpecLinux) -> HostStateLinux:
    if _path_is_file(SYSTEMD_RESOLV_CONF):
        systemd_resolv_conf = SYSTEMD_RESOLV_CONF
    else:
        systemd_resolv_conf = None
    return HostStateLinux(
        **_common_host_state(spec),
        resolv_conf_names_loopback=_resolv_conf_names_loopback(),
        systemd_resolv_conf=systemd_resolv_conf,
    )


def read_host_state_darwin(spec: SandboxBuildSpecDarwin) -> HostStateDarwin:
    return HostStateDarwin(**_common_host_state(spec), tty=_get_stdin_tty())
