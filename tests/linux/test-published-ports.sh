#!/usr/bin/env bash
# Test: publishedPorts forwards declared host TCP ports into the sandbox
# (pasta -t, spliced over the namespace loopback) while undeclared neighbors
# stay unbound on the host.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEST_CWD="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$SCRIPT_DIR/../lib.sh"

GRANTED_PORT=18944
UNDECLARED_PORT=18945
NONLOCAL_PORT=18946

SANDBOXED=$(build_fixture published-ports.nix \
	--arg publishedPorts "[ { port = $GRANTED_PORT; bindAddr = \"127.0.0.1\"; } ]")
SHELL_BIN="$SANDBOXED/bin/sandboxed-bash-published-ports"

HOST_PYTHON3=$(build_host_pkg python3Minimal)/bin/python3

# Host-side runner for expect_*: the assertions here are about what the HOST
# can reach, the inverse of the allowed-host-ports test.
run_host() { bash -c "$1" >/dev/null 2>&1; }

host_fetch() {
	"$HOST_PYTHON3" -c '
import sys, urllib.request
body = urllib.request.urlopen(
    "http://%s:%s/" % (sys.argv[1], sys.argv[2]), timeout=3
).read()
sys.exit(0 if body == b"inbound-ok" else 1)
' "$1" "$2"
}

# Polls the log for the server READY marker, then the given address for
# reachability (pasta's host-side bind can trail the in-namespace listen).
# Returns 0 once a fetch succeeds.
await_server() {
	local log="$1" pid="$2" addr="$3" port="$4"
	local _ready=0
	for _ in $(seq 1 100); do
		if grep -q '^READY$' "$log" 2>/dev/null; then
			_ready=1
			break
		fi
		if ! kill -0 "$pid" 2>/dev/null; then
			break
		fi
		sleep 0.2
	done
	if [ "$_ready" -ne 1 ]; then
		echo "ERROR: in-sandbox HTTP server never came up" >&2
		cat "$log" >&2 || true
		return 1
	fi
	for _ in $(seq 1 25); do
		if host_fetch "$addr" "$port" 2>/dev/null; then
			return 0
		fi
		sleep 0.2
	done
	return 1
}

TESTDIR_ROOT="$TEST_CWD/.tmp-test"
mkdir -p "$TESTDIR_ROOT"
TESTDIR=$(mktemp -d "$TESTDIR_ROOT/published-ports-linux.XXXXXX")

SANDBOX_PID=""
SANDBOX_ANY_PID=""
cleanup() {
	for pid in "$SANDBOX_PID" "$SANDBOX_ANY_PID"; do
		if [ -n "$pid" ]; then
			kill "$pid" 2>/dev/null || true
			wait "$pid" 2>/dev/null || true
		fi
	done
	# The sandboxed server tree (pasta/bwrap/python) detaches from the
	# launcher PID; without this it survives the run and squats the port,
	# failing the next run's setup check.
	pkill -f "inside-http-serve.py 0.0.0.0 $GRANTED_PORT" 2>/dev/null || true
	pkill -f "inside-http-serve.py 0.0.0.0 $NONLOCAL_PORT" 2>/dev/null || true
	rm -rf "$TESTDIR"
}
trap cleanup EXIT

for port in "$GRANTED_PORT" "$UNDECLARED_PORT" "$NONLOCAL_PORT"; do
	if ! "$HOST_PYTHON3" -c 'import socket, sys; s = socket.socket(); s.bind(("127.0.0.1", int(sys.argv[1])))' "$port" 2>/dev/null; then
		echo "FAIL: test setup — 127.0.0.1:$port already in use" >&2
		exit 1
	fi
done

echo "=== publishedPorts (Linux) ==="
echo "GRANTED_PORT=$GRANTED_PORT UNDECLARED_PORT=$UNDECLARED_PORT"
echo

# The server binds 0.0.0.0 inside the namespace: pasta's spliced forward
# connects over the namespace loopback, which 0.0.0.0 covers.
(cd "$TEST_CWD" && "$SHELL_BIN" --norc --noprofile -c \
	"python3 '$SCRIPT_DIR/../helpers/inside-http-serve.py' 0.0.0.0 $GRANTED_PORT") \
	>"$TESTDIR/sandbox.log" 2>&1 &
SANDBOX_PID=$!

if await_server "$TESTDIR/sandbox.log" "$SANDBOX_PID" 127.0.0.1 "$GRANTED_PORT"; then
	echo "PASS: host reaches the granted port on 127.0.0.1"
	PASS=$((PASS + 1))
else
	echo "FAIL: host reaches the granted port on 127.0.0.1"
	cat "$TESTDIR/sandbox.log" >&2 || true
	FAIL=$((FAIL + 1))
fi

expect_fail run_host "host cannot reach an undeclared port" \
	"'$HOST_PYTHON3' -c 'import sys, urllib.request; urllib.request.urlopen(\"http://127.0.0.1:$UNDECLARED_PORT/\", timeout=3)'"

# The OUTPUT drop policy is the sole egress enforcement (the default route
# stays: inbound replies to non-local peers need it) — pin that direct
# egress is blocked in this configuration.
run_inside() { "$SHELL_BIN" --norc --noprofile -c "$1" >/dev/null 2>&1; }
expect_fail run_inside "direct egress stays blocked while published ports are granted" \
	"python3 -c 'import socket; s = socket.socket(); s.settimeout(5); s.connect((\"1.1.1.1\", 443))'"

# Non-loopback grant: bindAddr = "0.0.0.0" is reachable on the host's own
# address (the tap-delivery path a container callback takes), and the
# loopback-scoped grant stays loopback-only. Needs a detectable host
# address; skipped otherwise, like test-network.sh's LAN-IP check.
HOST_IP=$(ip -4 route get 1.1.1.1 2>/dev/null | grep -oP 'src \K\S+' || echo "")
if [ -n "$HOST_IP" ]; then
	SANDBOXED_ANY=$(build_fixture published-ports.nix \
		--arg publishedPorts "[ { port = $NONLOCAL_PORT; bindAddr = \"0.0.0.0\"; } ]")
	SHELL_BIN_ANY="$SANDBOXED_ANY/bin/sandboxed-bash-published-ports"
	(cd "$TEST_CWD" && "$SHELL_BIN_ANY" --norc --noprofile -c \
		"python3 '$SCRIPT_DIR/../helpers/inside-http-serve.py' 0.0.0.0 $NONLOCAL_PORT") \
		>"$TESTDIR/sandbox-any.log" 2>&1 &
	SANDBOX_ANY_PID=$!

	if await_server "$TESTDIR/sandbox-any.log" "$SANDBOX_ANY_PID" "$HOST_IP" "$NONLOCAL_PORT"; then
		echo "PASS: host reaches the 0.0.0.0-bound port on its own address ($HOST_IP)"
		PASS=$((PASS + 1))
	else
		echo "FAIL: host reaches the 0.0.0.0-bound port on its own address ($HOST_IP)"
		cat "$TESTDIR/sandbox-any.log" >&2 || true
		FAIL=$((FAIL + 1))
	fi

	expect_fail run_host "loopback-scoped grant is not reachable on the host address" \
		"'$HOST_PYTHON3' -c 'import sys, urllib.request; urllib.request.urlopen(\"http://$HOST_IP:$GRANTED_PORT/\", timeout=3)'"
else
	echo "SKIP: no host IPv4 address detected; skipping non-loopback published-port checks" >&2
fi

print_results
exit_status
