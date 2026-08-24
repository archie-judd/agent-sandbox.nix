"""Configure pasta's network namespace, then exec onwards.

Runs as the first process inside the namespace, before bubblewrap. Holds no
policy and no paths of its own: it reads network.json, does what it says, and
replaces itself with the rest of the chain.

On the Linux hot path, so it imports only what it uses: json to read the file,
subprocess to run nft and ip, os to exec onwards. Anything added to
launcher/__init__.py is imported here too, which is why that file is empty.
"""

import json
import os
import subprocess
import sys


def main() -> None:
    separator = sys.argv.index("--")
    network_file = sys.argv[1]
    command = sys.argv[separator + 1 :]

    with open(network_file, encoding="utf-8") as handle:
        network = json.load(handle)

    # DNAT from the sandbox's loopback needs route_localnet, which no nft
    # ruleset can express.
    for path, value in network["sysctls"].items():
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(value)

    # Removing the default route means the namespace cannot reach the wider
    # internet directly. The drop policy in the ruleset would block it anyway;
    # this makes it unroutable as well.
    if network["delete_default_route"]:
        subprocess.run([network["ip"], "route", "del", "default"], check=True)

    subprocess.run(
        [network["nft"], "-f", "-"],
        input="\n".join(network["rules"]) + "\n",
        text=True,
        check=True,
    )

    os.execv(command[0], command)


if __name__ == "__main__":
    main()
