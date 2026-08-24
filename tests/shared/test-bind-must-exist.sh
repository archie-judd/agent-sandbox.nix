#!/usr/bin/env bash
# Test: declared rwDirs / rwFiles must exist on the host before the sandbox
# launches.
#
# The wrapper used to silently `mkdir -p` declared rwDirs and `touch` declared
# rwFiles at launch. That hid typos like `rwDirs = [ "$HOME/.cluade" ]` — the
# agent would populate the misspelled directory and the real ~/.claude config
# would diverge silently. After this change the wrapper checks each declared
# path with `[ -e ]` (so broken symlinks also fail), accumulates every missing
# path, prints one error line per miss, and exits 1 before any sandboxing runs.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

source "$SCRIPT_DIR/../lib.sh"

SANDBOXED=$(build_fixture bind-must-exist.nix)
SHELL_BIN="$SANDBOXED/bin/sandboxed-bash-bind-must-exist"

TESTDIR_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)/.tmp-test"
mkdir -p "$TESTDIR_ROOT"
TESTDIR=$(mktemp -d "$TESTDIR_ROOT/bind-must-exist.XXXXXX")

# HOME is overridden per-invocation so the existence of the declared
# rwDir/rwFile is entirely controlled by this test, independent of the
# host's real $HOME contents. It is a sibling of the launch directory, not a
# child of it: launching from above $HOME is refused outright (see
# test-home-cwd-confirm.sh), which would mask what these cases are testing.
FAKE_HOME=$(mktemp -d "$TESTDIR_ROOT/bind-must-exist-home.XXXXXX")
trap 'rm -rf "$TESTDIR" "$FAKE_HOME"' EXIT
cd "$TESTDIR"

DIR_PATH="$FAKE_HOME/.agent-sandbox-bind-must-exist/dir"
FILE_PATH="$FAKE_HOME/.agent-sandbox-bind-must-exist/file"

echo "=== Bind paths must exist (shared) ==="
echo

# --- 1. Both missing: both errors reported in one launch ---
capture env HOME="$FAKE_HOME" "$SHELL_BIN" -c 'echo unreachable'
assert_exit_code "both missing: launch fails" 1
assert_stderr_contains "both missing: rwDir error reported" \
	"$DIR_PATH: declared as rwDir but does not exist"
assert_stderr_contains "both missing: rwFile error reported" \
	"$FILE_PATH: declared as rwFile but does not exist"

# --- 2. Only rwDir missing ---
mkdir -p "$(dirname "$FILE_PATH")"
touch "$FILE_PATH"
capture env HOME="$FAKE_HOME" "$SHELL_BIN" -c 'echo unreachable'
assert_exit_code "rwDir missing only: launch fails" 1
assert_stderr_contains "rwDir missing only: rwDir error reported" \
	"$DIR_PATH: declared as rwDir but does not exist"
assert_stderr_not_contains "rwDir missing only: no rwFile error" \
	"declared as rwFile"

# --- 3. Only rwFile missing ---
rm -f "$FILE_PATH"
mkdir -p "$DIR_PATH"
capture env HOME="$FAKE_HOME" "$SHELL_BIN" -c 'echo unreachable'
assert_exit_code "rwFile missing only: launch fails" 1
assert_stderr_contains "rwFile missing only: rwFile error reported" \
	"$FILE_PATH: declared as rwFile but does not exist"
assert_stderr_not_contains "rwFile missing only: no rwDir error" \
	"declared as rwDir"

# --- 4. All present: launch succeeds ---
touch "$FILE_PATH"
capture env HOME="$FAKE_HOME" "$SHELL_BIN" -c 'echo ok'
assert_exit_code "all present: launch succeeds" 0
assert_output_equals "all present: command runs in sandbox" "ok"

print_results
exit_status
