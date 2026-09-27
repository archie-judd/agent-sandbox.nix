#!/usr/bin/env bash
# Test: workspaceDir decides what the sandbox grants and where the agent
# starts, and every prepared launch reports it. The workspace is the widest
# grant in the profile, so the user has to be able to read it off the terminal
# without opening launch.log.
#
# The physical-path case is the baseline: $PWD keeps a symlink the kernel does
# not, and the seatbelt and bubblewrap rules are written against the resolved
# path. What is reported has to be what is granted.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

source "$SCRIPT_DIR/../lib.sh"

SANDBOXED=$(build_fixture basic-sandbox.nix)
SHELL_BIN="$SANDBOXED/bin/sandboxed-bash"

PINNED=$(build_fixture workspace-pinned.nix)
PINNED_BIN="$PINNED/bin/sandboxed-bash-workspace-pinned"

TESTDIR_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)/.tmp-test"
mkdir -p "$TESTDIR_ROOT"
TESTDIR=$(mktemp -d "$TESTDIR_ROOT/workspace-dir.XXXXXX")

# Siblings of the launch directory, as in test-launch-log.sh: launching from
# above $HOME is refused outright, which would mask what these are testing.
FAKE_HOME=$(mktemp -d "$TESTDIR_ROOT/workspace-dir-home.XXXXXX")
mkdir -p "$FAKE_HOME/.test-state-dir"
touch "$FAKE_HOME/.test-state-file"
# The same home without the declared paths, for the refusal case.
EMPTY_HOME=$(mktemp -d "$TESTDIR_ROOT/workspace-dir-empty-home.XXXXXX")
# workspace-pinned.nix pins "$HOME/pinned", so the home is how the pin moves.
PIN_HOME=$(mktemp -d "$TESTDIR_ROOT/workspace-dir-pin-home.XXXXXX")

trap 'rm -rf "$TESTDIR" "$FAKE_HOME" "$EMPTY_HOME" "$PIN_HOME"' EXIT

launch() {
	capture env HOME="$1" "$SHELL_BIN" -c 'true'
}

launch_pinned() {
	capture env HOME="$PIN_HOME" AGENT_SANDBOX_SESSIONS_ROOT="$SESSIONS_ROOT" \
		"$PINNED_BIN" -c "$1"
}

# A launch that dies before the agent runs says why on stderr, and the exit
# code alone does not. Dump it, or a broken sandbox reports only "exit 1".
assert_launch_succeeded() {
	local desc="$1"
	if [ "$CAP_STATUS" -eq 0 ]; then
		echo "PASS: $desc"
		PASS=$((PASS + 1))
	else
		echo "FAIL: $desc (exit $CAP_STATUS)"
		printf '%s\n' "$CAP_ERR" | sed 's/^/    /'
		FAIL=$((FAIL + 1))
	fi
}

assert_pinned_log_contains() {
	local desc="$1" needle="$2" log
	log=$(find "$SESSIONS_ROOT" -mindepth 2 -maxdepth 2 -name launch.log)
	if [ -n "$log" ] && grep -qF "$needle" "$log"; then
		echo "PASS: $desc"
		PASS=$((PASS + 1))
	else
		echo "FAIL: $desc (launch.log missing: $needle)"
		[ -n "$log" ] && sed 's/^/    /' "$log"
		FAIL=$((FAIL + 1))
	fi
}

echo "=== Workspace directory (shared) ==="
echo

# --- 1. The granted workspace is reported, on stderr ---
cd "$TESTDIR"
launch "$FAKE_HOME"
assert_launch_succeeded "launch succeeds"
assert_stderr_contains "the launch reports the workspace it granted" \
	"workspace: $TESTDIR"
# stdout belongs to prepare.py's caller: stub.sh reads it as the session
# directory, so a line printed there would break the launch, not clutter it.
assert_output_not_contains "the workspace line does not go to stdout" "workspace:"

# --- 2. A symlinked launch directory reports the path that was granted ---
# bash keeps the link in $PWD; getcwd() and therefore the sandbox rules do not.
mkdir -p "$TESTDIR/real"
ln -s "$TESTDIR/real" "$TESTDIR/link"
cd "$TESTDIR/link"
launch "$FAKE_HOME"
assert_launch_succeeded "launch through a symlinked directory succeeds"
assert_stderr_contains "the workspace is reported physical" \
	"workspace: $TESTDIR/real"
assert_stderr_not_contains "the workspace is not reported as the symlink" \
	"workspace: $TESTDIR/link"

# --- 3. A refused launch grants nothing, and reports nothing ---
cd "$TESTDIR"
launch "$EMPTY_HOME"
assert_exit_code "a missing declared path refuses the launch" 1
assert_stderr_not_contains "a refused launch reports no workspace" "workspace:"

# --- 4. A pinned workspace is granted instead of the launch directory ---
# The whole point of pinning: where the wrapper was typed stops deciding what
# the agent can reach.
mkdir -p "$PIN_HOME/pinned"
echo pinned-content >"$PIN_HOME/pinned/inside.txt"
echo launch-secret >"$TESTDIR/outside.txt"
SESSIONS_ROOT="$TESTDIR/sessions-pinned"
mkdir -p "$SESSIONS_ROOT"
cd "$TESTDIR"

# Builtins only, never `cat`: capture sends stdout to a $(mktemp) file under
# the host's $TMPDIR, and the sandbox denies /private/var/folders on purpose
# (see seatbelt.temp_dirs). The first process inherits fd 1 from outside and
# may write to it; an exec'd child is re-checked against the policy and gets
# EPERM. So an exec'd binary writing to stdout fails here whatever the
# workspace is, which would make a leak assertion pass for the wrong reason.
launch_pinned 'read -r line < inside.txt && echo "$line"'
assert_launch_succeeded "a pinned launch succeeds from an unrelated directory"
assert_stderr_contains "the pin is reported as the workspace" \
	"workspace: $PIN_HOME/pinned"
# Relative, so this asserts the process actually started in the pin rather
# than merely being granted it.
assert_output_equals "the agent starts in the pinned workspace" "pinned-content"
# The launch directory is outside the sandbox when it is not the workspace.
# Carrying it in as the starting directory makes the first process warn twice
# about a directory it cannot stat, on every single launch.
assert_stderr_not_contains "no getcwd warnings from the unreachable launch directory" \
	"getcwd"

assert_pinned_log_contains "the log records where the wrapper was invoked" \
	"launch directory:  $TESTDIR"
assert_pinned_log_contains "the log records what was granted" \
	"workspace:         $PIN_HOME/pinned"

# The failure mode that matters: pinning elsewhere must not leave the launch
# directory reachable, or the pin has bought nothing. The redirect is what is
# under test — bash fails it before `read` runs when the file is denied.
launch_pinned "read -r line < $TESTDIR/outside.txt && echo \"\$line\""
assert_exit_code "the launch directory is not readable from inside" 1
assert_output_not_contains "the launch directory's contents do not leak" \
	"launch-secret"
# The same read against the pin, to prove the assertion above fails on the
# denial and not on the way it reads the file.
launch_pinned 'read -r line < inside.txt && echo "$line"'
assert_output_equals "the same read succeeds inside the workspace" \
	"pinned-content"

# --- 5. A pin that does not exist refuses, rather than granting nothing ---
rm -rf "$PIN_HOME/pinned"
SESSIONS_ROOT="$TESTDIR/sessions-missing-pin"
mkdir -p "$SESSIONS_ROOT"
launch_pinned 'echo should not run'
assert_exit_code "a missing pinned workspace refuses the launch" 1
assert_stderr_contains "the refusal names the pin" \
	"$PIN_HOME/pinned: declared as workspaceDir but does not exist"

print_results
exit_status
