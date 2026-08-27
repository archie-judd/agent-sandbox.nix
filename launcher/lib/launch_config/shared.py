"""The computed description of a launch, and the only step that writes it out.

SandboxLaunchConfig owns nothing and creates nothing. It is what compute
returned: an argv either side of the declared environment, some file bodies,
some symlinks to plant, the list of things to remove at exit, and any warnings
for the user. Everything in it is a value, so the whole launch is assertable
without a filesystem.
"""

from dataclasses import dataclass
from pathlib import Path

from launcher.lib.constants import WARN_PREFIX
from launcher.lib.host_state import GitState, HostState


@dataclass(frozen=True, kw_only=True)
class SandboxLaunchConfig:
    # Two segments because the declared environment is injected between them by
    # the stub, from a fragment Nix generates. Those values never enter Python.
    argv_before_env: tuple[str, ...]
    argv_after_env: tuple[str, ...]
    passwd: str
    # Concatenated, in order, into the session directory's ca-bundle.pem: the
    # system certificates plus the proxy's ephemeral CA. Empty when the wrapper
    # is unrestricted, since there is no proxy and no bundle to assemble.
    ca_bundle: tuple[Path, ...]
    cleanup: tuple[Path, ...]
    # Removed only if still empty. Bubblewrap materialises a mount destination
    # on the host, so a path bound over to make it read-only has to go; but if
    # something wrote real content there in the meantime it must be left alone.
    cleanup_if_empty: tuple[Path, ...]
    warnings: tuple[str, ...]


def get_sessions_root_warnings(host: HostState, session_dir: Path) -> list[str]:
    """Whether a declared read-write path hands the agent its own session records.

    The sessions root holds one directory per launch, each with the computed
    profile or bind list, both logs and the cleanup lists. A declared rwDir or
    rwFile above it makes all of that writable from inside the sandbox, so an
    agent can edit the record of what it was allowed to do, and rewrite the
    configuration a running session is still reading from.

    A warning rather than a refusal: it is a plausible thing to have declared by
    accident (an rwDir on $HOME/.local/state, or on the home itself), the
    sessions root is relocatable, and refusing would break a launch over
    something the user may have meant.

    Only read-write paths, and only ancestors. A read-only declaration exposes
    the records without endangering them, and a declared path below the root is
    inside somebody else's session rather than above this one.
    """
    sessions_root = session_dir.parent
    warnings = []
    for declared in host.declared:
        if declared.mode != "rw":
            continue
        if not sessions_root.is_relative_to(declared.expanded_path):
            continue
        warnings.append(
            f"{WARN_PREFIX} {declared.expanded_path} is declared read-write and "
            f"contains this sandbox's own session records ({sessions_root}), so "
            f"the agent can read and rewrite the configuration and logs of every "
            f"session, including this one."
        )
    return warnings


def _is_git_root_the_home(host: HostState, git: GitState) -> bool:
    """Whether exposing this repository would expose the whole home directory.

    A home-rooted repo's object store holds the history of tracked dotfiles:
    ~/.ssh/config, tokens. The repo root is bound read-only and the gitdir
    read-write, so there is no safe partial exposure.

    Launching from the home directory itself is the exception. The user has
    already confirmed that the whole home is exposed read-write, so refusing git
    there would hide nothing and would break the case that motivates it, which
    is working on a home-rooted dotfiles repo. A root strictly above the home
    stays refused either way, since that reaches beyond what was consented to.
    """
    if host.real_home == git.repo_root:
        return host.cwd != host.real_home
    return git.repo_root in host.real_home.parents


def get_usable_git_state(host: HostState) -> tuple[GitState | None, list[str]]:
    """The git state to build rules from, plus any warning about dropping it.

    This is a decision, not an observation, which is why it lives here rather
    than in host_state or launch_checks. It does not refuse a launch: it
    disables git for the session and says so.

    Shared because it is one policy, and it is the same one on both
    platforms: seatbelt would grant the repo root and bubblewrap would bind
    it, and neither should when the root is the home directory.
    """
    if host.git is None:
        return None, []
    if _is_git_root_the_home(host, host.git):
        return None, [
            f"{WARN_PREFIX} git root resolves to your home directory "
            f"({host.real_home}) — refusing to expose it. git is disabled for "
            f"this session."
        ]
    return host.git, []
