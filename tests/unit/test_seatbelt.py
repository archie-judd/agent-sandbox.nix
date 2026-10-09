from launcher.lib.build_spec import PublishedPort
from launcher.lib.launch_config.darwin.seatbelt import network_open, network_restricted

PROXY_PORT = 12345


def test_an_allowed_host_port_gets_one_outbound_rule() -> None:
    lines = network_open([3000])

    assert lines.count('(allow network-outbound (remote ip "localhost:3000"))') == 1


def test_null_allowed_host_ports_allow_every_port() -> None:
    lines = network_open(None)

    assert '(allow network-outbound (remote ip "localhost:*"))' in lines
    assert not any("localhost:3000" in line for line in lines)


def test_a_published_port_gets_a_loopback_bind_and_inbound_rule() -> None:
    lines = network_restricted(PROXY_PORT, [], [PublishedPort(port=3000, bind_addr="127.0.0.1")])

    assert lines.count('(allow network-bind (local ip "localhost:3000"))') == 1
    assert lines.count('(allow network-inbound (local ip "localhost:3000"))') == 1


def test_a_wider_bind_address_becomes_the_wildcard() -> None:
    lines = network_restricted(PROXY_PORT, [], [PublishedPort(port=3000, bind_addr="0.0.0.0")])

    assert lines.count('(allow network-inbound (local ip "*:3000"))') == 1
    assert not any("localhost:3000" in line for line in lines)


def test_no_published_ports_emit_no_inbound_rules() -> None:
    lines = network_restricted(PROXY_PORT, [], [])

    assert not any("network-inbound" in line for line in lines)
