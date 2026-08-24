#!/usr/bin/env bash
# Test: the wrapper's EXIT trap removes per-run temp state (Darwin-specific).
# The no-network wrapper used to `exec` into sandbox-exec, which replaced the
# shell and so skipped the EXIT trap entirely, leaking the ephemeral HOME, the
# runtime-patched seatbelt profile and the synthetic passwd file into /tmp.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

source "$SCRIPT_DIR/../lib.sh"

# Assertions in this suite check host state after the sandbox has exited, so
# `run` evaluates on the host rather than inside the sandbox.
run() { eval "$1"; }

# Every per-run temp path the trap is responsible for removing. /tmp/sandbox-proxy.log
# is deliberately excluded: it outlives a run by design.
tmp_state() {
	{
		ls -d /private/tmp/sandbox-home.* /tmp/sandbox-passwd.* /tmp/sandbox-profile-* \
			/tmp/sandbox-ca-cert.* /tmp/sandbox-ca-bundle.* /tmp/sandbox-proxy-port.* 2>/dev/null || true
	} | sort
}

proxy_pids() { { pgrep -f 'bin/sandbox-proxy' || true; } | sort | tr '\n' ' '; }

echo "=== Cleanup trap tests (Darwin) ==="
echo

STATE_BEFORE=$(tmp_state)
PROXY_BEFORE=$(proxy_pids)

SANDBOX_BIN=$(build_fixture basic-sandbox.nix)/bin/sandboxed-bash
NET_BIN=$(build_fixture network-allowed.nix)/bin/sandboxed-bash-net

TESTDIR_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)/.tmp-test"
mkdir -p "$TESTDIR_ROOT"
TESTDIR=$(mktemp -d "$TESTDIR_ROOT/cleanup-trap-darwin.XXXXXX")
trap 'rm -rf "$TESTDIR"' EXIT
cd "$TESTDIR"

# Pre-create the rwDir / rwFile declared by basic-sandbox.nix.
mkdir -p "$HOME/.test-state-dir"
touch "$HOME/.test-state-file"

# --- No-network wrapper (the path that used to exec) ---
capture "$SANDBOX_BIN" --norc --noprofile -c 'echo "$HOME"'
assert_exit_code "wrapper exits 0" 0
SB_HOME="$CAP_OUT"
expect_ok run "ran under an ephemeral HOME" \
	"printf '%s' '$SB_HOME' | grep -q '^/private/tmp/sandbox-home\.'"
expect_ok run "ephemeral HOME removed after exit" "test ! -e '$SB_HOME'"

# The trap must also fire when the sandboxed command fails, and must not
# swallow its exit status.
capture "$SANDBOX_BIN" --norc --noprofile -c 'echo "$HOME"; exit 3'
assert_exit_code "wrapper propagates non-zero exit status" 3
SB_HOME_FAIL="$CAP_OUT"
expect_ok run "ephemeral HOME removed after non-zero exit" "test ! -e '$SB_HOME_FAIL'"

# --- Networked wrapper (proxy branch of the trap) ---
capture "$NET_BIN" --norc --noprofile -c 'echo "$HOME"'
assert_exit_code "networked wrapper exits 0" 0
SB_HOME_NET="$CAP_OUT"
expect_ok run "networked ephemeral HOME removed after exit" "test ! -e '$SB_HOME_NET'"

# The proxy is killed, not waited on, so give it a moment to actually die.
for _ in $(seq 20); do
	if [ "$(proxy_pids)" = "$PROXY_BEFORE" ]; then break; fi
	sleep 0.1
done
expect_ok run "proxy process killed on exit" "[ '$(proxy_pids)' = '$PROXY_BEFORE' ]"

# --- Nothing at all left in /tmp ---
LEAKED=$(comm -13 <(printf '%s\n' "$STATE_BEFORE") <(printf '%s\n' "$(tmp_state)"))
if [ -n "$LEAKED" ]; then
	echo "leftover temp state:"
	printf '%s\n' "$LEAKED" | sed 's/^/    /'
fi
expect_ok run "no per-run temp state left in /tmp" "[ -z '$LEAKED' ]"

print_results
exit_status
