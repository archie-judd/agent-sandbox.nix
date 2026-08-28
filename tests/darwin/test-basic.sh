#!/usr/bin/env bash
# Basic sandbox tests (Darwin-specific)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

source "$SCRIPT_DIR/../lib.sh"

SANDBOXED=$(build_fixture basic-sandbox.nix)
SHELL="$SANDBOXED/bin/sandboxed-bash"

run() { "$SHELL" --norc --noprofile -c "$1" >/dev/null 2>&1; }
run_output() { "$SHELL" --norc --noprofile -c "$1" 2>/dev/null; }
# For assertions about the launch itself rather than about what the sandbox
# can reach.
on_host() { eval "$1"; }

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

# --- Host temp roots ---
# There is no mount namespace on darwin, so /tmp is the host's own /tmp,
# shared with every other user of the machine. It is denied outright, and
# TMPDIR points inside the session directory instead.
TMP_CANARY=$(mktemp /tmp/sandbox-host-canary.XXXXXX)
trap 'rm -rf "$TESTDIR"; rm -f "$TMP_CANARY"' EXIT

expect_fail run "cannot write to /tmp" "touch /tmp/sandbox-test"
expect_fail run "cannot write to /private/tmp" "touch /private/tmp/sandbox-test"
expect_fail run "cannot read host files in /tmp" "cat '$TMP_CANARY'"
expect_fail run "cannot read host files in /private/tmp" "cat '/private$TMP_CANARY'"
expect_fail run "cannot enumerate /tmp" "ls /tmp/"

SESSIONS_ROOT_REAL=$(cd "$AGENT_SANDBOX_SESSIONS_ROOT" && pwd -P)
SANDBOX_TMPDIR=$(run_output 'echo $TMPDIR')
expect_ok on_host "TMPDIR is inside the sessions root" \
	"case '$SANDBOX_TMPDIR' in '$SESSIONS_ROOT_REAL'/*) ;; *) exit 1 ;; esac"
expect_ok run "TMPDIR is writable" "touch \$TMPDIR/sandbox-test && rm \$TMPDIR/sandbox-test"

SANDBOX_HOME=$(run_output 'echo $HOME')
expect_ok on_host "HOME is inside the sessions root" \
	"case '$SANDBOX_HOME' in '$SESSIONS_ROOT_REAL'/*) ;; *) exit 1 ;; esac"

# --- TTY isolation (escape-sequence / TIOCSTI injection defense) ---
expect_fail run "cannot open /dev/tty for writes" "printf '\a' > /dev/tty"

print_results
exit_status
