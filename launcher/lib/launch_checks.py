import sys
from pathlib import Path

from launcher.lib.build_spec import SandboxBuildSpecDarwin, SandboxBuildSpecLinux
from launcher.lib.constants import ERROR_PREFIX, WARN_PREFIX
from launcher.lib.host_state import (
    DeclaredDir,
    DeclaredPath,
    HostStateDarwin,
    HostStateLinux,
    get_nix_daemon_socket_path,
)
from launcher.lib.launch_config.linux.seccomp import SUPPORTED_MACHINES

_AFFIRMATIVE = frozenset({"y", "Y", "yes", "Yes", "YES"})


def _get_declared_label(declared: DeclaredPath) -> str:
    if isinstance(declared, DeclaredDir):
        return f"{declared.mode}Dir"
    return f"{declared.mode}File"


def _origin_suffix(declared: DeclaredPath) -> str:
    if declared.unexpanded_path == str(declared.expanded_path):
        return ""
    return f' (declared as "{declared.unexpanded_path}")'


def _get_missing_binds(host: HostStateLinux | HostStateDarwin) -> list[DeclaredPath]:
    return [declared for declared in host.declared if not declared.exists]


def _get_relative_paths(host: HostStateLinux | HostStateDarwin) -> list[DeclaredPath]:
    return [
        declared
        for declared in host.declared
        if not declared.expanded_path.is_absolute()
    ]


def _is_cwd_above_home(host: HostStateLinux | HostStateDarwin) -> bool:
    if host.cwd == Path("/"):
        return True
    return host.cwd in host.real_home.parents


def _is_cwd_home(host: HostStateLinux | HostStateDarwin) -> bool:
    return host.cwd == host.real_home


def _get_nested_bind_conflicts(
    host: HostStateDarwin,
) -> list[tuple[DeclaredPath, str]]:
    """Declared paths that would collide when planted into the sandbox home.

    A path declared inside another resolves through the symlink planted
    earlier and back out into the real home, where ln -sfn would destroy the
    user's real file at launch.
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
    # /dev/tty rather than stdin, so this neither consumes input meant for
    # the agent nor auto-answers itself when stdin is a pipe. There is
    # deliberately no flag or environment variable to skip it.
    print(
        f"{WARN_PREFIX} launching from your home directory ({host.real_home}).",
        file=sys.stderr,
    )
    print(
        f"{WARN_PREFIX} the launch directory is bound read-write, so the agent "
        f"can read and modify everything under it. Your home is not masked in "
        f"this session.",
        file=sys.stderr,
    )
    try:
        with open("/dev/tty", "w", encoding="utf-8") as terminal:
            terminal.write(f"{WARN_PREFIX} continue? [y/N] ")
            terminal.flush()
        with open("/dev/tty", "r", encoding="utf-8") as terminal:
            reply = terminal.readline()
    except OSError as error:
        # Said out loud so a broken terminal does not look like a decline.
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

    # Fail closed: the default AF_UNIX denial is a security control.
    if (
        spec.platform == "linux"
        and isinstance(host, HostStateLinux)
        and not spec.allow_unix_sockets
        and host.machine not in SUPPORTED_MACHINES
    ):
        supported = ", ".join(sorted(SUPPORTED_MACHINES))
        refusals.append(
            f"no AF_UNIX seccomp filter is available for this machine "
            f"({host.machine}; supported: {supported}). Set "
            f"allowUnixSockets = true to launch without the denial."
        )

    # Refused rather than warned: the store grant allowNix trades away is
    # already paid by launch time, and nothing inside would say why nix fails.
    if spec.allow_nix and host.nix_daemon_socket is None:
        refusals.append(
            f"no nix daemon socket at {get_nix_daemon_socket_path()}, which "
            f"allowNix = true needs. Set NIX_DAEMON_SOCKET_PATH if the daemon "
            f"listens elsewhere."
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
                f"refusing to launch from your home directory ({host.real_home}) "
                f"with no terminal to confirm on."
            )
        elif not _confirm_home_cwd_launch(host):
            refusals.append(
                f"launching from your home directory ({host.real_home}) was declined."
            )

    return tuple(refusals)
