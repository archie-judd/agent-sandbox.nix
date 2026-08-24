#!/usr/bin/env bash
# Test: ancestor directory traversal for deeply nested CWD paths (Darwin-specific)
# Verifies that file-read-metadata is granted on all intermediate directories
# between $HOME and the repo root, fixing EPERM on realpathSync/lstat.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

source "$SCRIPT_DIR/../lib.sh"

echo "=== Deep CWD ancestor traversal tests (Darwin) ==="
echo

SANDBOXED=$(build_fixture deep-cwd-sandbox.nix)
SHELL="$SANDBOXED/bin/sandboxed-bash-deep-cwd"

# Create a deeply nested directory under HOME to simulate a path with multiple
# ancestor directories between $HOME and the repo root / CWD.
DEEP_DIR="$HOME/.tmp-test-deep-cwd/a/b/c/d/e"
mkdir -p "$DEEP_DIR"
trap 'rm -rf "$HOME/.tmp-test-deep-cwd"' EXIT

# Initialize a git repo at the deep leaf so REPO_ROOT is deeply nested.
git -C "$DEEP_DIR" init -q

# run/run_output must execute the sandboxed shell FROM the deep directory.
run() { (cd "$DEEP_DIR" && "$SHELL" --norc --noprofile -c "$1") >/dev/null 2>&1; }
run_output() { (cd "$DEEP_DIR" && "$SHELL" --norc --noprofile -c "$1") 2>/dev/null; }

# Verify that stat() on an intermediate ancestor succeeds.
# Before the fix these would EPERM because the seatbelt profile lacked
# file-read-metadata rules for directories between $HOME and $REPO_ROOT.
# PARENT5 ($HOME/.tmp-test-deep-cwd/a/b/c/d) == REPO_ROOT_PARENT and was
# already covered by the old profile, so we only test PARENT1–PARENT4.
PARENT1="$HOME/.tmp-test-deep-cwd"
PARENT2="$HOME/.tmp-test-deep-cwd/a"
PARENT3="$HOME/.tmp-test-deep-cwd/a/b"
PARENT4="$HOME/.tmp-test-deep-cwd/a/b/c"

expect_ok run "stat on 1st ancestor dir succeeds" "test -d '$PARENT1'"
expect_ok run "stat on 2nd ancestor dir succeeds" "test -d '$PARENT2'"
expect_ok run "stat on 3rd ancestor dir succeeds" "test -d '$PARENT3'"
expect_ok run "stat on 4th ancestor dir succeeds" "test -d '$PARENT4'"

# Verify that directory listing of an ancestor is still denied (only stat
# is permitted — not readdir/file-read-data).
expect_fail run "cannot list contents of 1st ancestor" "ls '$PARENT1/'"

# Verify realpathSync-equivalent: resolve a symlink path that requires
# lstat on each component. We use 'ls -la' on the CWD via its absolute
# path to force kernel path resolution through each ancestor.
expect_ok run "can stat the deep repo root via absolute path" "test -d '$DEEP_DIR'"

# Verify the sandbox still works normally (reads CWD, writes /tmp).
expect_ok run "can write a file in the deep CWD" "touch '$DEEP_DIR/sandbox-test' && rm '$DEEP_DIR/sandbox-test'"
expect_ok run "can write to /tmp from deep CWD" "touch /tmp/sandbox-deep-test && rm /tmp/sandbox-deep-test"

print_results
exit_status
