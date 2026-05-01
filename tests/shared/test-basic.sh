#!/usr/bin/env bash
# Basic sandbox isolation and access tests (shared across platforms)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
echo "{}" >> test.nix

source "$SCRIPT_DIR/../lib.sh"

SANDBOXED=$(nix-build --no-out-link "$SCRIPT_DIR/../fixtures/basic-sandbox.nix")
SHELL="$SANDBOXED/bin/sandboxed-bash"

run() { "$SHELL" --norc --noprofile -c "$@" >/dev/null 2>&1; }
run_output() { "$SHELL" --norc --noprofile -c "$@" 2>/dev/null; }

TESTDIR_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)/.tmp-test"
mkdir -p "$TESTDIR_ROOT"
TESTDIR=$(mktemp -d "$TESTDIR_ROOT/basic.XXXXXX")
trap 'rm -rf "$TESTDIR"' EXIT
cd "$TESTDIR"

echo "=== Basic sandbox tests (shared) ==="
echo

# --- Isolation ---
expect_fail "cannot read ~/.ssh" "ls \$HOME/.ssh"
expect_fail "cannot read ~/.bash_history" "cat \$HOME/.bash_history"
expect_fail "cannot read /root" "ls /root"
expect_fail "cannot read CWD *.nix files" "cat ./test.nix"

# --- Basic access ---
expect_ok "can write to CWD" "touch ./sandbox-test-file && rm ./sandbox-test-file"
expect_ok "can write to /tmp" "touch /tmp/sandbox-test && rm /tmp/sandbox-test"
expect_ok "can read /etc/resolv.conf" "cat /etc/resolv.conf > /dev/null"
expect_ok "can run allowed binaries" "ls / > /dev/null"

# --- stateDirs / stateFiles / extraEnv ---
if [ "$(run_output 'echo $TEST_VAR')" = "test-value" ]; then
	echo "PASS: extraEnv variable is accessible"
	PASS=$((PASS + 1))
else
	echo "FAIL: extraEnv variable not accessible"
	FAIL=$((FAIL + 1))
fi

# --- Environment isolation (env -i) ---
export _TEST_HOST_VAR="should-not-propagate"
if [ -z "$(run_output 'echo $_TEST_HOST_VAR')" ]; then
	echo "PASS: host env vars not in extraEnv are not propagated"
	PASS=$((PASS + 1))
else
	echo "FAIL: host env var leaked into sandbox"
	FAIL=$((FAIL + 1))
fi

# --- Ephemeral HOME (both platforms) ---
expect_ok "home is empty tmpfs" "ls \$HOME"
expect_ok "home tmpfs is writable (ephemeral)" "touch \$HOME/.test-write && rm \$HOME/.test-write"
expect_fail "host dotfiles are not visible" "ls \$HOME/.bashrc"

print_results
exit_status
