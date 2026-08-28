#!/usr/bin/env bash
# Test: UNIX-socket egress is denied from inside the sandbox in filtered
# mode (allowedDomains set). The open-mode mechanism is covered by
# test-localhost-denied-unrestricted.sh.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEST_CWD="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$SCRIPT_DIR/../lib.sh"

SANDBOXED=$(build_fixture unix-socket-client-sandbox.nix)
SHELL="$SANDBOXED/bin/sandboxed-bash"

# Host-side python3 from nixpkgs, for the UNIX-socket listener below.
# /usr/bin/python3 on macOS is a Command Line Tools stub that isn't safe
# to depend on in CI; nix-provided python3 is reproducible.
HOST_PYTHON3=$(build_host_pkg python3Minimal)/bin/python3

# The launch directory, so the socket below is one the sandbox can reach.
run() { (cd "$TEST_CWD" && "$SHELL" --norc --noprofile -c "$1") >/dev/null 2>&1; }

TESTDIR_ROOT="$TEST_CWD/.tmp-test"
mkdir -p "$TESTDIR_ROOT"
TESTDIR=$(mktemp -d "$TESTDIR_ROOT/unix-socket-egress-denied.XXXXXX")

# Place the socket inside the launch directory, which the sandbox has
# file-read/write on. This isolates the assertion: if connect() is denied,
# it is the network-outbound rule (now absent) doing it, not filesystem
# reachability. The names are short because sun_path holds only 104 bytes.
SOCK_DIR=$(mktemp -d "$TESTDIR_ROOT/uxs.XXXXXX")
SOCK_PATH="$SOCK_DIR/l.sock"

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
expect_ok run "socat binary is available inside the sandbox" "command -v socat"

# Real assertion. socat exits non-zero on connect() failure. We send a
# byte (printf x) to ensure the right side is opened — socat's bidirectional
# mode is lazy when stdin is EOF, which would skip the connect syscall.
expect_fail run "cannot connect() to UNIX socket on host" "printf x | socat -t 1 - UNIX-CONNECT:'$SOCK_PATH'"

print_results
exit_status
