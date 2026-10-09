#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

source "$SCRIPT_DIR/../lib.sh"

SANDBOXED=$(build_fixture basic-sandbox.nix)
SHELL_BIN="$SANDBOXED/bin/sandboxed-bash"

TESTDIR_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)/.tmp-test"
mkdir -p "$TESTDIR_ROOT"
TESTDIR=$(mktemp -d "$TESTDIR_ROOT/session-retention.XXXXXX")
FAKE_HOME=$(mktemp -d "$TESTDIR_ROOT/session-retention-home.XXXXXX")
mkdir -p "$FAKE_HOME/.test-state-dir"
touch "$FAKE_HOME/.test-state-file"
SESSIONS_ROOT="$TESTDIR/sessions"
trap 'rm -rf "$TESTDIR" "$FAKE_HOME"' EXIT
cd "$TESTDIR"

echo "=== Stub pid recorded (shared) ==="
echo

capture env HOME="$FAKE_HOME" AGENT_SANDBOX_SESSIONS_ROOT="$SESSIONS_ROOT" \
	"$SHELL_BIN" -c 'echo ok'
assert_exit_code "launch succeeds" 0

SESSION=$(find "$SESSIONS_ROOT" -mindepth 1 -maxdepth 1 -type d)
if [ -s "$SESSION/stub.pid" ]; then
	echo "PASS: the launch recorded its stub pid"
	PASS=$((PASS + 1))
else
	echo "FAIL: the launch recorded no stub pid"
	FAIL=$((FAIL + 1))
fi

print_results
exit_status
