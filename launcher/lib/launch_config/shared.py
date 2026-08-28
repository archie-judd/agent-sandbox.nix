from dataclasses import dataclass
from pathlib import Path

from launcher.lib.constants import WARN_PREFIX
from launcher.lib.host_state import HostState


@dataclass(frozen=True, kw_only=True)
class SandboxLaunchConfig:
    # Two segments because the declared environment is injected between them
    # by the stub; those values never enter Python.
    argv_before_env: tuple[str, ...]
    argv_after_env: tuple[str, ...]
    passwd: str
    ca_bundle: tuple[Path, ...]
    cleanup: tuple[Path, ...]
    # Removed only if still empty: content something wrote there in the
    # meantime is not ours to delete.
    cleanup_if_empty: tuple[Path, ...]
    warnings: tuple[str, ...]


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
