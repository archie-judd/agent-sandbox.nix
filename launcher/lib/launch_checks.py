"""Whether this launch may proceed at all.

Returns the reasons rather than printing them, so `prepare_launch` owns the exit
and the messages stay assertable. Every check is a pure predicate over
`HostState` with one exception, which the module cannot avoid: launching from
the real home has to be confirmed by a human, so `_confirm_home_cwd_launch`
reads `/dev/tty`. That is the only prompt in the launcher.

The git-root-is-home rule deliberately lives elsewhere. It does not refuse a
launch, it disables git for the session and warns, which makes it a decision
about what to bind rather than a refusal, so it belongs in launch_config with
the other bind decisions and its warning.
"""

import sys
from pathlib import Path

from launcher.lib.build_spec import SandboxBuildSpecDarwin, SandboxBuildSpecLinux
from launcher.lib.constants import ERROR_PREFIX, WARN_PREFIX
from launcher.lib.host_state import (
    DeclaredDir,
    DeclaredPath,
    HostStateDarwin,
    HostStateLinux,
)

_AFFIRMATIVE = frozenset({"y", "Y", "yes", "Yes", "YES"})


def _get_declared_label(declared: DeclaredPath) -> str:
    """The mkSandbox argument this path came from: rwDir, rwFile, roDir, roFile."""
    if isinstance(declared, DeclaredDir):
        return f"{declared.mode}Dir"
    return f"{declared.mode}File"


def _origin_suffix(declared: DeclaredPath) -> str:
    """How the path was written, when expansion changed it.

    Empty when it did not, since repeating an absolute path back at someone
    tells them nothing. Messages lead with the expanded path, because that is
    the thing that does not exist and the thing worth grepping for.
    """
    if declared.unexpanded_path == str(declared.expanded_path):
        return ""
    return f' (declared as "{declared.unexpanded_path}")'


def _get_missing_binds(host: HostStateLinux | HostStateDarwin) -> list[DeclaredPath]:
    """Declared paths that do not exist on the host.

    All of them, not the first: fixing one typo per relaunch is the behaviour
    this replaced.
    """
    return [declared for declared in host.declared if not declared.exists]


def _get_relative_paths(host: HostStateLinux | HostStateDarwin) -> list[DeclaredPath]:
    """Declared paths that did not expand to an absolute path.

    Nothing is a base for these. The bash handed the declared string to
    bubblewrap, which resolved it against its own working directory, so
    `rwDirs = [ "somedir" ]` bound a different folder depending on where the
    wrapper was run from. This is also what catches `$(...)`: command
    substitution no longer happens, so the text survives literally, and literal
    text is not an absolute path.
    """
    return [
        declared
        for declared in host.declared
        if not declared.expanded_path.is_absolute()
    ]


def _is_cwd_above_home(host: HostStateLinux | HostStateDarwin) -> bool:
    """Whether the launch directory sits above the real home.

    The launch directory is always bound read-write, so launching from above
    home would grant paths that are not the user's to hand over: other users'
    homes, system state. On Linux binding it over the sandbox root cannot work
    anyway.
    """
    if host.cwd == Path("/"):
        return True
    return host.cwd in host.real_home.parents


def _is_cwd_home(host: HostStateLinux | HostStateDarwin) -> bool:
    return host.cwd == host.real_home


def _get_nested_bind_conflicts(
    host: HostStateDarwin,
) -> list[tuple[DeclaredPath, str]]:
    """Declared paths that would collide when planted into the sandbox home.

    macOS plants each declared path under the real home as a symlink inside the
    ephemeral sandbox HOME, in declaration order. A path declared inside another
    resolves through the symlink planted earlier and back out into the real
    home, where mkdir -p creates directories and ln -sfn unlinks whatever the
    destination resolves to. That destroys the user's real file at launch, with
    no agent involved.

    Answerable from the declared list alone. The bash walked the real filesystem
    under $SANDBOX_HOME only because it had nowhere else to hold the set of
    paths it had already planted.

    Linux needs none of this: bubblewrap binds each path independently.
    """
    conflicts: list[tuple[DeclaredPath, str]] = []
    planted: list[DeclaredPath] = []

    for declared in host.declared:
        if not declared.expanded_path.is_relative_to(host.real_home):
            continue

        for earlier in planted:
            if declared.expanded_path == earlier.expanded_path:
                conflicts.append(
                    (
                        declared,
                        f"it is already declared as "
                        f"{_get_declared_label(earlier)}. Declare it once.",
                    )
                )
                break
            if declared.expanded_path.is_relative_to(earlier.expanded_path):
                conflicts.append(
                    (
                        declared,
                        f"it is nested inside {earlier.expanded_path}, which is also "
                        f"declared as {_get_declared_label(earlier)}. Nested binds are "
                        f"not supported.",
                    )
                )
                break
            if earlier.expanded_path.is_relative_to(declared.expanded_path):
                conflicts.append(
                    (
                        declared,
                        f"{earlier.expanded_path} is declared as "
                        f"{_get_declared_label(earlier)} and is nested inside it. "
                        f"Overlapping binds are not supported.",
                    )
                )
                break

        planted.append(declared)

    return conflicts


def _confirm_home_cwd_launch(host: HostStateLinux | HostStateDarwin) -> bool:
    """Ask, on the terminal, before exposing the whole home read-write.

    Reads /dev/tty rather than stdin so it neither consumes input meant for the
    agent nor auto-answers itself when stdin is a pipe. There is deliberately no
    flag or environment variable to skip it.
    """
    print(
        f"{WARN_PREFIX} launching from your home directory ({host.real_home}).",
        file=sys.stderr,
    )
    print(
        f"{WARN_PREFIX} the launch directory is bound read-write, so the agent can "
        f"read and modify everything under it: ssh keys, credentials, browser state, "
        f"every other project. Your home is not masked in this session.",
        file=sys.stderr,
    )
    # Two single-mode opens rather than one "r+", matching the bash this
    # replaces: `printf ... > /dev/tty` then `read < /dev/tty`. A read-write
    # handle on a terminal is not the same thing and does not need to be.
    try:
        with open("/dev/tty", "w", encoding="utf-8") as terminal:
            terminal.write(f"{WARN_PREFIX} continue? [y/N] ")
            terminal.flush()
        with open("/dev/tty", "r", encoding="utf-8") as terminal:
            reply = terminal.readline()
    except OSError as error:
        # Not a decline. Saying so keeps a broken terminal from looking like
        # the user answering no.
        print(
            f"{ERROR_PREFIX} could not ask for confirmation on /dev/tty: {error}",
            file=sys.stderr,
        )
        return False
    return reply.strip() in _AFFIRMATIVE


def get_launch_refusals(
    spec: SandboxBuildSpecLinux | SandboxBuildSpecDarwin,
    host: HostStateLinux | HostStateDarwin,
) -> tuple[str, ...]:
    """Every reason this launch must not proceed. Empty means allowed."""
    refusals: list[str] = []

    relative = _get_relative_paths(host)
    for declared in relative:
        refusals.append(
            f"{declared.expanded_path}: declared as "
            f"{_get_declared_label(declared)} but is not an absolute path; "
            f"write it out in full or use $HOME"
            f"{_origin_suffix(declared)}"
        )

    for declared in _get_missing_binds(host):
        # A relative path is reported once, for the reason that matters. Whether
        # it happens to exist relative to the launch directory is beside the
        # point, and saying both would suggest making it exist would help.
        if declared in relative:
            continue
        refusals.append(
            f"{declared.expanded_path}: declared as "
            f"{_get_declared_label(declared)} but does not exist"
            f"{_origin_suffix(declared)}"
        )

    if spec.platform == "darwin" and isinstance(host, HostStateDarwin):
        for declared, problem in _get_nested_bind_conflicts(host):
            refusals.append(
                f"{declared.expanded_path}: declared as "
                f"{_get_declared_label(declared)} but {problem}"
                f"{_origin_suffix(declared)}"
            )

    if _is_cwd_above_home(host):
        refusals.append(
            f"refusing to launch from {host.cwd}: it sits above your home directory "
            f"({host.real_home}), and the launch directory is always writable inside "
            f"the sandbox."
        )
        return tuple(refusals)

    if _is_cwd_home(host):
        if not host.has_controlling_terminal:
            refusals.append(
                f"refusing to launch from your home directory ({host.real_home}) with "
                f"no terminal to confirm on. The launch directory is always writable "
                f"inside the sandbox, so this would expose your whole home to the "
                f"agent unattended."
            )
        elif not _confirm_home_cwd_launch(host):
            refusals.append(
                f"launching from your home directory ({host.real_home}) was declined."
            )

    return tuple(refusals)
