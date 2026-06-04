#!/usr/bin/env bash
# Network restriction tests (shared across platforms)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

source "$SCRIPT_DIR/../lib.sh"

echo "=== Network restriction tests (shared) ==="
echo

# --- Backward-compat list-format tests ---

# Build a sandbox with restrictNetwork=true and one allowed domain (list format)
SANDBOXED_NET=$(nix-build --no-out-link "$SCRIPT_DIR/../fixtures/network-allowed.nix")
NET_SHELL="$SANDBOXED_NET/bin/sandboxed-bash-net"
run() { "$NET_SHELL" --norc --noprofile -c "$@" >/dev/null 2>&1; }

# Test 1: allowed domain works
expect_ok "allowed domain (httpbin.org) reachable" \
	'curl -sf --retry 3 --retry-delay 2 --retry-connrefused --max-time 10 -o /dev/null http://httpbin.org/get'

# Test 2: blocked domain fails
expect_fail "blocked domain (example.com) denied" \
	'curl -sf --max-time 10 -o /dev/null http://example.com'

# Test 3: unrestricted mode still works
SANDBOXED_UNRES=$(nix-build --no-out-link "$SCRIPT_DIR/../fixtures/network-unrestricted.nix")
UNRES_SHELL="$SANDBOXED_UNRES/bin/sandboxed-bash-unres"
run() { "$UNRES_SHELL" --norc --noprofile -c "$@" >/dev/null 2>&1; }

expect_ok "unrestricted mode can reach any domain" \
	'curl -s --retry 3 --retry-delay 2 --retry-connrefused --max-time 10 -o /dev/null http://example.com'

# Test 4: HTTPS with SSL verification works (proves CA injection)
run() { "$NET_SHELL" --norc --noprofile -c "$@" >/dev/null 2>&1; }

expect_ok "HTTPS with SSL verification works (MITM CA injection)" \
	'curl -sf --retry 3 --retry-delay 2 --retry-connrefused --max-time 10 -o /dev/null https://httpbin.org/get'

# Test 5: list format allows all methods (POST should succeed, proving "*" conversion)
expect_ok "list format allows POST (backward-compat wildcard)" \
	'curl -sf --retry 3 --retry-delay 2 --retry-connrefused --max-time 10 -X POST -o /dev/null https://httpbin.org/post'

# Test 6: empty allowlist blocks everything
SANDBOXED_BLOCK=$(nix-build --no-out-link "$SCRIPT_DIR/../fixtures/network-blocked.nix")
BLOCK_SHELL="$SANDBOXED_BLOCK/bin/sandboxed-bash-block"
run() { "$BLOCK_SHELL" --norc --noprofile -c "$@" >/dev/null 2>&1; }

expect_fail "empty allowlist blocks all domains" \
	'curl -sf --max-time 10 -o /dev/null http://example.com'

# --- MITM / method filtering tests (attrset format) ---

SANDBOXED_METHODS=$(nix-build --no-out-link "$SCRIPT_DIR/../fixtures/network-method-filtered.nix")
METHOD_SHELL="$SANDBOXED_METHODS/bin/sandboxed-bash-methods"
run() { "$METHOD_SHELL" --norc --noprofile -c "$@" >/dev/null 2>&1; }

# Test 8: Allowed method succeeds (GET to httpbin.org)
expect_ok "allowed method (GET httpbin.org) succeeds" \
	'curl -sf --retry 3 --retry-delay 2 --retry-connrefused --max-time 10 -o /dev/null https://httpbin.org/get'

# Test 9: Blocked method returns 403 (POST to httpbin.org)
expect_fail "blocked method (POST httpbin.org) denied" \
	'curl -sf --max-time 10 -X POST -o /dev/null https://httpbin.org/post'

# Test 10: Wildcard method domain allows POST (pie.dev)
expect_ok "wildcard method domain allows POST" \
	'curl -sf --retry 3 --retry-delay 2 --retry-connrefused --max-time 10 -X POST -d "test=1" -o /dev/null https://pie.dev/post'

# Test 11: URL > 8KB returns 414
LONG_PATH=$(printf 'x%.0s' $(seq 1 8200))
expect_fail "URL > 8KB returns 414" \
	"curl -sf --max-time 10 -o /dev/null \"https://httpbin.org/get?q=$LONG_PATH\""

# Test 12: WebSocket upgrade blocked
expect_fail "WebSocket upgrade blocked" \
	'curl -sf --max-time 10 -o /dev/null -H "Upgrade: websocket" -H "Connection: Upgrade" https://httpbin.org/get'

# Test 13: subdomain of allowed domain works (suffix matching)
expect_ok "subdomain of allowed domain works (www.httpbin.org)" \
	'curl -sf --retry 3 --retry-delay 2 --retry-connrefused --max-time 10 -o /dev/null https://www.httpbin.org/get'

# Test 14: non-subdomain with shared suffix is blocked (no false suffix match)
expect_fail "shared-suffix non-subdomain blocked (nothttpbin.org)" \
	'curl -sf --max-time 10 -o /dev/null https://nothttpbin.org'

# --- Direct-to-IP bypass tests (prove kernel-level enforcement) ---

run() { "$NET_SHELL" --norc --noprofile -c "$@" >/dev/null 2>&1; }

# Test 15: direct IP bypassing proxy is blocked
expect_fail "direct IP bypass blocked (curl --noproxy)" \
	'curl -sf --noproxy "*" --max-time 5 http://1.1.1.1'

# Test 16: raw TCP connection bypassing proxy is blocked
expect_fail "raw TCP bypass blocked (bash /dev/tcp)" \
	'exec 3<>/dev/tcp/1.1.1.1/80'

# Test 17: --connect-to direct IP for allowed domain blocked
expect_fail "direct IP for allowed domain blocked (--connect-to)" \
	'curl -sf --max-time 5 --connect-to ::1.1.1.1: http://httpbin.org/get'

# Test 18: host services on 127.0.0.1 other than the proxy are unreachable.
# Stands in for the real threat: a user running a local service (Postgres,
# Redis, a dev API) on 127.0.0.1. Without the proxy-port pin, a sandboxed
# agent could connect directly via --noproxy and bypass the proxy's filter.
# On Darwin this is enforced by the seatbelt rule being pinned to the proxy
# port. On Linux the sandbox's network namespace has its own 127.0.0.1, so
# the host's listener is already unreachable for unrelated reasons.
#
# We use nc as the listener (universally available) and bash /dev/tcp from
# inside the sandbox as the probe — no HTTP, just a raw TCP connect. If the
# sandbox can connect, the seatbelt let it through (FAIL). If it can't, the
# seatbelt blocked it (PASS). We pre-verify the listener is actually up so
# we never confuse a setup glitch for a sandbox denial.
#
# Hardcoded port (below the ephemeral range on macOS so the proxy can't
# land on it). If something else is already using it we abort loudly rather
# than silently false-passing.
HOST_SERVICE_PORT=18917
if nc -z 127.0.0.1 "$HOST_SERVICE_PORT" 2>/dev/null; then
	echo "FAIL: test setup — 127.0.0.1:$HOST_SERVICE_PORT already in use; cannot run host-service test" >&2
	exit 1
fi
( nc -l 127.0.0.1 "$HOST_SERVICE_PORT" >/dev/null 2>&1 ) &
_HOST_SERVICE_PID=$!
trap 'kill "$_HOST_SERVICE_PID" 2>/dev/null || true' EXIT
_ready=0
for _ in 1 2 3 4 5; do
	if nc -z 127.0.0.1 "$HOST_SERVICE_PORT" 2>/dev/null; then
		_ready=1
		break
	fi
	sleep 0.2
done
if [ "$_ready" -ne 1 ]; then
	echo "FAIL: test setup — nc listener never came up on 127.0.0.1:$HOST_SERVICE_PORT" >&2
	kill "$_HOST_SERVICE_PID" 2>/dev/null || true
	exit 1
fi
expect_fail "host service on non-proxy 127.0.0.1 port unreachable from sandbox" \
	"exec 3<>/dev/tcp/127.0.0.1/$HOST_SERVICE_PORT"
kill "$_HOST_SERVICE_PID" 2>/dev/null || true
trap - EXIT

print_results
exit_status
