from dataclasses import dataclass
from pathlib import Path
from typing import Sequence

from launcher.lib.constants import WARN_PREFIX
from launcher.lib.host_state import DeclaredDir, DeclaredPath, HostState, MaskedPath
from launcher.lib.symlinks import ResolvedPath

NIX_STORE = Path("/nix/store")


@dataclass(frozen=True, kw_only=True)
class SandboxLaunchConfig:
    # Two segments because the declared environment is injected between them
    # by launch.sh; those values never enter Python.
    argv_before_env: tuple[str, ...]
    argv_after_env: tuple[str, ...]
    passwd: str
    ca_bundle: tuple[Path, ...]
    cleanup: tuple[Path, ...]
    # Removed only if still empty: content something wrote there in the
    # meantime is not ours to delete.
    cleanup_if_empty: tuple[Path, ...]
    warnings: tuple[str, ...]


def is_already_bound(path: Path, prefixes: Sequence[Path]) -> bool:
    return any(path == prefix or prefix in path.parents for prefix in prefixes)


def get_store_symlink_targets(
    declared: Sequence[DeclaredPath],
    workspace_inner_symlinks: Sequence[ResolvedPath],
    prefixes: Sequence[Path],
    masked: Sequence[MaskedPath],
) -> tuple[tuple[Path, ...], list[str]]:
    """The symlink targets a platform should expose read-only, and the
    warnings for the ones it should not.

    Targets are kept only when in the nix store: anywhere else would let an
    agent plant a symlink that expands the sandbox on the next launch. Store
    paths are immutable and agent-unwritable.
    """
    # Files, then directories, then the symlinks inside those directories:
    # that order decides which of two paths leading to one target is the one
    # that reports it.
    files = [entry for entry in declared if not isinstance(entry, DeclaredDir)]
    dirs = [entry for entry in declared if isinstance(entry, DeclaredDir)]

    chains: list[tuple[Path, Sequence[Path]]] = [
        (entry.expanded_path, entry.hops) for entry in [*files, *dirs]
    ]
    chains += [
        (inner.physical_path, inner.hops)
        for entry in dirs
        for inner in entry.inner_symlinks
    ]
    chains += [(inner.physical_path, inner.hops) for inner in workspace_inner_symlinks]

    bound = list(prefixes)

    targets: list[Path] = []
    warnings: list[str] = []
    resolved: set[Path] = set()

    for link, hops in chains:
        if any(
            link == mask.expanded_path
            or (mask.kind == "dir" and link.is_relative_to(mask.expanded_path))
            for mask in masked
        ):
            continue
        for landing in hops:
            if landing in resolved:
                continue
            resolved.add(landing)
            if is_already_bound(landing, bound):
                continue
            if NIX_STORE not in landing.parents:
                warnings.append(
                    f"{WARN_PREFIX} ignoring symlink to '{landing}': outside "
                    f"permitted paths. Declare it as a rwDir, rwFile, roDir or "
                    f"roFile to allow access."
                )
                continue
            targets.append(landing)
            bound.append(landing)

    targets = [
        target
        for target in targets
        if not any(other in target.parents for other in targets)
    ]
    return tuple(targets), warnings


def get_sessions_root_warnings(host: HostState, session_dir: Path) -> list[str]:
    # A warning rather than a refusal: an rwDir on $HOME/.local/state is a
    # plausible accident, and the sessions root is relocatable.
    sessions_root = session_dir.parent
    warnings = []
    for declared in host.declared:
        if declared.mode != "rw":
            continue
        if not sessions_root.is_relative_to(declared.expanded_path):
            continue
        warnings.append(
            f"{WARN_PREFIX} {declared.expanded_path} is declared read-write and "
            f"contains this sandbox's own session records ({sessions_root})."
        )
    return warnings
