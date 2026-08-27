#!/usr/bin/env bash
# Test: every launch records itself in launch.log, and records nothing secret.
#
# The session directory is only useful if it says what happened, and it has to
# say so on the paths where something went wrong: a refused launch writes its
# reasons, and a launch that started writes the status the sandbox exited with.
# Logging is best effort and must never gate a launch, which is the opposite of
# the convention everywhere else in the launcher.
#
# The one thing that must never appear is a declared env value. The spec carries
# keys alone and the values are resolved by the stub, so the keys are all the
# launcher could write even if it tried; this asserts that stays true, because
# it is what makes a session directory safe to attach to an issue.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

source "$SCRIPT_DIR/../lib.sh"

SANDBOXED=$(build_fixture basic-sandbox.nix)
SHELL_BIN="$SANDBOXED/bin/sandboxed-bash"

TESTDIR_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)/.tmp-test"
mkdir -p "$TESTDIR_ROOT"
TESTDIR=$(mktemp -d "$TESTDIR_ROOT/launch-log.XXXXXX")

# Siblings of the launch directory, as in test-session-retention.sh: launching
# from above $HOME is refused outright, which would mask what these are testing.
FAKE_HOME=$(mktemp -d "$TESTDIR_ROOT/launch-log-home.XXXXXX")
mkdir -p "$FAKE_HOME/.test-state-dir"
touch "$FAKE_HOME/.test-state-file"
# The same home without the declared paths, for the refusal case.
EMPTY_HOME=$(mktemp -d "$TESTDIR_ROOT/launch-log-empty-home.XXXXXX")

# Restored before removal: one case makes a directory unwritable on purpose.
cleanup() {
	chmod -R u+w "$TESTDIR" 2>/dev/null || true
	rm -rf "$TESTDIR" "$FAKE_HOME" "$EMPTY_HOME"
}
trap cleanup EXIT
cd "$TESTDIR"

# Each case gets a root of its own, so "the session directory" is unambiguous
# without having to sort by name.
SESSIONS_ROOT=""
new_sessions_root() {
	SESSIONS_ROOT="$TESTDIR/sessions-$1"
	mkdir -p "$SESSIONS_ROOT"
}

launch() {
	capture env HOME="$FAKE_HOME" AGENT_SANDBOX_SESSIONS_ROOT="$SESSIONS_ROOT" \
		"$SHELL_BIN" "$@"
}

log_path() {
	find "$SESSIONS_ROOT" -mindepth 2 -maxdepth 2 -name launch.log
}

assert_log_contains() {
	local desc="$1" needle="$2" log
	log=$(log_path)
	if [ -n "$log" ] && grep -qF "$needle" "$log"; then
		echo "PASS: $desc"
		PASS=$((PASS + 1))
	else
		echo "FAIL: $desc (launch.log missing: $needle)"
		[ -n "$log" ] && sed 's/^/    /' "$log"
		FAIL=$((FAIL + 1))
	fi
}

assert_log_not_contains() {
	local desc="$1" needle="$2" log
	log=$(log_path)
	if [ -n "$log" ] && grep -qF "$needle" "$log"; then
		echo "FAIL: $desc (launch.log unexpectedly contains: $needle)"
		sed 's/^/    /' "$log"
		FAIL=$((FAIL + 1))
	else
		echo "PASS: $desc"
		PASS=$((PASS + 1))
	fi
}

echo "=== Launch log (shared) ==="
echo

# --- 1. A successful launch records what was asked for and what was decided ---
new_sessions_root ok
launch -c 'echo ok'
assert_exit_code "launch succeeds" 0
assert_output_equals "command runs in the sandbox" "ok"

assert_log_contains "the request section names the wrapper" \
	"sandboxed-bash launch requested"
assert_log_contains "the request section lists the declared arguments" "rwDirs:"
# Against version.txt rather than a literal, so a release bump does not have to
# be made here too.
assert_log_contains "the request section records the version" \
	"version:           $(cat "$SCRIPT_DIR/../../version.txt")"
assert_log_contains "the outcome section is written once the launch is prepared" \
	"launch prepared"
assert_log_contains "the outcome section records what a declared path expanded to" \
	"rwDir  \$HOME/.test-state-dir -> $FAKE_HOME/.test-state-dir"

# The keys are in the spec; the values are shell expressions the stub resolves
# and never enter Python. Both halves are asserted, since the first passing
# alone would be satisfied by logging nothing at all.
assert_log_contains "declared env keys are recorded" "TEST_VAR"
assert_log_not_contains "declared env values are not recorded" "test-value"

# --- 2. The status the sandbox exited with is recorded by cleanup ---
assert_log_contains "a zero exit status is recorded" "sandbox exited with status 0"

new_sessions_root exit-status
launch -c 'exit 3'
assert_exit_code "the sandbox's exit status reaches the caller" 3
assert_log_contains "a non-zero exit status is recorded" \
	"sandbox exited with status 3"

# --- 3. A refused launch records why, and says where it recorded it ---
new_sessions_root refused
capture env HOME="$EMPTY_HOME" AGENT_SANDBOX_SESSIONS_ROOT="$SESSIONS_ROOT" \
	"$SHELL_BIN" -c 'echo should not run'
assert_exit_code "a missing declared path refuses the launch" 1
assert_stderr_contains "the refusal names the session directory" \
	"this launch was recorded in $SESSIONS_ROOT/"
assert_log_contains "the refusal section is written" "launch refused"
assert_log_contains "the refusal reason is recorded" \
	"declared as rwDir but does not exist"

# --- 4. A declared rwDir above the sessions root warns ---
# It would let the agent rewrite the configuration and logs of every session,
# including the one it is running in.
SESSIONS_ROOT="$FAKE_HOME/.test-state-dir/sessions"
mkdir -p "$SESSIONS_ROOT"
launch -c 'true'
assert_exit_code "a launch whose records sit inside an rwDir still starts" 0
assert_stderr_contains "covering the sessions root warns on the terminal" \
	"$FAKE_HOME/.test-state-dir is declared read-write and contains this sandbox's own session records"
assert_log_contains "the warning is recorded as well as printed" \
	"is declared read-write and contains this sandbox's own session records"
rm -rf "$SESSIONS_ROOT"

# --- 5. An unwritable sessions root fails with a reason, not a traceback ---
# The directory holds the computed argv and profile, so a launch cannot be
# assembled without it. Logging is what stays best effort, not this.
LOCKED="$TESTDIR/locked"
mkdir -p "$LOCKED"
chmod 500 "$LOCKED"
SESSIONS_ROOT="$LOCKED/sessions"
launch -c 'echo should not run'
assert_exit_code "an unwritable sessions root fails the launch" 1
assert_stderr_contains "the failure explains itself" \
	"could not create the session directory"
assert_stderr_not_contains "the failure is not a traceback" "Traceback"
chmod 700 "$LOCKED"

print_results
exit_status
