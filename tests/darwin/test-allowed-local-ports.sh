#!/usr/bin/env bash
# Test: allowedLocalPorts allows explicitly configured host-local TCP ports
# while preserving the default block for neighboring host-local TCP ports.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEST_CWD="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$SCRIPT_DIR/../lib.sh"

SANDBOXED=$(nix-build --no-out-link "$SCRIPT_DIR/../fixtures/allowed-local-ports.nix")
SHELL="$SANDBOXED/bin/sandboxed-bash-allowed-local-ports"

HOST_PYTHON3=$(nix-build --no-out-link -E '(import <nixpkgs> {}).python3Minimal')/bin/python3

run() { (cd "$TEST_CWD" && "$SHELL" --norc --noprofile -c "$@") >/dev/null 2>&1; }

ALLOWED_PORT=18934
DENIED_PORT=18935

TESTDIR_ROOT="$TEST_CWD/.tmp-test"
mkdir -p "$TESTDIR_ROOT"
TESTDIR=$(mktemp -d "$TESTDIR_ROOT/allowed-local-ports-darwin.XXXXXX")

SERVER_PID=""
cleanup() {
	if [ -n "$SERVER_PID" ]; then
		kill "$SERVER_PID" 2>/dev/null || true
		wait "$SERVER_PID" 2>/dev/null || true
	fi
	rm -rf "$TESTDIR"
}
trap cleanup EXIT

for port in "$ALLOWED_PORT" "$DENIED_PORT"; do
	if ! "$HOST_PYTHON3" -c 'import socket, sys; s = socket.socket(); s.bind(("127.0.0.1", int(sys.argv[1])))' "$port" 2>/dev/null; then
		echo "FAIL: test setup — 127.0.0.1:$port already in use" >&2
		exit 1
	fi
done

echo "=== allowedLocalPorts (Darwin) ==="
echo "ALLOWED_PORT=$ALLOWED_PORT DENIED_PORT=$DENIED_PORT"
echo

expect_ok "curl is available" "command -v curl"
expect_ok "python3 is available" "command -v python3"

expect_status "can reach service started inside same sandbox on allowed port" 0 \
	"python3 '$SCRIPT_DIR/../helpers/inside-http-loopback.py' '$ALLOWED_PORT'"

"$HOST_PYTHON3" -c '
import signal, socket, sys, threading

sockets = []
for port in [int(p) for p in sys.argv[1:]]:
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("127.0.0.1", port))
    s.listen(8)
    sockets.append(s)

sys.stdout.write("READY\n"); sys.stdout.flush()

def serve(s):
    while True:
        try:
            c, _ = s.accept()
            try:
                c.recv(1024)
                c.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok")
            finally:
                c.close()
        except Exception:
            break

for s in sockets:
    threading.Thread(target=serve, args=(s,), daemon=True).start()
signal.pause()
' "$ALLOWED_PORT" "$DENIED_PORT" >"$TESTDIR/server.log" 2>&1 &
SERVER_PID=$!

_ready=0
for _ in $(seq 1 50); do
	if grep -q '^READY$' "$TESTDIR/server.log" 2>/dev/null; then
		_ready=1
		break
	fi
	sleep 0.1
done
if [ "$_ready" -ne 1 ]; then
	echo "ERROR: host HTTP servers never came up" >&2
	cat "$TESTDIR/server.log" >&2 || true
	exit 1
fi

expect_ok "can reach allowed host-local TCP port" \
	"curl -sf --noproxy '*' --max-time 3 http://127.0.0.1:$ALLOWED_PORT/"

expect_fail "cannot reach non-allowed host-local TCP port" \
	"curl -sf --noproxy '*' --max-time 3 http://127.0.0.1:$DENIED_PORT/"

print_results
exit_status
