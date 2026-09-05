#!/usr/bin/env bash
# Unit tests for the namespace nft ruleset (no sandbox launch). Pins the
# per-port reply accepts for inbound forwards (rationale in get_nft_rules).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$SCRIPT_DIR/../lib.sh"

echo "=== nftables ruleset unit tests (Linux) ==="
echo

HOST_PYTHON3=$(build_host_pkg python3Minimal)/bin/python3

# print_rules <restricted|open> [inbound_port...]
print_rules() {
	local mode="$1"
	shift
	PYTHONPATH="$REPO_ROOT" "$HOST_PYTHON3" - "$mode" "$@" <<-'EOF'
		import sys
		from launcher.lib.launch_config.linux.nftables import get_nft_rules
		proxy_port = 12345 if sys.argv[1] == "restricted" else None
		inbound = [int(port) for port in sys.argv[2:]]
		for rule in get_nft_rules("10.0.2.2", proxy_port, [5432], inbound):
		    print(rule)
	EOF
}

capture print_rules restricted 18944 18945
assert_exit_code "ruleset builds with inbound forwards (restricted)" 0
assert_output_contains "granted inbound port gets a reply accept" \
	"add rule ip sandbox_filter output tcp sport 18944 ct state established accept"
assert_output_contains "every granted inbound port gets its own reply accept" \
	"add rule ip sandbox_filter output tcp sport 18945 ct state established accept"

capture print_rules restricted
assert_exit_code "ruleset builds without inbound forwards (restricted)" 0
assert_output_not_contains "no reply accepts without inbound forwards" \
	"ct state established"

# Open mode's OUTPUT policy is accept, so replies need no dedicated rule;
# pin that the inbound ports add nothing there.
capture print_rules open 18944
assert_exit_code "ruleset builds with inbound forwards (open)" 0
assert_output_not_contains "open mode emits no reply accepts" \
	"ct state established"

print_results
exit_status
