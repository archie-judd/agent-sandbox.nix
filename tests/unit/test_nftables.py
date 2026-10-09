from launcher.lib.launch_config.linux.nftables import get_nft_rules

GATEWAY_IP = "10.0.2.2"
PROXY_PORT = 12345
ALLOWED_HOST_PORTS = [5432]


def _reply_accepts(rules: list[str]) -> list[str]:
    return [rule for rule in rules if "ct state established" in rule]


def test_every_published_port_gets_its_own_reply_accept() -> None:
    rules = get_nft_rules(GATEWAY_IP, PROXY_PORT, ALLOWED_HOST_PORTS, [18944, 18945])

    assert _reply_accepts(rules) == [
        "add rule ip sandbox_filter output tcp sport 18944 ct state established accept",
        "add rule ip sandbox_filter output tcp sport 18945 ct state established accept",
    ]


def test_no_reply_accepts_without_published_ports() -> None:
    rules = get_nft_rules(GATEWAY_IP, PROXY_PORT, ALLOWED_HOST_PORTS)

    assert _reply_accepts(rules) == []


def test_open_mode_emits_no_reply_accepts() -> None:
    # Open mode's output policy is accept, so replies need no rule of their own.
    rules = get_nft_rules(GATEWAY_IP, None, ALLOWED_HOST_PORTS, [18944])

    assert _reply_accepts(rules) == []


def test_open_mode_drops_only_the_gateway() -> None:
    rules = get_nft_rules(GATEWAY_IP, None, [])

    assert "policy accept" in rules[1]
    assert [rule for rule in rules if rule.endswith("drop")] == [
        f"add rule ip sandbox_filter output ip daddr {GATEWAY_IP} drop"
    ]


def test_restricted_mode_drops_by_default_and_admits_the_proxy() -> None:
    rules = get_nft_rules(GATEWAY_IP, PROXY_PORT, [])

    assert "policy drop" in rules[1]
    assert f"add rule ip sandbox_filter output ip daddr {GATEWAY_IP} tcp dport {PROXY_PORT} accept" in rules


def test_an_allowed_host_port_is_dnatted_to_the_gateway() -> None:
    rules = get_nft_rules(GATEWAY_IP, None, [5432])

    assert f"add rule ip sandbox_nat output ip daddr 127.0.0.1 tcp dport 5432 dnat to {GATEWAY_IP}" in rules
    assert f"add rule ip sandbox_filter output ip daddr {GATEWAY_IP} tcp dport 5432 accept" in rules


def test_null_host_ports_dnat_every_tcp_port() -> None:
    rules = get_nft_rules(GATEWAY_IP, None, None)

    assert f"add rule ip sandbox_nat output ip daddr 127.0.0.1 meta l4proto tcp dnat to {GATEWAY_IP}" in rules
