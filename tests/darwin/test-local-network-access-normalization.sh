#!/usr/bin/env bash
# localNetworkAccess loopback aliases must be emitted as sandbox-exec-compatible
# localhost targets in the Darwin Seatbelt profile.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

source "$SCRIPT_DIR/../lib.sh"

sandbox_profile_for_wrapper() {
	local wrapper="$1/bin/sandboxed-bash-local-access"
	grep -Eo '/nix/store/[^" ]+-sandboxed-bash-local-access-sandbox\.sb' "$wrapper" | head -n 1
}

expect_normalized_target() {
	local desc="$1" target="$2" expected="$3" unexpected="$4"
	local out profile
	if ! out=$(nix-build --no-out-link --argstr target "$target" "$SCRIPT_DIR/../fixtures/network-local-access-darwin.nix" 2>&1); then
		echo "FAIL: $desc (build failed)"
		printf '%s\n' "$out" | sed 's/^/    /'
		FAIL=$((FAIL + 1))
	elif ! profile=$(sandbox_profile_for_wrapper "$out"); then
		echo "FAIL: $desc (sandbox profile not found)"
		FAIL=$((FAIL + 1))
	elif ! grep -qF "$expected" "$profile"; then
		echo "FAIL: $desc (missing expected rule: $expected)"
		sed 's/^/    /' "$profile"
		FAIL=$((FAIL + 1))
	elif [ -n "$unexpected" ] && grep -qF "$unexpected" "$profile"; then
		echo "FAIL: $desc (found unnormalized rule: $unexpected)"
		sed 's/^/    /' "$profile"
		FAIL=$((FAIL + 1))
	else
		echo "PASS: $desc"
		PASS=$((PASS + 1))
	fi
}

echo "=== localNetworkAccess Seatbelt normalization (Darwin) ==="
echo

expect_normalized_target "IPv4 loopback alias is emitted as sandbox-exec-compatible localhost" \
	"127.0.0.1:3000" \
	'(allow network-outbound (remote ip "localhost:3000"))' \
	'(allow network-outbound (remote ip "127.0.0.1:3000"))'

print_results
exit_status
