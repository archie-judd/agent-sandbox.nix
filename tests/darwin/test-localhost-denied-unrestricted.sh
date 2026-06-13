#!/usr/bin/env bash
# Test: with allowedDomains omitted (open network mode), the sandbox can still
# reach the public internet but cannot reach host loopback (TCP IPv4 + IPv6)
# or host UNIX sockets. Regression for docs/v1-plan.md PR C — Darwin
# localhost/UNIX-socket deny by default.
#
# The same protection already holds in filtered mode (allowedDomains set);
# this test exercises the open mode where, prior to PR C, (allow network*)
# and (allow system-socket) let the sandbox connect() to either.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

source "$SCRIPT_DIR/../lib.sh"

SANDBOXED=$(nix-build --no-out-link "$SCRIPT_DIR/../fixtures/network-unrestricted-with-socat.nix")
SHELL="$SANDBOXED/bin/sandboxed-bash-unres-socat"

# Host-side python3 from nixpkgs, for the listener trio below.
# /usr/bin/python3 on macOS is a Command Line Tools stub that isn't safe
# to depend on in CI; nix-provided python3 is reproducible.
HOST_PYTHON3=$(nix-build --no-out-link -E '(import <nixpkgs> {}).python3Minimal')/bin/python3

run() { "$SHELL" --norc --noprofile -c "$@" >/dev/null 2>&1; }

# --- Setup ---

TCP4_PORT=18931
TCP6_PORT=18932

# Place the UNIX socket under /private/tmp so its directory is in the
# seatbelt allow set — isolates the deny to the network rule, not filesystem
# reachability.
SOCK_DIR=$(mktemp -d "/private/tmp/sandbox-open-loopback.XXXXXX")
SOCK_PATH="$SOCK_DIR/listener.sock"

TESTDIR_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)/.tmp-test"
mkdir -p "$TESTDIR_ROOT"
TESTDIR=$(mktemp -d "$TESTDIR_ROOT/localhost-denied-unrestricted.XXXXXX")

LISTENER_PID=""
cleanup() {
	if [ -n "$LISTENER_PID" ]; then
		kill "$LISTENER_PID" 2>/dev/null || true
		wait "$LISTENER_PID" 2>/dev/null || true
	fi
	rm -rf "$SOCK_DIR" "$TESTDIR"
}
trap cleanup EXIT

# Pre-flight: bail if ports are already in use; we'd false-pass otherwise.
if nc -z 127.0.0.1 "$TCP4_PORT" 2>/dev/null; then
	echo "FAIL: test setup — 127.0.0.1:$TCP4_PORT already in use" >&2
	exit 1
fi
if nc -z ::1 "$TCP6_PORT" 2>/dev/null; then
	echo "FAIL: test setup — [::1]:$TCP6_PORT already in use" >&2
	exit 1
fi

# Single python process binds three listeners (TCP v4, TCP v6, UNIX) and
# accept()s — so a successful connect() observably completes rather than
# queueing silently in the kernel backlog.
"$HOST_PYTHON3" -c '
import socket, sys, signal, threading
sock_path, p4, p6 = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
u  = socket.socket(socket.AF_UNIX,  socket.SOCK_STREAM); u.bind(sock_path);          u.listen(8)
t4 = socket.socket(socket.AF_INET,  socket.SOCK_STREAM); t4.bind(("127.0.0.1", p4)); t4.listen(8)
t6 = socket.socket(socket.AF_INET6, socket.SOCK_STREAM); t6.bind(("::1", p6));       t6.listen(8)
sys.stdout.write("READY\n"); sys.stdout.flush()
def loop(s):
    while True:
        try:
            c, _ = s.accept(); c.close()
        except Exception:
            break
for s in (u, t4, t6):
    threading.Thread(target=loop, args=(s,), daemon=True).start()
signal.pause()
' "$SOCK_PATH" "$TCP4_PORT" "$TCP6_PORT" >"$TESTDIR/listener.log" 2>&1 &
LISTENER_PID=$!

# Wait for all three listeners to bind.
_ready=0
for _ in $(seq 1 50); do
	if [ -S "$SOCK_PATH" ] \
		&& nc -z 127.0.0.1 "$TCP4_PORT" 2>/dev/null \
		&& nc -z ::1 "$TCP6_PORT" 2>/dev/null; then
		_ready=1
		break
	fi
	sleep 0.1
done
if [ "$_ready" -ne 1 ]; then
	echo "ERROR: host listeners never came up" >&2
	cat "$TESTDIR/listener.log" >&2 || true
	exit 1
fi

echo "=== Localhost + UNIX-socket egress denied, open mode (Darwin) ==="
echo "SOCK_PATH=$SOCK_PATH TCP4=$TCP4_PORT TCP6=$TCP6_PORT"
echo

# Sanity: client tools resolve inside the sandbox. If these fail the deny
# assertions below would be meaningless (a missing binary also exits non-zero).
expect_ok "socat is available" "command -v socat"
expect_ok "curl is available" "command -v curl"

# Real assertions: each connect() must be denied.
#
# TCP probes use bash /dev/tcp — it exercises connect() only, with no read or
# write, so the exit code is the pure kernel verdict on the connect syscall.
# socat would conflate "sandbox denied connect" with "listener closed after
# accept" (the latter is what our python listener does), producing false
# positives. IPv6 uses the unbracketed form — bash's /dev/tcp path parser
# rejects "[::1]" as a hostname.
#
# UNIX-socket probe still uses socat: AF_UNIX has no /dev/tcp equivalent,
# and socat distinguishes "connect denied" (rc=1, "Operation not permitted")
# from a successful connect (rc=0) correctly here.
expect_fail "cannot connect to host loopback 127.0.0.1 (TCP/v4)" \
	"exec 3<>/dev/tcp/127.0.0.1/$TCP4_PORT"

expect_fail "cannot connect to host loopback ::1 (TCP/v6)" \
	"exec 3<>/dev/tcp/::1/$TCP6_PORT"

expect_fail "cannot connect to host UNIX socket" \
	"printf x | socat -t 1 - UNIX-CONNECT:'$SOCK_PATH'"

# Open mode promises the public internet works — sanity-check that.
expect_ok "public internet reachable (http://example.com)" \
	"curl -s --retry 3 --retry-delay 2 --retry-connrefused --max-time 10 -o /dev/null http://example.com"

print_results
exit_status
