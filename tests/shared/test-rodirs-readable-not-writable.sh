#!/usr/bin/env bash
# Test: roDirs / roFiles are readable but not writable from inside the sandbox.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

source "$SCRIPT_DIR/../lib.sh"

SANDBOXED=$(build_fixture ro-binds-sandbox.nix)
SHELL="$SANDBOXED/bin/sandboxed-bash-ro-binds"

run() { "$SHELL" --norc --noprofile -c "$1" >/dev/null 2>&1; }
run_output() { "$SHELL" --norc --noprofile -c "$1" 2>/dev/null; }

TESTDIR_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)/.tmp-test"
mkdir -p "$TESTDIR_ROOT"
TESTDIR=$(mktemp -d "$TESTDIR_ROOT/ro-binds.XXXXXX")
trap 'rm -rf "$TESTDIR" "$HOME/.test-ro-dir" "$HOME/.test-ro-file"' EXIT
cd "$TESTDIR"

# Pre-create the declared roDir / roFile with known content.
mkdir -p "$HOME/.test-ro-dir"
echo "dir-content" > "$HOME/.test-ro-dir/contents.txt"
echo "file-content" > "$HOME/.test-ro-file"

echo "=== roDirs / roFiles read-only behavior (shared) ==="
echo

# --- roDir reads succeed ---
expect_ok run "can read file under roDir" "cat \$HOME/.test-ro-dir/contents.txt > /dev/null"
expect_ok run "can list roDir contents" "ls \$HOME/.test-ro-dir > /dev/null"
content=$(run_output "cat \$HOME/.test-ro-dir/contents.txt")
if [ "$content" = "dir-content" ]; then
	echo "PASS: roDir file content is correct"
	PASS=$((PASS + 1))
else
	echo "FAIL: roDir file content is wrong (got '$content', expected 'dir-content')"
	FAIL=$((FAIL + 1))
fi

# --- roDir writes fail ---
expect_fail run "cannot modify file under roDir" "echo modified > \$HOME/.test-ro-dir/contents.txt"
expect_fail run "cannot create new file under roDir" "touch \$HOME/.test-ro-dir/new-file"
expect_fail run "cannot delete file under roDir" "rm \$HOME/.test-ro-dir/contents.txt"

# --- roFile reads succeed ---
expect_ok run "can read roFile" "cat \$HOME/.test-ro-file > /dev/null"
content=$(run_output "cat \$HOME/.test-ro-file")
if [ "$content" = "file-content" ]; then
	echo "PASS: roFile content is correct"
	PASS=$((PASS + 1))
else
	echo "FAIL: roFile content is wrong (got '$content', expected 'file-content')"
	FAIL=$((FAIL + 1))
fi

# --- roFile writes fail ---
expect_fail run "cannot overwrite roFile" "echo overwrite > \$HOME/.test-ro-file"
expect_fail run "cannot append to roFile" "echo append >> \$HOME/.test-ro-file"
# Note: we deliberately don't assert `rm $HOME/.test-ro-file` fails. On Darwin
# the wrapper exposes roFiles by symlinking them into SANDBOX_HOME, so `rm`
# unlinks the writable symlink rather than the bound host file. The check
# below proves the property we actually care about: the host file is intact
# after the write attempts.
host_content=$(cat "$HOME/.test-ro-file" 2>/dev/null)
if [ "$host_content" = "file-content" ]; then
	echo "PASS: host roFile content unchanged after write attempts"
	PASS=$((PASS + 1))
else
	echo "FAIL: host roFile content modified (got '$host_content', expected 'file-content')"
	FAIL=$((FAIL + 1))
fi

print_results
exit_status
