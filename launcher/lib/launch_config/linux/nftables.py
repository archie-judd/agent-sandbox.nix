"""The ruleset applied inside pasta's namespace, in `nft -f` syntax."""

from typing import Sequence


def get_nft_rules(
    gateway_ip: str,
    proxy_port: int | None,
    allowed_host_ports: Sequence[int] | None,
    published_ports: Sequence[int] = (),
) -> list[str]:
    """Restricted mode drops everything by default and permits only
    in-namespace loopback and TCP to the proxy. Open mode drops only traffic
    addressed to the pasta gateway, which blocks host loopback services
    without touching internet traffic. published_ports are the pasta -t
    forwards' in-namespace ports."""
    if allowed_host_ports is None:
        # TCP-only; null means every host-local TCP port.
        matches = ["meta l4proto tcp"]
    else:
        matches = [f"tcp dport {port}" for port in allowed_host_ports]

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
        # Reply traffic of inbound forwards: a non-local peer is delivered
        # over the tap device (not the spliced loopback), so the server's
        # replies leave via the tap and need their own accept. `ct state
        # established` keeps this from widening egress: an outbound flow
        # sourced from a granted port never reaches established, because its
        # initial SYN is dropped here.
        rules += [
            f"add rule ip sandbox_filter output tcp sport {port} "
            "ct state established accept"
            for port in sorted(set(published_ports))
        ]

    if matches:
        # The DNAT'd flow needs SNAT so pasta sees it as coming from the
        # namespace address.
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
