"""How declared paths and the git directory become bubblewrap arguments.

Vocabulary, not decisions, in the same sense as darwin/seatbelt.py: this module
works out which binds each path needs and groups them, but the order they are
emitted in is compute.py's, and nothing here knows what the final argument list
looks like.

Pure. Reads no files, runs no subprocesses, prints nothing.

The apparent repetition in the resolve logic is real. Bubblewrap resolves mount
destinations against its own intermediate root rather than the host's
filesystem, so a declared path that is itself a symlink cannot be a mount
destination once an enclosing bind has exposed it, and no ordering of the binds
avoids that.
"""

from dataclasses import dataclass
from pathlib import Path
from typing import Sequence

from launcher.lib.build_spec import SandboxBuildSpecLinux
from launcher.lib.constants import WARN_PREFIX
from launcher.lib.host_state import (
    DeclaredDir,
    DeclaredPath,
    GitState,
    HostStateLinux,
)
from launcher.lib.symlinks import Symlink

NIX_STORE = Path("/nix/store")

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
class DeclaredBinds:
    """The argument groups the declared paths contribute, kept apart because
    their emission order in the argument list differs from the order they are
    computed in."""

    dir_binds: tuple[str, ...]
    ro_dir_binds: tuple[str, ...]
    file_binds: tuple[str, ...]
    ro_file_binds: tuple[str, ...]
    parent_dirs: tuple[str, ...]
    symlink_targets: tuple[str, ...]
    parent_symlinks: tuple[str, ...]
    warnings: tuple[str, ...]


def _is_already_bound(path: Path, prefixes: Sequence[Path]) -> bool:
    return any(path == prefix or prefix in path.parents for prefix in prefixes)


def get_bound_prefixes(
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


def _get_parent_dirs(
    path: Path, prefixes: Sequence[Path], seen: set[Path]
) -> list[Path]:
    """Ancestors of `path` that bubblewrap has not been told about.

    Needed whenever something is bound at a path whose parents do not exist in
    the sandbox yet, such as under the ephemeral HOME tmpfs. These are not added
    to the bound prefixes: --dir creates an empty directory, it does not expose
    its contents, so a sibling still needs its own bind.

    `seen` is updated in place. The dedup runs across every call, and the set of
    directories it ends up creating does not depend on the order callers ask in:
    walking upwards stops at the first one already seen, so an ancestor asked
    for twice contributes its remaining parents once.
    """
    needed: list[Path] = []
    current = path.parent
    while current != Path("/"):
        if _is_already_bound(current, prefixes) or current in seen:
            break
        needed.append(current)
        seen.add(current)
        current = current.parent
    return needed


def _get_symlink_target_args(
    target: Path, prefixes: Sequence[Path], resolved: set[Path]
) -> tuple[list[str], list[str]]:
    """The bind exposing one hop's landing, and any warning about refusing it.

    Landings are bound read-only whatever the declared mode, and only when they
    are in the nix store: a target anywhere else would let an agent plant a
    symlink that expands the sandbox on the next launch. Store paths are exempt
    because they are immutable and agent-unwritable.

    Returns (args, warnings), both empty when the target is already exposed.
    `resolved` is updated in place, because two declared paths can lead to the
    same target and it is bound once.
    """
    if target in resolved:
        return [], []
    resolved.add(target)
    if _is_already_bound(target, prefixes):
        return [], []
    if NIX_STORE not in target.parents:
        return [], [
            f"{WARN_PREFIX} ignoring symlink to '{target}' — target is outside "
            f"permitted paths; declare it as a rwDir, rwFile, roDir or roFile "
            f"to allow access"
        ]
    return ["--ro-bind", str(target), str(target)], []


def _get_parent_symlink_args(
    parent_symlinks: Sequence[Symlink], prefixes: Sequence[Path], planted: set[Path]
) -> list[str]:
    """--symlink for each symlinked directory a path is reached through.

    Takes the symlinks rather than what carried them, because a declared path
    and a hop of its chain both have them and both need them planted.

    Emitted whatever becomes of the target, including when the target is already
    exposed. The name the link holds still has to exist inside the sandbox: the
    kernel walks that name, and a missing directory partway along it fails the
    open with ENOENT while the file sits bound at its flattened path, reachable
    only under a name nothing asks for.

    This is not a way around the nix-store check above. A symlink is a name, not
    an access grant, and following it reaches a file only if something else bound
    that file.

    Skipped where an enclosing bind already exposes the link, which is the host's
    own symlink and so already the right thing: planting over it would give
    bubblewrap two instructions for one path.

    `planted` is updated in place, because two paths can share a parent.
    """
    args: list[str] = []
    for link in parent_symlinks:
        if link.path in planted or _is_already_bound(link.path, prefixes):
            continue
        planted.add(link.path)
        args.extend(["--symlink", str(link.points_to), str(link.path)])
    return args


def _get_hop_args(
    hops: Sequence[Path],
    prefixes: Sequence[Path],
    resolved: set[Path],
    seen_parents: set[Path],
) -> tuple[list[str], list[str], list[str]]:
    """Everything one chain of hop landings contributes, in the order the
    fields of DeclaredBinds carry it: (symlink_targets, parent_dirs, warnings).

    Only landings: the links met while walking a hop's text are recorded by
    resolve_path as parent symlinks of the path that was resolved, so they are
    planted with the rest of its parent symlinks rather than here.
    """
    targets: list[str] = []
    parent_dirs: list[str] = []
    warnings: list[str] = []

    for landing in hops:
        target_args, target_warnings = _get_symlink_target_args(
            landing, prefixes, resolved
        )
        targets += target_args
        warnings += target_warnings
        if target_args:
            for parent in _get_parent_dirs(landing, prefixes, seen_parents):
                parent_dirs += ["--dir", str(parent)]

    return targets, parent_dirs, warnings


def _get_declared_bind_args(
    declared: DeclaredPath, prefixes: Sequence[Path]
) -> list[str]:
    """The bind exposing one declared path at the name it was declared under.

    A path that is not a symlink is bound at itself.

    A symlink is skipped when an enclosing bind already exposes it: bubblewrap
    resolves mount destinations against its own intermediate root, where an
    absolute symlink target does not exist, so it cannot create a mountpoint on
    top of one and dies. Nothing is lost, since the covering bind exposes the
    link and the chain's targets are bound separately.

    Otherwise a symlinked file is bound from its final target, so the declared
    name holds the content, while a symlinked directory is bound from itself, so
    a roDir keeps its read-only mode inside a read-write parent.
    """
    path = declared.expanded_path
    flag = "--bind" if declared.mode == "rw" else "--ro-bind"
    if not declared.hops:
        return [flag, str(path), str(path)]
    if _is_already_bound(path.parent, prefixes):
        return []
    if isinstance(declared, DeclaredDir):
        return [flag, str(path), str(path)]
    final = declared.hops[-1]
    if NIX_STORE not in final.parents:
        return []
    return [flag, str(final), str(path)]


def get_declared_binds(host: HostStateLinux, prefixes: Sequence[Path]) -> DeclaredBinds:
    """Bind each declared path, and everything its symlinks lead to.

    Declared files first, then declared directories, then the symlinks sitting
    inside those directories. That order decides which of two paths leading to
    one target carries the bind, so it is preserved from the bash this replaces.
    """
    dir_binds: list[str] = []
    ro_dir_binds: list[str] = []
    file_binds: list[str] = []
    ro_file_binds: list[str] = []
    parent_dirs: list[str] = []
    symlink_targets: list[str] = []
    parent_symlinks: list[str] = []
    warnings: list[str] = []
    resolved: set[Path] = set()
    planted: set[Path] = set()
    seen_parents: set[Path] = set()

    files = [d for d in host.declared if not isinstance(d, DeclaredDir)]
    dirs = [d for d in host.declared if isinstance(d, DeclaredDir)]

    for declared in [*files, *dirs]:
        # Every symlinked directory the walk met, whether above the declared
        # name or inside a hop's text: resolve_path records them in one list,
        # in walk order. The name a program opens is the one that was
        # declared, and expanded_path is already the flattened form of it.
        parent_symlinks += _get_parent_symlink_args(
            declared.parent_symlinks, prefixes, planted
        )

        targets, chain_dirs, chain_warnings = _get_hop_args(
            declared.hops, prefixes, resolved, seen_parents
        )
        symlink_targets += targets
        parent_dirs += chain_dirs
        warnings += chain_warnings

        bind_args = _get_declared_bind_args(declared, prefixes)
        is_dir = isinstance(declared, DeclaredDir)
        if is_dir and declared.mode == "rw":
            dir_binds += bind_args
        elif is_dir:
            ro_dir_binds += bind_args
        elif declared.mode == "rw":
            file_binds += bind_args
        else:
            ro_file_binds += bind_args

        # A symlinked file bound at its declared name needs that name's parents
        # to exist first. A directory needs nothing: its own bind creates the
        # destination, and a path that is not a symlink is bound where it
        # already is.
        if bind_args and not is_dir and declared.hops:
            for parent in _get_parent_dirs(
                declared.expanded_path, prefixes, seen_parents
            ):
                parent_dirs += ["--dir", str(parent)]

    for declared_dir in dirs:
        for inner in declared_dir.inner_symlinks:
            # An inner entry's parent symlinks include the declared directory's
            # own parents, and the directory itself when it is a symlink, since
            # resolve_path walks from the root. All of those are already
            # planted or covered by the enclosing bind, so _get_parent_symlink_args
            # skips them and only links found inside the entry's hop text are new.
            parent_symlinks += _get_parent_symlink_args(
                inner.parent_symlinks, prefixes, planted
            )
            targets, chain_dirs, chain_warnings = _get_hop_args(
                inner.hops, prefixes, resolved, seen_parents
            )
            symlink_targets += targets
            parent_dirs += chain_dirs
            warnings += chain_warnings

    return DeclaredBinds(
        dir_binds=tuple(dir_binds),
        ro_dir_binds=tuple(ro_dir_binds),
        file_binds=tuple(file_binds),
        ro_file_binds=tuple(ro_file_binds),
        parent_dirs=tuple(parent_dirs),
        symlink_targets=tuple(symlink_targets),
        parent_symlinks=tuple(parent_symlinks),
        warnings=tuple(warnings),
    )


def get_git_binds(
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
