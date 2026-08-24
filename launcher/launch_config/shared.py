"""The computed description of a launch, and the only step that writes it out.

SandboxLaunchConfig owns nothing and creates nothing. It is what compute
returned: an argv either side of the declared environment, some file bodies,
some symlinks to plant, the list of things to remove at exit, and any warnings
for the user. Everything in it is a value, so the whole launch is assertable
without a filesystem.
"""

from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True, kw_only=True)
class SandboxLaunchConfig:
    # Two segments because the declared environment is injected between them by
    # the stub, from a fragment Nix generates. Those values never enter Python.
    argv_before_env: tuple[str, ...]
    argv_after_env: tuple[str, ...]
    passwd: str
    cleanup: tuple[Path, ...]
    warnings: tuple[str, ...]
