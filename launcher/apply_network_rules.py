"""Configure pasta's network namespace, then exec onwards. Every failure is
fatal: the ruleset is a security control, so nothing may fall through to the
exec below.

Importing launcher.lib.constants imports launcher/__init__.py and
launcher/lib/__init__.py on the way, which is why both are kept empty.
"""

import json
import os
import subprocess
import sys

from launcher.lib.constants import ERROR_PREFIX, SECCOMP_FD


def _run(argv: list[str], failure: str, stdin: str | None = None) -> None:
    try:
        subprocess.run(argv, input=stdin, text=True, check=True)
    except (OSError, subprocess.CalledProcessError) as error:
        raise SystemExit(f"{ERROR_PREFIX} {failure}: {error}") from error


def main() -> None:
    separator = sys.argv.index("--")
    network_file = sys.argv[1]
    command = sys.argv[separator + 1 :]

    with open(network_file, encoding="utf-8") as handle:
        network = json.load(handle)

    for path, value in network["sysctls"].items():
        try:
            with open(path, "w", encoding="utf-8") as handle:
                handle.write(value)
        except OSError as error:
            raise SystemExit(
                f"{ERROR_PREFIX} could not write {path}: {error}"
            ) from error

    _run(
        [network["nft"], "-f", "-"],
        "could not load the sandbox nftables ruleset",
        stdin="\n".join(network["rules"]) + "\n",
    )

    # Left open on SECCOMP_FD for bubblewrap's --seccomp: this is the only
    # process that can open a descriptor bubblewrap inherits, because pasta
    # does not pass one to its child.
    if network["seccomp_filter"] is not None:
        try:
            fd = os.open(network["seccomp_filter"], os.O_RDONLY)
        except OSError as error:
            raise SystemExit(
                f"{ERROR_PREFIX} could not open the seccomp filter "
                f"{network['seccomp_filter']}: {error}"
            ) from error
        if fd != SECCOMP_FD:
            os.dup2(fd, SECCOMP_FD)
            os.close(fd)
        # dup2 leaves the new descriptor inheritable, but not when source and
        # target coincide, so it is forced rather than assumed.
        os.set_inheritable(SECCOMP_FD, True)

    os.execv(command[0], command)


if __name__ == "__main__":
    main()
