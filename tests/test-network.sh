#!/usr/bin/env bash
# Network restriction tests
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OS=$(uname)

source "$SCRIPT_DIR/lib.sh"

echo "=== Network restriction tests ($OS) ==="
echo

# Build a sandbox with restrictNetwork=true and one allowed domain
SANDBOXED_NET=$(nix-build --no-out-link "$SCRIPT_DIR/network-allowed.nix")
NET_SHELL="$SANDBOXED_NET/bin/sandboxed-bash-net"
run() { "$NET_SHELL" --norc --noprofile -c "$@" >/dev/null 2>&1; }

# Test 1: allowed domain works
expect_ok "allowed domain (httpbin.org) reachable" \
	'curl -sf --max-time 10 -o /dev/null http://httpbin.org/get'

# Test 2: blocked domain fails
expect_fail "blocked domain (example.com) denied" \
	'curl -sf --max-time 10 -o /dev/null http://example.com'

# Test 3: unrestricted mode still works
SANDBOXED_UNRES=$(nix-build --no-out-link "$SCRIPT_DIR/network-unrestricted.nix")
UNRES_SHELL="$SANDBOXED_UNRES/bin/sandboxed-bash-unres"
run() { "$UNRES_SHELL" --norc --noprofile -c "$@" >/dev/null 2>&1; }

expect_ok "unrestricted mode can reach any domain" \
	'curl -s --max-time 10 -o /dev/null http://example.com'

# Test 4: empty allowlist blocks everything
SANDBOXED_BLOCK=$(nix-build --no-out-link "$SCRIPT_DIR/network-blocked.nix")
BLOCK_SHELL="$SANDBOXED_BLOCK/bin/sandboxed-bash-block"
run() { "$BLOCK_SHELL" --norc --noprofile -c "$@" >/dev/null 2>&1; }

expect_fail "empty allowlist blocks all domains" \
	'curl -sf --max-time 10 -o /dev/null http://example.com'

# Test 5 (Linux only): DNS resolution is blocked when restrictNetwork=true
if [ "$OS" = "Linux" ]; then
	expect_fail "DNS resolution blocked when restrictNetwork=true" \
		'getent hosts example.com'
fi

print_results
exit_status
