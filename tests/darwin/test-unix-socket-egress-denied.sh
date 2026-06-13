#!/usr/bin/env bash
# Test: UNIX-socket egress is denied from inside the sandbox in filtered
# mode (allowedDomains set). Regression guard for SANDBOX-FINDINGS.md §2.
#
# Both modes now deny AF_UNIX outbound, but via different mechanisms —
# see tests/fixtures/unix-socket-client-sandbox.nix for the split. This
# test exercises the filtered-mode mechanism; the open-mode mechanism is
# covered by tests/darwin/test-localhost-denied-unrestricted.sh.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

source "$SCRIPT_DIR/../lib.sh"

SANDBOXED=$(nix-build --no-out-link "$SCRIPT_DIR/../fixtures/unix-socket-client-sandbox.nix")
SHELL="$SANDBOXED/bin/sandboxed-bash"

# Host-side python3 from nixpkgs, for the UNIX-socket listener below.
# /usr/bin/python3 on macOS is a Command Line Tools stub that isn't safe
# to depend on in CI; nix-provided python3 is reproducible.
HOST_PYTHON3=$(nix-build --no-out-link -E '(import <nixpkgs> {}).python3Minimal')/bin/python3

run() { "$SHELL" --norc --noprofile -c "$@" >/dev/null 2>&1; }

TESTDIR_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)/.tmp-test"
mkdir -p "$TESTDIR_ROOT"
TESTDIR=$(mktemp -d "$TESTDIR_ROOT/unix-socket-egress-denied.XXXXXX")

# Place the socket under /private/tmp so its directory is in the
# seatbelt allow set (file-read/write for /private/tmp). This isolates
# the assertion: if connect() is denied, it's the network-outbound rule
# (now absent) doing it, not filesystem reachability.
SOCK_DIR=$(mktemp -d "/private/tmp/sandbox-unix-egress.XXXXXX")
SOCK_PATH="$SOCK_DIR/listener.sock"

LISTENER_PID=""
cleanup() {
	if [ -n "$LISTENER_PID" ]; then
		kill "$LISTENER_PID" 2>/dev/null || true
		wait "$LISTENER_PID" 2>/dev/null || true
	fi
	rm -rf "$SOCK_DIR" "$TESTDIR"
}
trap cleanup EXIT

# Host-side UNIX-socket listener that actually accept()s — so a successful
# connect() would observably complete, not just queue in the kernel backlog.
"$HOST_PYTHON3" -c '
import socket, sys, signal, threading
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.bind(sys.argv[1])
s.listen(128)
sys.stdout.write("READY\n"); sys.stdout.flush()
def loop():
    while True:
        try:
            c, _ = s.accept()
            c.close()
        except Exception:
            break
threading.Thread(target=loop, daemon=True).start()
signal.pause()
' "$SOCK_PATH" >"$TESTDIR/listener.log" 2>&1 &
LISTENER_PID=$!

for _ in $(seq 1 50); do
	[ -S "$SOCK_PATH" ] && break
	sleep 0.1
done
if [ ! -S "$SOCK_PATH" ]; then
	echo "ERROR: host listener never bound $SOCK_PATH" >&2
	echo "--- listener.log ---" >&2
	cat "$TESTDIR/listener.log" >&2 || true
	echo "--- end listener.log ---" >&2
	exit 1
fi

echo "=== UNIX-socket egress denied (Darwin) ==="
echo "SOCK_PATH=$SOCK_PATH"
echo

# Sanity: the client tool resolves inside the sandbox. If this fails the
# egress assertion below is meaningless (a missing binary also exits non-zero).
expect_ok "socat binary is available inside the sandbox" "command -v socat"

# Real assertion. socat exits non-zero on connect() failure. We send a
# byte (printf x) to ensure the right side is opened — socat's bidirectional
# mode is lazy when stdin is EOF, which would skip the connect syscall.
expect_fail "cannot connect() to UNIX socket on host" "printf x | socat -t 1 - UNIX-CONNECT:'$SOCK_PATH'"

print_results
exit_status
