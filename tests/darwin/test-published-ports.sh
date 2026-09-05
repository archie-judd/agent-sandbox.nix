#!/usr/bin/env bash
# Test: publishedPorts lets the sandboxed process accept host TCP
# connections on declared ports (direct binds — Darwin has no network
# namespace) while undeclared ports stay unbindable/unreachable.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEST_CWD="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$SCRIPT_DIR/../lib.sh"

GRANTED_PORT=18944
UNDECLARED_PORT=18945

SANDBOXED=$(build_fixture published-ports.nix \
	--arg publishedPorts "[ { port = $GRANTED_PORT; bindAddr = \"127.0.0.1\"; } ]")
SHELL_BIN="$SANDBOXED/bin/sandboxed-bash-published-ports"

HOST_PYTHON3=$(build_host_pkg python3Minimal)/bin/python3

run_host() { bash -c "$1" >/dev/null 2>&1; }

host_fetch() {
	"$HOST_PYTHON3" -c '
import sys, urllib.request
body = urllib.request.urlopen(
    "http://127.0.0.1:%s/" % sys.argv[1], timeout=3
).read()
sys.exit(0 if body == b"inbound-ok" else 1)
' "$1"
}

TESTDIR_ROOT="$TEST_CWD/.tmp-test"
mkdir -p "$TESTDIR_ROOT"
TESTDIR=$(mktemp -d "$TESTDIR_ROOT/published-ports-darwin.XXXXXX")

SANDBOX_PID=""
cleanup() {
	if [ -n "$SANDBOX_PID" ]; then
		kill "$SANDBOX_PID" 2>/dev/null || true
		wait "$SANDBOX_PID" 2>/dev/null || true
	fi
	rm -rf "$TESTDIR"
}
trap cleanup EXIT

for port in "$GRANTED_PORT" "$UNDECLARED_PORT"; do
	if ! "$HOST_PYTHON3" -c 'import socket, sys; s = socket.socket(); s.bind(("127.0.0.1", int(sys.argv[1])))' "$port" 2>/dev/null; then
		echo "FAIL: test setup — 127.0.0.1:$port already in use" >&2
		exit 1
	fi
done

echo "=== publishedPorts (Darwin) ==="
echo "GRANTED_PORT=$GRANTED_PORT UNDECLARED_PORT=$UNDECLARED_PORT"
echo

(cd "$TEST_CWD" && "$SHELL_BIN" --norc --noprofile -c \
	"python3 '$SCRIPT_DIR/../helpers/inside-http-serve.py' 127.0.0.1 $GRANTED_PORT") \
	>"$TESTDIR/sandbox.log" 2>&1 &
SANDBOX_PID=$!

_ready=0
for _ in $(seq 1 100); do
	if grep -q '^READY$' "$TESTDIR/sandbox.log" 2>/dev/null; then
		_ready=1
		break
	fi
	if ! kill -0 "$SANDBOX_PID" 2>/dev/null; then
		break
	fi
	sleep 0.2
done
if [ "$_ready" -ne 1 ]; then
	echo "ERROR: in-sandbox HTTP server never came up" >&2
	cat "$TESTDIR/sandbox.log" >&2 || true
	exit 1
fi

_reachable=1
for _ in $(seq 1 25); do
	if host_fetch "$GRANTED_PORT" 2>/dev/null; then
		_reachable=0
		break
	fi
	sleep 0.2
done

if [ "$_reachable" -eq 0 ]; then
	echo "PASS: host reaches the granted port on 127.0.0.1"
	PASS=$((PASS + 1))
else
	echo "FAIL: host reaches the granted port on 127.0.0.1"
	cat "$TESTDIR/sandbox.log" >&2 || true
	FAIL=$((FAIL + 1))
fi

expect_fail run_host "host cannot reach an undeclared port" \
	"'$HOST_PYTHON3' -c 'import sys, urllib.request; urllib.request.urlopen(\"http://127.0.0.1:$UNDECLARED_PORT/\", timeout=3)'"

print_results
exit_status
