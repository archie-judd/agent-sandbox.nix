#!/usr/bin/env bash
# allowedHostPorts accepts null or TCP port integers.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

source "$SCRIPT_DIR/../lib.sh"

# Not build_fixture: the build is what this file asserts on, so it must run
# every time and its failure output is the subject rather than an error.
build_with_ports() {
	local ports="$1"
	nix-build --no-out-link --arg ports "$ports" "$SCRIPT_DIR/../fixtures/allowed-host-ports.nix" 2>&1
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

echo "=== allowedHostPorts validation ==="
echo

expect_ok_ports "integer port is accepted" "[ 3000 ]"
expect_ok_ports "null allows all ports" "null"
expect_ok_ports "duplicates are accepted" "[ 3000 3000 ]"
expect_invalid_ports "string port is rejected" '[ "3000" ]' "allowedHostPorts must only contain integers"
expect_invalid_ports "colon-delimited string is rejected" '[ "localhost:3000" ]' "allowedHostPorts must only contain integers"
expect_invalid_ports "zero is rejected" "[ 0 ]" "allowedHostPorts must only contain integers"
expect_invalid_ports "port above range is rejected" "[ 65536 ]" "allowedHostPorts must only contain integers"
expect_invalid_ports "negative port is rejected" "[ (-1) ]" "allowedHostPorts must only contain integers"

print_results
exit_status
