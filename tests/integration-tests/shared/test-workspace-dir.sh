#!/usr/bin/env bash
# Test: every prepared launch reports the workspace it granted on stderr.
# The workspace is the widest grant in the profile, so the user has to be able
# to read it off the terminal without opening launch.log.
#
# The physical-path case is the baseline: $PWD keeps a symlink the kernel does
# not, and the seatbelt and bubblewrap rules are written against the resolved
# path. What is reported has to be what is granted.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

source "$SCRIPT_DIR/../lib.sh"

SANDBOXED=$(build_fixture basic-sandbox.nix)
SHELL_BIN="$SANDBOXED/bin/sandboxed-bash"

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

trap 'rm -rf "$TESTDIR" "$FAKE_HOME" "$EMPTY_HOME"' EXIT

launch() {
	capture env HOME="$1" "$SHELL_BIN" -c 'true'
}

echo "=== Workspace directory (shared) ==="
echo

# --- 1. The granted workspace is reported, on stderr ---
cd "$TESTDIR"
launch "$FAKE_HOME"
assert_exit_code "launch succeeds" 0
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
assert_exit_code "launch through a symlinked directory succeeds" 0
assert_stderr_contains "the workspace is reported physical" \
	"workspace: $TESTDIR/real"
assert_stderr_not_contains "the workspace is not reported as the symlink" \
	"workspace: $TESTDIR/link"

# --- 3. A refused launch grants nothing, and reports nothing ---
cd "$TESTDIR"
launch "$EMPTY_HOME"
assert_exit_code "a missing declared path refuses the launch" 1
assert_stderr_not_contains "a refused launch reports no workspace" "workspace:"

print_results
exit_status
