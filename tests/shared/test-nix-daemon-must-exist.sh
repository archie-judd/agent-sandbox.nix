#!/usr/bin/env bash
# Test: allowNix = true refuses the launch when there is no nix daemon socket
# at the path the launcher would expose.
#
# Without the check the launch succeeded, having already exposed the whole
# store, and the first nix command inside the sandbox failed on its own with a
# connect error naming a path nothing had told the user about. A single-user
# install, where there is no daemon at all, is the same refusal: it cannot be
# supported, because operating the store directly needs the store bound
# read-write.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

source "$SCRIPT_DIR/../lib.sh"

NIX_SUPPORT=$(build_fixture nix-support.nix)
SHELL_BIN="$NIX_SUPPORT/bin/sandboxed-bash-nix-support"

TESTDIR_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)/.tmp-test"
mkdir -p "$TESTDIR_ROOT"
TESTDIR=$(mktemp -d "$TESTDIR_ROOT/nix-daemon-must-exist.XXXXXX")
trap 'rm -rf "$TESTDIR"' EXIT
# Physical, because the launcher resolves the socket path before naming it in
# the refusal, and an assertion here has to match that name exactly.
TESTDIR=$(cd "$TESTDIR" && pwd -P)
cd "$TESTDIR"

echo "=== Nix daemon socket must exist (shared) ==="
echo

# --- 1. Nothing at the socket path ---
MISSING="$TESTDIR/no-daemon-here/socket"
capture env NIX_DAEMON_SOCKET_PATH="$MISSING" \
	"$SHELL_BIN" --norc --noprofile -c 'echo unreachable'
assert_exit_code "missing socket: launch fails" 1
assert_stderr_contains "missing socket: refusal names the path" \
	"no nix daemon socket at $MISSING"
assert_output_not_contains "missing socket: nothing runs inside" "unreachable"

# --- 2. Something there, but not a socket ---
NOT_A_SOCKET="$TESTDIR/regular-file"
touch "$NOT_A_SOCKET"
capture env NIX_DAEMON_SOCKET_PATH="$NOT_A_SOCKET" \
	"$SHELL_BIN" --norc --noprofile -c 'echo unreachable'
assert_exit_code "not a socket: launch fails" 1
assert_stderr_contains "not a socket: refusal names the path" \
	"no nix daemon socket at $NOT_A_SOCKET"

# --- 3. The host's own daemon, which the rest of the nix suite needs anyway ---
capture "$SHELL_BIN" --norc --noprofile -c 'echo ok'
assert_exit_code "host daemon present: launch succeeds" 0
assert_output_equals "host daemon present: command runs in sandbox" "ok"

print_results
exit_status
