#!/usr/bin/env bash
# Test: the sessions root keeps a bounded number of session directories, and
# pruning never touches one whose sandbox is still running.
#
# Session directories survive their own run on purpose, so without a prune they
# accumulate forever, one per launch. The liveness check is the interesting half:
# a running session's directory is still being read, so deleting it takes the CA
# bundle out from under the agent on macOS and strands the proxy and the mount
# points cleanup reads from disk on both platforms.
#
# The fake directories below are named the way create_session_dir names them,
# since that shape is what the prune matches on.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

source "$SCRIPT_DIR/../lib.sh"

RETENTION=25

SANDBOXED=$(build_fixture basic-sandbox.nix)
SHELL_BIN="$SANDBOXED/bin/sandboxed-bash"

TESTDIR_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)/.tmp-test"
mkdir -p "$TESTDIR_ROOT"
TESTDIR=$(mktemp -d "$TESTDIR_ROOT/session-retention.XXXXXX")

# A sibling of the launch directory, as in test-bind-must-exist.sh: launching
# from above $HOME is refused outright, which would mask what this is testing.
FAKE_HOME=$(mktemp -d "$TESTDIR_ROOT/session-retention-home.XXXXXX")
mkdir -p "$FAKE_HOME/.test-state-dir"
touch "$FAKE_HOME/.test-state-file"

SESSIONS_ROOT="$TESTDIR/sessions"

LIVE_PID=""
cleanup() {
	if [ -n "$LIVE_PID" ]; then
		kill "$LIVE_PID" 2>/dev/null || true
	fi
	rm -rf "$TESTDIR" "$FAKE_HOME"
}
trap cleanup EXIT
cd "$TESTDIR"

# fake_session <index> — one directory named as a session from 2020, so every
# one of them sorts older than the launch under test.
fake_session() {
	printf '%s/20200101-%06d-1234-sandboxed-bash' "$SESSIONS_ROOT" "$1"
}

populate() {
	rm -rf "$SESSIONS_ROOT"
	local index
	for ((index = 1; index <= 30; index++)); do
		mkdir -p "$(fake_session "$index")"
	done
}

launch() {
	capture env HOME="$FAKE_HOME" AGENT_SANDBOX_LOG_DIR="$SESSIONS_ROOT" \
		"$SHELL_BIN" -c 'echo ok'
}

count_sessions() {
	find "$SESSIONS_ROOT" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' '
}

echo "=== Session directory retention (shared) ==="
echo

# --- 1. Finished sessions beyond the limit are removed ---
populate
launch
assert_exit_code "prune: launch succeeds" 0
assert_output_equals "prune: command runs in sandbox" "ok"

# 30 existed, the newest 25 are kept, and this launch adds its own.
if [ "$(count_sessions)" -eq $((RETENTION + 1)) ]; then
	echo "PASS: prune: $((RETENTION + 1)) directories remain"
	PASS=$((PASS + 1))
else
	echo "FAIL: prune: $(count_sessions) directories remain, expected $((RETENTION + 1))"
	FAIL=$((FAIL + 1))
fi

for index in 1 5; do
	if [ -d "$(fake_session "$index")" ]; then
		echo "FAIL: prune: session $index should have been removed"
		FAIL=$((FAIL + 1))
	else
		echo "PASS: prune: session $index removed"
		PASS=$((PASS + 1))
	fi
done

if [ -d "$(fake_session 6)" ]; then
	echo "PASS: prune: session 6 kept"
	PASS=$((PASS + 1))
else
	echo "FAIL: prune: session 6 should have been kept"
	FAIL=$((FAIL + 1))
fi

# The prune has nothing to work from unless the stub records its pid. Every
# fake session is dated 2020, so the launch's own is the only other entry.
NEW_SESSION=$(find "$SESSIONS_ROOT" -mindepth 1 -maxdepth 1 -type d -not -name '20200101-*')
if [ -s "$NEW_SESSION/stub.pid" ]; then
	echo "PASS: prune: the launch recorded its stub pid"
	PASS=$((PASS + 1))
else
	echo "FAIL: prune: the launch recorded no stub pid"
	FAIL=$((FAIL + 1))
fi

# --- 2. A running session survives, however old it is ---
populate
sleep 300 &
LIVE_PID=$!
echo "$LIVE_PID" >"$(fake_session 1)/stub.pid"
# Dead, to prove the check reads the pid rather than the file's presence. Waited
# on so it is reaped, not left as a zombie, which is still a live pid.
sleep 0 &
DEAD_PID=$!
wait "$DEAD_PID"
echo "$DEAD_PID" >"$(fake_session 2)/stub.pid"

launch
assert_exit_code "liveness: launch succeeds" 0

if [ -d "$(fake_session 1)" ]; then
	echo "PASS: liveness: the running session survives"
	PASS=$((PASS + 1))
else
	echo "FAIL: liveness: the running session was pruned"
	FAIL=$((FAIL + 1))
fi

if [ -d "$(fake_session 2)" ]; then
	echo "FAIL: liveness: a session with a dead pid should have been removed"
	FAIL=$((FAIL + 1))
else
	echo "PASS: liveness: a session with a dead pid is removed"
	PASS=$((PASS + 1))
fi

print_results
exit_status
