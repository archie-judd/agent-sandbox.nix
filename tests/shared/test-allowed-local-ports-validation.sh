#!/usr/bin/env bash
# allowedLocalPorts accepts TCP port integers and "*".
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

source "$SCRIPT_DIR/../lib.sh"

build_with_ports() {
	local ports="$1"
	nix-build --no-out-link --arg ports "$ports" "$SCRIPT_DIR/../fixtures/allowed-local-ports.nix" 2>&1
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

echo "=== allowedLocalPorts validation ==="
echo

expect_ok_ports "integer port is accepted" "[ 3000 ]"
expect_ok_ports "wildcard is accepted" '[ "*" ]'
expect_ok_ports "duplicates are accepted" "[ 3000 3000 ]"
expect_invalid_ports "string port is rejected" '[ "3000" ]' "allowedLocalPorts must only contain integers"
expect_invalid_ports "colon-delimited string is rejected" '[ "localhost:3000" ]' "allowedLocalPorts must only contain integers"
expect_invalid_ports "zero is rejected" "[ 0 ]" "allowedLocalPorts must only contain integers"
expect_invalid_ports "port above range is rejected" "[ 65536 ]" "allowedLocalPorts must only contain integers"
expect_invalid_ports "negative port is rejected" "[ (-1) ]" "allowedLocalPorts must only contain integers"

print_results
exit_status
