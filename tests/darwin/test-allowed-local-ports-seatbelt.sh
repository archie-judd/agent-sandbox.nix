#!/usr/bin/env bash
# allowedLocalPorts is emitted as host-local TCP port rules in the Darwin
# Seatbelt profile.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

source "$SCRIPT_DIR/../lib.sh"

sandbox_profile_for_wrapper() {
	local wrapper="$1/bin/sandboxed-bash-allowed-local-ports"
	grep -Eo '/nix/store/[^" ]+-sandboxed-bash-allowed-local-ports-sandbox\.sb' "$wrapper" | head -n 1
}

expect_rule_count() {
	local desc="$1" ports="$2" rule="$3" count="$4"
	local build_log out profile actual
	build_log=$(mktemp)
	if ! out=$(nix-build --no-out-link --arg ports "$ports" "$SCRIPT_DIR/../fixtures/allowed-local-ports.nix" 2>"$build_log"); then
		echo "FAIL: $desc (build failed)"
		sed 's/^/    /' "$build_log"
		rm -f "$build_log"
		FAIL=$((FAIL + 1))
	elif ! profile=$(sandbox_profile_for_wrapper "$out"); then
		echo "FAIL: $desc (sandbox profile not found)"
		rm -f "$build_log"
		FAIL=$((FAIL + 1))
	else
		rm -f "$build_log"
		actual=$(grep -cF "$rule" "$profile" || true)
		if [ "$actual" -eq "$count" ]; then
			echo "PASS: $desc"
			PASS=$((PASS + 1))
		else
			echo "FAIL: $desc (expected $count, found $actual: $rule)"
			sed 's/^/    /' "$profile"
			FAIL=$((FAIL + 1))
		fi
	fi
}

echo "=== allowedLocalPorts Seatbelt rules (Darwin) ==="
echo

expect_rule_count "integer port emits one localhost rule" \
	"[ 3000 ]" \
	'(allow network-outbound (remote ip "localhost:3000"))' \
	1

expect_rule_count "duplicate ports emit one localhost rule" \
	"[ 3000 3000 ]" \
	'(allow network-outbound (remote ip "localhost:3000"))' \
	1

expect_rule_count "null does not emit specific port rules" \
	"null" \
	'(allow network-outbound (remote ip "localhost:3000"))' \
	0

expect_rule_count "null emits one all-ports rule" \
	"null" \
	'(allow network-outbound (remote ip "localhost:*"))' \
	1

print_results
exit_status
