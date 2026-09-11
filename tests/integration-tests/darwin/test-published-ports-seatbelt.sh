#!/usr/bin/env bash
# publishedPorts is emitted as port-pinned bind + inbound rules in the
# Darwin Seatbelt profile: loopback bindAddr stays localhost-scoped, any other
# bindAddr becomes the wildcard.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

source "$SCRIPT_DIR/../lib.sh"

# The profile is computed per launch and written into the session directory.
# `prepare` writes it before the sandbox runs, so it exists even when the
# launch itself goes nowhere.
SESSIONS=$(mktemp -d)
trap 'rm -rf "$SESSIONS"' EXIT

sandbox_profile_for_wrapper() {
	local wrapper="$1/bin/sandboxed-bash-published-ports"
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
	if ! out=$(build_fixture published-ports.nix --arg publishedPorts "$ports" 2>"$build_log"); then
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

echo "=== publishedPorts Seatbelt rules (Darwin) ==="
echo

expect_rule_count "integer entry emits one localhost inbound rule" \
	"[ 3000 ]" \
	'(allow network-inbound (local ip "localhost:3000"))' \
	1

expect_rule_count "loopback bindAddr emits one localhost bind rule" \
	'[ { port = 3000; bindAddr = "127.0.0.1"; } ]' \
	'(allow network-bind (local ip "localhost:3000"))' \
	1

expect_rule_count "wider bindAddr emits one wildcard inbound rule" \
	'[ { port = 3000; bindAddr = "0.0.0.0"; } ]' \
	'(allow network-inbound (local ip "*:3000"))' \
	1

expect_rule_count "duplicate entries emit one rule" \
	"[ 3000 3000 ]" \
	'(allow network-inbound (local ip "localhost:3000"))' \
	1

expect_rule_count "empty list emits no inbound rules" \
	"[ ]" \
	"(allow network-inbound (local ip " \
	0

print_results
exit_status
