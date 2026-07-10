#!/usr/bin/env bash
# Test: allowedLocalPorts = null allows all host-local TCP ports on Linux.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEST_CWD="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$SCRIPT_DIR/../lib.sh"

SANDBOXED=$(nix-build --no-out-link --arg ports null "$SCRIPT_DIR/../fixtures/allowed-local-ports.nix")
SHELL="$SANDBOXED/bin/sandboxed-bash-allowed-local-ports"

HOST_PYTHON3=$(nix-build --no-out-link -E '(import <nixpkgs> {}).python3Minimal')/bin/python3

run() { (cd "$TEST_CWD" && "$SHELL" --norc --noprofile -c "$@") >/dev/null 2>&1; }

PORT_A=18937
PORT_B=18938

TESTDIR_ROOT="$TEST_CWD/.tmp-test"
mkdir -p "$TESTDIR_ROOT"
TESTDIR=$(mktemp -d "$TESTDIR_ROOT/allowed-local-ports-null-linux.XXXXXX")

SERVER_PID=""
cleanup() {
	if [ -n "$SERVER_PID" ]; then
		kill "$SERVER_PID" 2>/dev/null || true
		wait "$SERVER_PID" 2>/dev/null || true
	fi
	rm -rf "$TESTDIR"
}
trap cleanup EXIT

for port in "$PORT_A" "$PORT_B"; do
	if ! "$HOST_PYTHON3" -c 'import socket, sys; s = socket.socket(); s.bind(("127.0.0.1", int(sys.argv[1])))' "$port" 2>/dev/null; then
		echo "FAIL: test setup — 127.0.0.1:$port already in use" >&2
		exit 1
	fi
done

echo "=== allowedLocalPorts = null (Linux) ==="
echo "PORT_A=$PORT_A PORT_B=$PORT_B"
echo

expect_ok "curl is available" "command -v curl"

"$HOST_PYTHON3" "$SCRIPT_DIR/../helpers/host-http-loopback.py" \
	"$PORT_A" "$PORT_B" >"$TESTDIR/server.log" 2>&1 &
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

expect_ok "can reach first host-local TCP port through localhost" \
	"curl -sf --noproxy '*' --max-time 3 http://localhost:$PORT_A/"

expect_ok "can reach second host-local TCP port through localhost" \
	"curl -sf --noproxy '*' --max-time 3 http://localhost:$PORT_B/"

expect_ok "can reach first host-local TCP port through pasta gateway" \
	"curl -sf --noproxy '*' --max-time 3 http://10.0.2.2:$PORT_A/"

expect_ok "can reach second host-local TCP port through pasta gateway" \
	"curl -sf --noproxy '*' --max-time 3 http://10.0.2.2:$PORT_B/"

print_results
exit_status
