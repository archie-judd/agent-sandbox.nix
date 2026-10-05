#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

source "$SCRIPT_DIR/../lib.sh"

echo "=== allowHeadlessBrowsers requires allowUnixSockets (Linux) ==="
echo

DENIED=$(build_fixture headless-browser.nix --argstr browser chromium --arg allowUnixSockets false)
capture "$DENIED/bin/sandboxed-bash-headless-browser" --norc --noprofile -c 'echo unreachable'
assert_exit_code "allowUnixSockets = false: launch fails" 1
assert_stderr_contains "allowUnixSockets = false: refusal names both flags" \
	"allowHeadlessBrowsers needs allowUnixSockets = true"
assert_output_not_contains "allowUnixSockets = false: nothing runs inside" "unreachable"

ALLOWED=$(build_fixture headless-browser.nix --argstr browser chromium --arg allowUnixSockets true)
capture "$ALLOWED/bin/sandboxed-bash-headless-browser" --norc --noprofile -c 'echo reachable'
assert_exit_code "allowUnixSockets = true: launch succeeds" 0
assert_output_contains "allowUnixSockets = true: command runs inside" "reachable"

print_results
exit_status
