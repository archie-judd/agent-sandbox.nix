#!/usr/bin/env bash
# Basic sandbox tests (Darwin-specific)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

source "$SCRIPT_DIR/../lib.sh"

SANDBOXED=$(build_fixture basic-sandbox.nix)
SHELL="$SANDBOXED/bin/sandboxed-bash"

run() { "$SHELL" --norc --noprofile -c "$1" >/dev/null 2>&1; }

TESTDIR_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)/.tmp-test"
mkdir -p "$TESTDIR_ROOT"
TESTDIR=$(mktemp -d "$TESTDIR_ROOT/basic-darwin.XXXXXX")
trap 'rm -rf "$TESTDIR"' EXIT
cd "$TESTDIR"

# Pre-create the rwDir / rwFile declared by basic-sandbox.nix. The wrapper no
# longer creates declared bind paths automatically.
mkdir -p "$HOME/.test-state-dir"
touch "$HOME/.test-state-file"

echo "=== Basic sandbox tests (Darwin) ==="
echo

# --- Darwin-specific tests ---
expect_fail run "cannot write to /etc" "touch /etc/test"
expect_ok run "can exec /bin/sh subshell" "/bin/sh -c 'echo hello'"

REAL_HOME="/Users/$(whoami)"
expect_fail run "cannot read real home" "ls $REAL_HOME/.ssh"

# --- Directory enumeration (readdir blocked, stat allowed) ---
expect_fail run "cannot enumerate /Users" "ls /Users/"
expect_fail run "cannot enumerate real home dir" "ls $REAL_HOME/"
expect_ok run "stat on /Users succeeds (path traversal)" "test -d /Users"
expect_ok run "stat on real home succeeds (path traversal)" "test -d $REAL_HOME"

# --- TTY isolation (escape-sequence / TIOCSTI injection defense) ---
expect_fail run "cannot open /dev/tty for writes" "printf '\a' > /dev/tty"

print_results
exit_status
