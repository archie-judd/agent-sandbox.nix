#!/usr/bin/env bash
# Network restriction tests (Linux-specific)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

source "$SCRIPT_DIR/../lib.sh"

echo "=== Network restriction tests (Linux) ==="
echo

# Build a sandbox with restrictNetwork=true and one allowed domain
SANDBOXED_NET=$(nix-build --no-out-link "$SCRIPT_DIR/../fixtures/network-allowed.nix")
NET_SHELL="$SANDBOXED_NET/bin/sandboxed-bash-net"
run() { "$NET_SHELL" --norc --noprofile -c "$@" >/dev/null 2>&1; }

# Linux only: DNS resolution is blocked when restrictNetwork=true
expect_fail "DNS resolution blocked when restrictNetwork=true" \
	'getent hosts example.com'

# Test: sandbox cannot reach the proxy host on non-proxy TCP ports.
# The nftables OUTPUT rule in the route-restrict script allows only the proxy
# port through to the host IP. Without it, every open port on the host machine
# (SSH, databases, dev servers) is directly reachable from the sandbox even
# though the wider internet is blocked by the route restriction.
# We detect the host IP the same way sandbox startup does (routing to 1.1.1.1),
# start a raw TCP listener on that IP on a known-free port, verify it is up
# from outside the sandbox, then confirm the sandbox cannot reach it.
# The nftables rule DROPs (not REJECTs) so we use curl --max-time to bound
# the probe rather than /dev/tcp which would hang until the kernel timeout.
_HOST_IP=$(ip -4 route get 1.1.1.1 2>/dev/null | grep -oP 'src \K\S+')
if [ -z "$_HOST_IP" ]; then
	echo "SKIP: could not determine host IP; skipping host-IP port restriction test" >&2
else
	HOST_IP_PORT=18918
	if nc -z "$_HOST_IP" "$HOST_IP_PORT" 2>/dev/null; then
		echo "FAIL: test setup — $_HOST_IP:$HOST_IP_PORT already in use" >&2
		exit 1
	fi
	( nc -l "$_HOST_IP" "$HOST_IP_PORT" >/dev/null 2>&1 ) &
	_HOST_IP_SVC_PID=$!
	trap 'kill "$_HOST_IP_SVC_PID" 2>/dev/null || true' EXIT
	_ready=0
	for _ in 1 2 3 4 5; do
		if nc -z "$_HOST_IP" "$HOST_IP_PORT" 2>/dev/null; then
			_ready=1; break
		fi
		sleep 0.2
	done
	if [ "$_ready" -ne 1 ]; then
		echo "FAIL: test setup — nc listener never came up on $_HOST_IP:$HOST_IP_PORT" >&2
		kill "$_HOST_IP_SVC_PID" 2>/dev/null || true
		exit 1
	fi
	expect_fail "proxy host non-proxy port unreachable from sandbox (nftables)" \
		"curl -sf --noproxy '*' --max-time 2 http://$_HOST_IP:$HOST_IP_PORT/"
	kill "$_HOST_IP_SVC_PID" 2>/dev/null || true
	trap - EXIT
fi

# Test: sandbox cannot reach the pasta gateway (10.0.2.2) on non-proxy TCP ports.
# pasta translates connections to 10.0.2.2 into host loopback connections, so
# without this rule a sandboxed agent can reach SSH, databases, and any other
# service on 127.0.0.1 — bypassing the external-IP rule entirely.
# We bind a listener on the host's 127.0.0.1 (pasta forwards 10.0.2.2:<port>
# → 127.0.0.1:<port>) and probe it from inside the sandbox via 10.0.2.2.
PASTA_GW_PORT=18919
if nc -z 127.0.0.1 "$PASTA_GW_PORT" 2>/dev/null; then
	echo "FAIL: test setup — 127.0.0.1:$PASTA_GW_PORT already in use; cannot run pasta-gateway test" >&2
	exit 1
fi
( nc -l 127.0.0.1 "$PASTA_GW_PORT" >/dev/null 2>&1 ) &
_PASTA_GW_SVC_PID=$!
trap 'kill "$_PASTA_GW_SVC_PID" 2>/dev/null || true' EXIT
_ready=0
for _ in 1 2 3 4 5; do
	if nc -z 127.0.0.1 "$PASTA_GW_PORT" 2>/dev/null; then
		_ready=1; break
	fi
	sleep 0.2
done
if [ "$_ready" -ne 1 ]; then
	echo "FAIL: test setup — nc listener never came up on 127.0.0.1:$PASTA_GW_PORT" >&2
	kill "$_PASTA_GW_SVC_PID" 2>/dev/null || true
	exit 1
fi
expect_fail "pasta gateway non-proxy port unreachable from sandbox (nftables)" \
	"curl -sf --noproxy '*' --max-time 2 http://10.0.2.2:$PASTA_GW_PORT/"
kill "$_PASTA_GW_SVC_PID" 2>/dev/null || true
trap - EXIT

# Test: sandbox cannot send UDP to the pasta gateway (10.0.2.2).
# The nftables OUTPUT chain now has policy drop; only TCP to the proxy
# port is accepted, so UDP is dropped before it reaches pasta's forwarder.
# UDP is connectionless — the send from the sandbox always succeeds locally —
# so we verify on the listener side: start a UDP listener on host loopback
# (pasta forwards 10.0.2.2:<port> → 127.0.0.1:<port>), let the sandbox send
# a datagram, then assert the listener received nothing.
PASTA_GW_UDP_PORT=18921
_UDP_TMP=$(mktemp)
trap 'rm -f "$_UDP_TMP"' EXIT
( nc -lu 127.0.0.1 "$PASTA_GW_UDP_PORT" >"$_UDP_TMP" 2>/dev/null ) &
_UDP_SVC_PID=$!
trap 'kill "$_UDP_SVC_PID" 2>/dev/null || true; rm -f "$_UDP_TMP"' EXIT
sleep 0.3  # nc -lu binds immediately; brief pause is enough
run "bash -c 'echo probe >/dev/udp/10.0.2.2/$PASTA_GW_UDP_PORT'" || true  # send always returns 0
sleep 0.3  # give pasta time to forward if it were going to
expect_ok "udp to pasta gateway dropped (listener received nothing)" \
	"[ ! -s '$_UDP_TMP' ]"
kill "$_UDP_SVC_PID" 2>/dev/null || true
trap - EXIT
rm -f "$_UDP_TMP"

# Test: sandbox cannot ping the pasta gateway (ICMP blocked by default-drop).
# First confirm that unprivileged ping to the namespace's own loopback works;
# if it doesn't (e.g. ping_group_range not permissive in this namespace) we
# skip the gateway probe rather than record a false positive.
if run "ping -c 1 -W 2 127.0.0.1"; then
	expect_fail "icmp to pasta gateway dropped" \
		'ping -c 1 -W 2 10.0.2.2'
else
	echo "SKIP: unprivileged ping not available in this namespace; skipping ICMP test" >&2
fi

print_results
exit_status
