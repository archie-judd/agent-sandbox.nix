#!/usr/bin/env bash
# Test: with allowedDomains omitted (open network mode), the sandbox can reach
# the public internet but cannot reach host loopback services. On Linux, host
# loopback is accessible from inside the pasta namespace via the pasta gateway
# (10.0.2.2 → 127.0.0.1 on the host). The open-mode nftables rule drops all
# traffic to 10.0.2.2, blocking that path.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEST_CWD="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$SCRIPT_DIR/../lib.sh"

SANDBOXED=$(nix-build --no-out-link "$SCRIPT_DIR/../fixtures/network-unrestricted.nix")
SHELL="$SANDBOXED/bin/sandboxed-bash-unres"

HOST_PYTHON3=$(nix-build --no-out-link -E '(import <nixpkgs> {}).python3Minimal')/bin/python3

run() { (cd "$TEST_CWD" && "$SHELL" --norc --noprofile -c "$@") >/dev/null 2>&1; }

# --- Setup ---

TCP4_PORT=18933
INSIDE_PORT=18936

TESTDIR_ROOT="$TEST_CWD/.tmp-test"
mkdir -p "$TESTDIR_ROOT"
TESTDIR=$(mktemp -d "$TESTDIR_ROOT/localhost-denied-unrestricted-linux.XXXXXX")

LISTENER_PID=""
cleanup() {
	if [ -n "$LISTENER_PID" ]; then
		kill "$LISTENER_PID" 2>/dev/null || true
		wait "$LISTENER_PID" 2>/dev/null || true
	fi
	rm -rf "$TESTDIR"
}
trap cleanup EXIT

# Pre-flight: bail if port is already in use.
if bash -c "exec 3<>/dev/tcp/127.0.0.1/$TCP4_PORT" 2>/dev/null; then
	echo "FAIL: test setup — 127.0.0.1:$TCP4_PORT already in use" >&2
	exit 1
fi

"$HOST_PYTHON3" -c '
import socket, sys, signal, threading
p4 = int(sys.argv[1])
t4 = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
t4.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
t4.bind(("127.0.0.1", p4))
t4.listen(8)
sys.stdout.write("READY\n"); sys.stdout.flush()
def loop(s):
    while True:
        try: c, _ = s.accept(); c.close()
        except Exception: break
threading.Thread(target=loop, args=(t4,), daemon=True).start()
signal.pause()
' "$TCP4_PORT" >"$TESTDIR/listener.log" 2>&1 &
LISTENER_PID=$!

# Wait for the listener to bind.
_ready=0
for _ in $(seq 1 50); do
	if bash -c "exec 3<>/dev/tcp/127.0.0.1/$TCP4_PORT" 2>/dev/null; then
		_ready=1
		break
	fi
	sleep 0.1
done
if [ "$_ready" -ne 1 ]; then
	echo "ERROR: host listener never came up" >&2
	cat "$TESTDIR/listener.log" >&2 || true
	exit 1
fi

echo "=== Localhost egress denied, open mode (Linux) ==="
echo "TCP4=$TCP4_PORT (host 127.0.0.1, probed via pasta gateway 10.0.2.2)"
echo "INSIDE_PORT=$INSIDE_PORT"
echo

expect_ok  "curl is available" "command -v curl"
expect_ok  "python3 is available" "command -v python3"

expect_status "can reach service started inside same sandbox on loopback" 0 \
	"python3 '$SCRIPT_DIR/../helpers/inside-http-loopback.py' '$INSIDE_PORT'"

# Host loopback is reachable from inside the pasta namespace via the pasta
# gateway (pasta forwards 10.0.2.2:<port> → 127.0.0.1:<port> on the host).
# The nftables drop rule for 10.0.2.2 must block this. Use curl --max-time
# rather than /dev/tcp: nftables drop is silent (no RST/ICMP), so /dev/tcp
# would hang until the kernel's TCP timeout; curl bounds the wait explicitly.
expect_fail "cannot reach host loopback via pasta gateway (TCP/v4)" \
	"curl -sf --noproxy '*' --max-time 3 http://10.0.2.2:$TCP4_PORT/"

expect_ok "public internet reachable (http://example.com)" \
	"curl -s --retry 3 --retry-delay 2 --retry-connrefused --max-time 10 -o /dev/null http://example.com"

print_results
exit_status
