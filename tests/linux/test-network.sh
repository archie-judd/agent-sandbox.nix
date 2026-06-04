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

print_results
exit_status
