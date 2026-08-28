"""Works out which bubblewrap binds each declared path and the git directory
need. Emission order is compute.py's.

Bubblewrap resolves mount destinations against its own intermediate root, not
the host's filesystem, so a declared path that is itself a symlink cannot be
a mount destination once an enclosing bind has exposed it, and no ordering of
the binds avoids that.
"""

from dataclasses import dataclass
from pathlib import Path
from typing import Sequence

from launcher.lib.build_spec import SandboxBuildSpecLinux
from launcher.lib.constants import WARN_PREFIX
from launcher.lib.git_state import GitState
from launcher.lib.host_state import (
    DeclaredDir,
    DeclaredPath,
    HostStateLinux,
    get_grantable_repo_root,
)
from launcher.lib.symlinks import Symlink

NIX_STORE = Path("/nix/store")

# Bound unconditionally, so a symlink target under any of them is already
# reachable.
ETC_PREFIXES = (
    Path("/etc/resolv.conf"),
    Path("/etc/passwd"),
    Path("/etc/ssl/certs"),
    Path("/etc/static"),
    Path("/etc/pki"),
)


@dataclass(frozen=True, kw_only=True)
class DeclaredBinds:
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
    # The repo root only when compute.py actually binds it: listing a prefix
    # nothing binds would skip a declared path that then has no bind at all.
    repo_root = get_grantable_repo_root(host, git)
    if repo_root is not None:
        prefixes.append(repo_root)
    if git is not None:
        prefixes.append(git.common_dir)
    return prefixes


def _get_parent_dirs(
    path: Path, prefixes: Sequence[Path], seen: set[Path]
) -> list[Path]:
    # Not added to the bound prefixes: --dir creates an empty directory, it
    # does not expose contents, so a sibling still needs its own bind.
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
    # Targets are bound read-only and only when in the nix store: anywhere
    # else would let an agent plant a symlink that expands the sandbox on the
    # next launch. Store paths are immutable and agent-unwritable.
    if target in resolved:
        return [], []
    resolved.add(target)
    if _is_already_bound(target, prefixes):
        return [], []
    if NIX_STORE not in target.parents:
        return [], [
            f"{WARN_PREFIX} ignoring symlink to '{target}': outside permitted "
            f"paths. Declare it as a rwDir, rwFile, roDir or roFile to allow "
            f"access."
        ]
    return ["--ro-bind", str(target), str(target)], []


def _get_parent_symlink_args(
    parent_symlinks: Sequence[Symlink], prefixes: Sequence[Path], planted: set[Path]
) -> list[str]:
    # Planted even when the target is already exposed: the kernel walks the
    # declared name, and a missing directory partway along it fails the open
    # with ENOENT. Not a way around the nix-store check above: a symlink is
    # a name, not an access grant.
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
    # A symlinked file is bound from its final target, so the declared name
    # holds the content; a symlinked directory is bound from itself, so a
    # roDir keeps its read-only mode inside a read-write parent. A symlink an
    # enclosing bind already exposes is skipped entirely: bubblewrap cannot
    # create a mountpoint on top of it and dies.
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
    # Files, then directories, then the symlinks inside those directories:
    # that order decides which of two paths leading to one target carries the
    # bind.
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

        # A symlinked file bound at its declared name needs that name's
        # parents to exist first.
        if bind_args and not is_dir and declared.hops:
            for parent in _get_parent_dirs(
                declared.expanded_path, prefixes, seen_parents
            ):
                parent_dirs += ["--dir", str(parent)]

    for declared_dir in dirs:
        for inner in declared_dir.inner_symlinks:
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
    # A protected path that does not exist yet would otherwise simply be
    # created; binding an empty file over it makes it read-only instead.
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
