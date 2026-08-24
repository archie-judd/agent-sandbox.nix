#!/usr/bin/env bash
# Basic sandbox isolation and access tests (shared across platforms)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

source "$SCRIPT_DIR/../lib.sh"

SANDBOXED=$(build_fixture basic-sandbox.nix)
SHELL="$SANDBOXED/bin/sandboxed-bash"

run() { "$SHELL" --norc --noprofile -c "$1" >/dev/null 2>&1; }
run_output() { "$SHELL" --norc --noprofile -c "$1" 2>/dev/null; }

TESTDIR_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)/.tmp-test"
mkdir -p "$TESTDIR_ROOT"
TESTDIR=$(mktemp -d "$TESTDIR_ROOT/basic.XXXXXX")
trap 'rm -rf "$TESTDIR"' EXIT
cd "$TESTDIR"

# Pre-create the rwDir / rwFile declared by basic-sandbox.nix. The wrapper no
# longer creates declared bind paths automatically.
mkdir -p "$HOME/.test-state-dir"
touch "$HOME/.test-state-file"

echo "=== Basic sandbox tests (shared) ==="
echo

# --- Isolation ---
expect_fail run "cannot read ~/.ssh" "ls \$HOME/.ssh"
expect_fail run "cannot read ~/.bash_history" "cat \$HOME/.bash_history"
expect_fail run "cannot read /root" "ls /root"

# --- Basic access ---
expect_ok run "can write to CWD" "touch ./sandbox-test-file && rm ./sandbox-test-file"
expect_ok run "can write to /tmp" "touch /tmp/sandbox-test && rm /tmp/sandbox-test"
expect_ok run "can read /etc/resolv.conf" "cat /etc/resolv.conf > /dev/null"
expect_ok run "can run allowed binaries" "ls / > /dev/null"

# --- rwDirs / rwFiles / env ---
if [ "$(run_output 'echo $TEST_VAR')" = "test-value" ]; then
	echo "PASS: env variable is accessible"
	PASS=$((PASS + 1))
else
	echo "FAIL: env variable not accessible"
	FAIL=$((FAIL + 1))
fi

# --- Environment isolation (env -i) ---
export _TEST_HOST_VAR="should-not-propagate"
if [ -z "$(run_output 'echo $_TEST_HOST_VAR')" ]; then
	echo "PASS: host env vars not in env are not propagated"
	PASS=$((PASS + 1))
else
	echo "FAIL: host env var leaked into sandbox"
	FAIL=$((FAIL + 1))
fi

# --- Ephemeral HOME (both platforms) ---
expect_ok run "home is empty tmpfs" "ls \$HOME"
expect_ok run "home tmpfs is writable (ephemeral)" "touch \$HOME/.test-write && rm \$HOME/.test-write"
expect_fail run "host dotfiles are not visible" "ls \$HOME/.bashrc"

# --- /usr/bin/env shebang support ---
printf '#!/usr/bin/env sh\necho hello\n' > "$TESTDIR/env-shebang.sh"
chmod +x "$TESTDIR/env-shebang.sh"
expect_ok run "/usr/bin/env resolves shebang interpreter" "./env-shebang.sh"

# --- /etc/passwd does not expose host username ---
# Linux: synthetic single-entry file is served; Darwin: /private/etc/passwd is denied entirely.
# In both cases the host username must not appear in the username field (field 1).
host_username=$(id -un)
sandbox_passwd_username=$("$SHELL" --norc --noprofile -c 'cut -d: -f1 /etc/passwd 2>/dev/null' 2>/dev/null || echo "")
if [ "$sandbox_passwd_username" != "$host_username" ]; then
	echo "PASS: host username not exposed via /etc/passwd"
	PASS=$((PASS + 1))
else
	echo "FAIL: host username '$host_username' visible in /etc/passwd username field"
	FAIL=$((FAIL + 1))
fi

print_results
exit_status
