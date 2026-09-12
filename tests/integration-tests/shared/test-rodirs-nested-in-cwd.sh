#!/usr/bin/env bash
# Test: a roDir / roFile declared inside the launch directory is readable but
# not writable, even though the launch directory itself is bound read-write.
# Seatbelt grants per operation, so the read-only declaration's read allow does
# not by itself revoke the write the launch-directory grant gave.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

source "$SCRIPT_DIR/../lib.sh"

SANDBOXED=$(build_fixture nested-ro-in-cwd.nix)
SHELL_BIN="$SANDBOXED/bin/sandboxed-bash-nested-ro-in-cwd"

TESTDIR_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)/.tmp-test"
mkdir -p "$TESTDIR_ROOT"

FAKE_HOME=$(mktemp -d "$TESTDIR_ROOT/nested-ro-home.XXXXXX")
trap 'rm -rf "$FAKE_HOME"' EXIT

LAUNCH_DIR="$FAKE_HOME/.agent-sandbox-nested-ro"
mkdir -p "$LAUNCH_DIR/vendor"
echo "dir-content" >"$LAUNCH_DIR/vendor/contents.txt"
echo "file-content" >"$LAUNCH_DIR/pinned.txt"
cd "$LAUNCH_DIR"

run() { env HOME="$FAKE_HOME" "$SHELL_BIN" --norc --noprofile -c "$1" >/dev/null 2>&1; }
run_output() { env HOME="$FAKE_HOME" "$SHELL_BIN" --norc --noprofile -c "$1" 2>/dev/null; }

expect_content() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$actual" = "$expected" ]; then
    echo "PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $desc (got '$actual', expected '$expected')"
    FAIL=$((FAIL + 1))
  fi
}

echo "=== roDirs / roFiles nested in the launch directory (shared) ==="
echo

# --- reads succeed ---
expect_ok run "can read file under nested roDir" "cat vendor/contents.txt > /dev/null"
expect_ok run "can list nested roDir contents" "ls vendor > /dev/null"
expect_content "nested roDir file content is correct" "dir-content" \
  "$(run_output "cat vendor/contents.txt")"
expect_ok run "can read nested roFile" "cat pinned.txt > /dev/null"
expect_content "nested roFile content is correct" "file-content" \
  "$(run_output "cat pinned.txt")"

# --- writes fail ---
expect_fail run "cannot modify file under nested roDir" "echo modified > vendor/contents.txt"
expect_fail run "cannot create new file under nested roDir" "touch vendor/new-file"
expect_fail run "cannot delete file under nested roDir" "rm vendor/contents.txt"
expect_fail run "cannot overwrite nested roFile" "echo overwrite > pinned.txt"
expect_fail run "cannot append to nested roFile" "echo append >> pinned.txt"

expect_ok run "can still write elsewhere in the launch directory" "touch sibling-file"

# --- the host files are intact ---
expect_content "host roDir file content unchanged" "dir-content" \
  "$(cat "$LAUNCH_DIR/vendor/contents.txt" 2>/dev/null)"
expect_content "host roFile content unchanged" "file-content" \
  "$(cat "$LAUNCH_DIR/pinned.txt" 2>/dev/null)"
if [ ! -e "$LAUNCH_DIR/vendor/new-file" ]; then
  echo "PASS: nothing created inside the host roDir"
  PASS=$((PASS + 1))
else
  echo "FAIL: a file was created inside the host roDir"
  FAIL=$((FAIL + 1))
fi

print_results
exit_status
