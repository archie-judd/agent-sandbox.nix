"""The ruleset applied inside pasta's namespace, in `nft -f` syntax.

Vocabulary, not decisions, in the same sense as darwin/seatbelt.py. It knows
nothing about pasta beyond the gateway address it is handed, so the addressing
stays owned by compute.py, which is also what puts pasta on the command line.

Pure. Reads no files, runs no subprocesses, prints nothing.
"""

from typing import Sequence


def get_nft_rules(
    gateway_ip: str, proxy_port: int | None, allowed_local_ports: Sequence[int] | None
) -> list[str]:
    """The ruleset, as one `nft -f` line per entry.

    Restricted mode drops everything by default and permits only in-namespace
    loopback and TCP to the proxy. Open mode keeps the default route and drops
    only traffic addressed to the pasta gateway, which is what blocks host
    loopback services without touching internet traffic, whose destinations are
    real server addresses rather than the gateway.
    """
    if allowed_local_ports is None:
        # allowedLocalPorts is TCP-only; null means every host-local TCP port.
        matches = ["meta l4proto tcp"]
    else:
        matches = [f"tcp dport {port}" for port in allowed_local_ports]

    rules = ["add table ip sandbox_filter"]
    if proxy_port is None:
        rules.append(
            "add chain ip sandbox_filter output "
            "{ type filter hook output priority 0 ; policy accept ; }"
        )
    else:
        rules.append(
            "add chain ip sandbox_filter output "
            "{ type filter hook output priority 0 ; policy drop ; }"
        )
        rules.append("add rule ip sandbox_filter output oif lo accept")

    if matches:
        # DNAT from sandbox loopback needs route_localnet, and the translated
        # flow needs SNAT so pasta sees it as coming from the namespace address.
        rules += [
            "add table ip sandbox_nat",
            "add chain ip sandbox_nat output "
            "{ type nat hook output priority -100 ; policy accept ; }",
            "add chain ip sandbox_nat postrouting "
            "{ type nat hook postrouting priority 100 ; policy accept ; }",
        ]
        rules += [
            f"add rule ip sandbox_nat output ip daddr 127.0.0.1 {match} "
            f"dnat to {gateway_ip}"
            for match in matches
        ]
        rules += [
            f"add rule ip sandbox_nat postrouting ip saddr 127.0.0.1 "
            f"ip daddr {gateway_ip} {match} masquerade"
            for match in matches
        ]

    if proxy_port is not None:
        rules.append(
            f"add rule ip sandbox_filter output ip daddr {gateway_ip} "
            f"tcp dport {proxy_port} accept"
        )
    rules += [
        f"add rule ip sandbox_filter output ip daddr {gateway_ip} {match} accept"
        for match in matches
    ]
    if proxy_port is None:
        rules.append(f"add rule ip sandbox_filter output ip daddr {gateway_ip} drop")
    return rules
