"""Configure pasta's network namespace, then exec onwards.

Runs as the first process inside the namespace, before bubblewrap. Holds no
policy and no paths of its own: it reads network.json, does what it says, and
replaces itself with the rest of the chain.

On the Linux hot path, so it imports only what it uses: json to read the file,
subprocess to run nft and ip, os to exec onwards. Reaching launcher.lib.constants
imports launcher/__init__.py and launcher/lib/__init__.py on the way, so anything
added to either is imported here too, which is why both are empty.

Every failure here is fatal and says so. The ruleset and the dropped default
route are what stand between a restricted sandbox and the open internet, so
nothing may fall through to the exec below.
"""

import json
import os
import subprocess
import sys

from launcher.lib.constants import ERROR_PREFIX


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

    # DNAT from the sandbox's loopback needs route_localnet, which no nft
    # ruleset can express.
    for path, value in network["sysctls"].items():
        try:
            with open(path, "w", encoding="utf-8") as handle:
                handle.write(value)
        except OSError as error:
            raise SystemExit(
                f"{ERROR_PREFIX} could not write {path}: {error}"
            ) from error

    # Removing the default route means the namespace cannot reach the wider
    # internet directly. The drop policy in the ruleset would block it anyway;
    # this makes it unroutable as well.
    if network["delete_default_route"]:
        _run(
            [network["ip"], "route", "del", "default"],
            "could not remove default route",
        )

    _run(
        [network["nft"], "-f", "-"],
        "could not load the sandbox nftables ruleset",
        stdin="\n".join(network["rules"]) + "\n",
    )

    os.execv(command[0], command)


if __name__ == "__main__":
    main()
