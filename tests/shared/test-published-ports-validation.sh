#!/usr/bin/env bash
# publishedPorts accepts TCP port integers or { port; bindAddr; } — no
# null form, unlike allowedHostPorts.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

source "$SCRIPT_DIR/../lib.sh"

# Not build_fixture: the build is what this file asserts on, so it must run
# every time and its failure output is the subject rather than an error.
build_with_ports() {
	local ports="$1"
	nix-build --no-out-link --arg publishedPorts "$ports" "$SCRIPT_DIR/../fixtures/published-ports.nix" 2>&1
}

expect_ok_ports() {
	local desc="$1" ports="$2"
	local out
	if out=$(build_with_ports "$ports"); then
		echo "PASS: $desc"
		PASS=$((PASS + 1))
	else
		echo "FAIL: $desc (build failed)"
		printf '%s\n' "$out" | sed 's/^/    /'
		FAIL=$((FAIL + 1))
	fi
}

expect_invalid_ports() {
	local desc="$1" ports="$2" needle="$3"
	local out
	if out=$(build_with_ports "$ports"); then
		echo "FAIL: $desc (build succeeded; expected validation error)"
		FAIL=$((FAIL + 1))
	elif printf '%s' "$out" | grep -qF "$needle"; then
		echo "PASS: $desc"
		PASS=$((PASS + 1))
	else
		echo "FAIL: $desc (threw, but message missing: $needle)"
		printf '%s\n' "$out" | sed 's/^/    /'
		FAIL=$((FAIL + 1))
	fi
}

echo "=== publishedPorts validation ==="
echo

expect_ok_ports "integer port is accepted" "[ 3000 ]"
expect_ok_ports "attrset entry with bindAddr is accepted" '[ { port = 3000; bindAddr = "0.0.0.0"; } ]'
expect_ok_ports "attrset entry defaults bindAddr" "[ { port = 3000; } ]"
expect_ok_ports "duplicates are accepted" "[ 3000 3000 ]"
expect_invalid_ports "null is rejected (no allow-all form)" "null" "publishedPorts must be a list"
expect_invalid_ports "string port is rejected" '[ "3000" ]' "publishedPorts entries must be integers"
expect_invalid_ports "zero is rejected" "[ 0 ]" "publishedPorts entries must be integers"
expect_invalid_ports "port above range is rejected" "[ 65536 ]" "publishedPorts entries must be integers"
expect_invalid_ports "attrset without port is rejected" '[ { bindAddr = "127.0.0.1"; } ]' "publishedPorts entries must be integers"
expect_invalid_ports "hostname bindAddr is rejected" '[ { port = 3000; bindAddr = "localhost"; } ]' "publishedPorts entries must be integers"
expect_invalid_ports "out-of-range octet is rejected" '[ { port = 3000; bindAddr = "256.0.0.1"; } ]' "publishedPorts entries must be integers"

print_results
exit_status
