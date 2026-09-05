#!/usr/bin/env bash
# allowedHostPorts is emitted as host-local TCP port rules in the Darwin
# Seatbelt profile.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

source "$SCRIPT_DIR/../lib.sh"

# The profile is no longer a build artifact: it is computed per launch and
# written into the session directory. `prepare` writes it before the sandbox
# runs, so it exists even when the launch itself goes nowhere.
SESSIONS=$(mktemp -d)
trap 'rm -rf "$SESSIONS"' EXIT

sandbox_profile_for_wrapper() {
	local wrapper="$1/bin/sandboxed-bash-allowed-host-ports"
	local run
	local profile
	run=$(mktemp -d "$SESSIONS/run.XXXXXX")
	AGENT_SANDBOX_SESSIONS_ROOT="$run" "$wrapper" -c true >/dev/null 2>&1 || true
	profile=$(find "$run" -name seatbelt.sb | head -n 1)
	# find succeeds with no output when nothing matches, so the caller's
	# "profile not found" branch needs this to fail explicitly.
	[ -n "$profile" ] || return 1
	printf '%s\n' "$profile"
}

expect_rule_count() {
	local desc="$1" ports="$2" rule="$3" count="$4"
	local build_log out profile actual
	build_log=$(mktemp)
	if ! out=$(build_fixture allowed-host-ports.nix --arg ports "$ports" 2>"$build_log"); then
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

echo "=== allowedHostPorts Seatbelt rules (Darwin) ==="
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
