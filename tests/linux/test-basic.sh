#!/usr/bin/env bash
# Basic sandbox tests (Linux-specific)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

source "$SCRIPT_DIR/../lib.sh"

SANDBOXED=$(build_fixture basic-sandbox.nix)
SHELL="$SANDBOXED/bin/sandboxed-bash"

run() { "$SHELL" --norc --noprofile -c "$1" >/dev/null 2>&1; }

TESTDIR_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)/.tmp-test"
mkdir -p "$TESTDIR_ROOT"
TESTDIR=$(mktemp -d "$TESTDIR_ROOT/basic-linux.XXXXXX")
trap 'rm -rf "$TESTDIR"' EXIT
cd "$TESTDIR"

# Pre-create the rwDir / rwFile declared by basic-sandbox.nix. The wrapper no
# longer creates declared bind paths automatically.
mkdir -p "$HOME/.test-state-dir"
touch "$HOME/.test-state-file"

echo "=== Basic sandbox tests (Linux) ==="
echo

# --- Linux-specific tests ---
expect_ok run "/etc is writable tmpfs (ephemeral)" "touch /etc/test && rm /etc/test"
expect_fail run "cannot read host /etc/shadow" "cat /etc/shadow"

# /tmp is its own tmpfs inside the mount namespace, so it is writable and is
# not the host's. Darwin has no mount namespace and denies it instead.
expect_ok run "/tmp is a writable tmpfs" "touch /tmp/sandbox-test && rm /tmp/sandbox-test"
HOST_TMP_CANARY=$(mktemp /tmp/sandbox-host-canary.XXXXXX)
trap 'rm -rf "$TESTDIR"; rm -f "$HOST_TMP_CANARY"' EXIT
expect_fail run "host /tmp is not visible" "test -e '$HOST_TMP_CANARY'"

# --- No host env leak via /proc/1/environ ---
# PID 1 in the sandbox is bubblewrap's own init process, which it keeps so it
# can reap; the sandboxed program is PID 2. Its environ is not empty: the
# launcher passes the computed environment as `env -i K=V ... bwrap ...` and
# relies on bubblewrap passing its own environment through, rather than setting
# it with --setenv. So what matters is not the size but what is absent, which is
# anything the host had and the sandbox was not given. PID 2 holds the same
# variables anyway, so this asserts the leak, not the duplication.
export SANDBOX_TEST_HOST_ONLY=canary-must-not-leak
capture "$SHELL" --norc --noprofile -c 'tr "\0" "\n" < /proc/1/environ'
# Guarded, because an unreadable environ would leave the output empty and make
# the absence check below pass for the wrong reason.
assert_exit_code "/proc/1/environ is readable" 0
assert_output_not_contains "no host env leak via /proc/1/environ" "SANDBOX_TEST_HOST_ONLY"

# --- Hostname is neutralised (no UTS namespace leak) ---
host_hostname=$(uname -n)
sandbox_hostname=$("$SHELL" --norc --noprofile -c 'uname -n' 2>/dev/null || echo "error")
if [ "$sandbox_hostname" = "sandbox" ] && [ "$sandbox_hostname" != "$host_hostname" ]; then
	echo "PASS: hostname inside sandbox is 'sandbox', not host hostname"
	PASS=$((PASS + 1))
else
	echo "FAIL: sandbox hostname is '$sandbox_hostname' (host: '$host_hostname')"
	FAIL=$((FAIL + 1))
fi

# --- /etc/passwd is a synthetic single-entry file (no host username leak) ---
passwd_line_count=$("$SHELL" --norc --noprofile -c 'wc -l < /etc/passwd' 2>/dev/null || echo "error")
if [ "$passwd_line_count" = "1" ]; then
	echo "PASS: /etc/passwd has exactly 1 line"
	PASS=$((PASS + 1))
else
	echo "FAIL: /etc/passwd has $passwd_line_count lines, expected 1"
	FAIL=$((FAIL + 1))
fi

sandbox_passwd_uid=$("$SHELL" --norc --noprofile -c 'cut -d: -f3 /etc/passwd' 2>/dev/null || echo "error")
if [ "$sandbox_passwd_uid" = "$(id -u)" ]; then
	echo "PASS: /etc/passwd UID matches host UID"
	PASS=$((PASS + 1))
else
	echo "FAIL: /etc/passwd UID is '$sandbox_passwd_uid', expected '$(id -u)'"
	FAIL=$((FAIL + 1))
fi


# --- /proc/cmdline is masked (no host hostname or kernel version leak) ---
proc_cmdline=$("$SHELL" --norc --noprofile -c 'cat /proc/cmdline' 2>/dev/null || echo "error")
if [ -z "$proc_cmdline" ]; then
	echo "PASS: /proc/cmdline is masked (empty)"
	PASS=$((PASS + 1))
else
	echo "FAIL: /proc/cmdline not masked (got: $proc_cmdline)"
	FAIL=$((FAIL + 1))
fi

# --- /proc/sys/kernel/random/boot_id is masked (no stable host fingerprint) ---
boot_id=$("$SHELL" --norc --noprofile -c 'cat /proc/sys/kernel/random/boot_id' 2>/dev/null || echo "error")
if [ -z "$boot_id" ]; then
	echo "PASS: /proc/sys/kernel/random/boot_id is masked (empty)"
	PASS=$((PASS + 1))
else
	echo "FAIL: /proc/sys/kernel/random/boot_id not masked (got: $boot_id)"
	FAIL=$((FAIL + 1))
fi

print_results
exit_status
