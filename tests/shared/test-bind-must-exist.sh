#!/usr/bin/env bash
# Test: missing rwDirs, rwFiles, roDirs, roFiles are silently skipped —
# the sandbox launches regardless of whether declared paths exist.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

source "$SCRIPT_DIR/../lib.sh"

SANDBOXED=$(nix-build --no-out-link "$SCRIPT_DIR/../fixtures/bind-must-exist.nix")
SHELL_BIN="$SANDBOXED/bin/sandboxed-bash-bind-must-exist"

TESTDIR_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)/.tmp-test"
mkdir -p "$TESTDIR_ROOT"
TESTDIR=$(mktemp -d "$TESTDIR_ROOT/bind-must-exist.XXXXXX")
trap 'rm -rf "$TESTDIR"' EXIT
cd "$TESTDIR"

FAKE_HOME="$TESTDIR/home"
mkdir -p "$FAKE_HOME"

DIR_PATH="$FAKE_HOME/.agent-sandbox-bind-must-exist/dir"
FILE_PATH="$FAKE_HOME/.agent-sandbox-bind-must-exist/file"

echo "=== Missing bind paths are silently skipped (shared) ==="
echo

# --- 1. Both missing: launch still succeeds, no output ---
capture env HOME="$FAKE_HOME" "$SHELL_BIN" -c 'echo ok'
assert_exit_code "both missing: launch succeeds" 0
assert_output_equals "both missing: command runs in sandbox" "ok"
assert_stderr_not_contains "both missing: no output about rwDir" "rwDir"
assert_stderr_not_contains "both missing: no output about rwFile" "rwFile"

# --- 2. Only rwDir missing ---
mkdir -p "$(dirname "$FILE_PATH")"
touch "$FILE_PATH"
capture env HOME="$FAKE_HOME" "$SHELL_BIN" -c 'echo ok'
assert_exit_code "rwDir missing only: launch succeeds" 0
assert_output_equals "rwDir missing only: command runs in sandbox" "ok"

# --- 3. Only rwFile missing ---
rm -f "$FILE_PATH"
mkdir -p "$DIR_PATH"
capture env HOME="$FAKE_HOME" "$SHELL_BIN" -c 'echo ok'
assert_exit_code "rwFile missing only: launch succeeds" 0
assert_output_equals "rwFile missing only: command runs in sandbox" "ok"

# --- 4. All present: launch succeeds ---
touch "$FILE_PATH"
capture env HOME="$FAKE_HOME" "$SHELL_BIN" -c 'echo ok'
assert_exit_code "all present: launch succeeds" 0
assert_output_equals "all present: command runs in sandbox" "ok"

print_results
exit_status
