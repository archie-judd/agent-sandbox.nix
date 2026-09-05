#!/usr/bin/env bash
# Tests for the two behaviours that only appear when allowedDomains and
# allowedLocalPorts are set together: the sandbox exempts loopback from the
# proxy, and the proxy records the hosts it allowed as well as the ones it
# blocked.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEST_CWD="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$SCRIPT_DIR/../lib.sh"

echo "=== NO_PROXY and allowed-host logging (shared) ==="
echo

ALLOWED_PORT=18939
HTTPBIN_PORT=18940

for port in "$ALLOWED_PORT" "$HTTPBIN_PORT"; do
	if nc -z 127.0.0.1 "$port" 2>/dev/null; then
		echo "FAIL: test setup — 127.0.0.1:$port already in use" >&2
		exit 1
	fi
done

TESTDIR_ROOT="$TEST_CWD/.tmp-test"
mkdir -p "$TESTDIR_ROOT"
TESTDIR=$(mktemp -d "$TESTDIR_ROOT/no-proxy-local-ports.XXXXXX")

SERVER_PID=""
HTTPBIN_PID=""
cleanup() {
	if [ -n "$SERVER_PID" ]; then
		kill "$SERVER_PID" 2>/dev/null || true
		wait "$SERVER_PID" 2>/dev/null || true
	fi
	if [ -n "$HTTPBIN_PID" ]; then
		kill "$HTTPBIN_PID" 2>/dev/null || true
		wait "$HTTPBIN_PID" 2>/dev/null || true
	fi
	rm -rf "$TESTDIR"
	return 0
}
trap cleanup EXIT

HOST_PYTHON3=$(build_host_pkg python3Minimal)/bin/python3
"$HOST_PYTHON3" "$SCRIPT_DIR/../helpers/host-http-loopback.py" "$ALLOWED_PORT" \
	>"$TESTDIR/server.log" 2>&1 &
SERVER_PID=$!

HTTPBIN_BIN=$(build_host_pkg go-httpbin)/bin/go-httpbin
"$HTTPBIN_BIN" -host 127.0.0.1 -port "$HTTPBIN_PORT" >"$TESTDIR/httpbin.log" 2>&1 &
HTTPBIN_PID=$!

wait_for_port() {
	local port="$1"
	for _ in $(seq 1 50); do
		if nc -z 127.0.0.1 "$port" 2>/dev/null; then
			return 0
		fi
		sleep 0.2
	done
	echo "FAIL: test setup — nothing came up on 127.0.0.1:$port" >&2
	exit 1
}
wait_for_port "$ALLOWED_PORT"
wait_for_port "$HTTPBIN_PORT"

SANDBOXED=$(build_fixture local-ports-with-domains.nix --argstr httpbinPort "$HTTPBIN_PORT")
SHELL_BIN="$SANDBOXED/bin/sandboxed-bash-local-ports-domains"

run() {
	(cd "$TEST_CWD" && "$SHELL_BIN" --norc --noprofile -c "$1") >/dev/null 2>&1
}

# Every launch creates its own session directory, so the shared root ends up
# holding one per run. A run whose proxy.log is asserted on gets a root to
# itself, where that log is the only one there.
run_in() {
	local subdir="$1" command="$2"
	(cd "$TEST_CWD" && AGENT_SANDBOX_SESSIONS_ROOT="$AGENT_SANDBOX_SESSIONS_ROOT/$subdir" \
		"$SHELL_BIN" --norc --noprofile -c "$command") >/dev/null 2>&1
}

# expect_ok hands the runner exactly one argument, so each isolated root needs
# a runner of its own.
run_loopback() { run_in loopback "$1"; }
run_allowed_domain() { run_in allowed-domain "$1"; }
run_blocked_domain() { run_in blocked-domain "$1"; }

# The point of the whole file: curl honours http_proxy and does not exempt
# loopback on its own, so without NO_PROXY this request reaches the proxy,
# which refuses every loopback address, and the open port goes unused.
expect_ok run_loopback "allowed local port reachable without --noproxy" \
	"curl -sf --max-time 10 -o /dev/null http://127.0.0.1:$ALLOWED_PORT/"

expect_ok run "allowed local port reachable by name without --noproxy" \
	"curl -sf --max-time 10 -o /dev/null http://localhost:$ALLOWED_PORT/"

expect_ok run "NO_PROXY is set in the sandbox environment" \
	'test -n "$NO_PROXY" && test -n "$no_proxy"'

expect_ok run "the proxy is still used for domains" \
	'test -n "$HTTP_PROXY"'

expect_ok run_allowed_domain "allowed domain still reachable through the proxy" \
	'curl -sf --max-time 10 -o /dev/null http://httpbin.test/get'

expect_fail run_blocked_domain "blocked domain still denied" \
	'curl -sf --max-time 10 -o /dev/null http://example.com'

proxy_log_in() {
	find "$AGENT_SANDBOX_SESSIONS_ROOT/$1" -mindepth 2 -maxdepth 2 -name proxy.log \
		2>/dev/null | head -1
}

assert_proxy_log_contains() {
	local subdir="$1" desc="$2" needle="$3" log
	log=$(proxy_log_in "$subdir")
	if [ -z "$log" ]; then
		echo "FAIL: $desc (no proxy.log under $subdir)"
		FAIL=$((FAIL + 1))
	elif grep -qF -- "$needle" "$log"; then
		echo "PASS: $desc"
		PASS=$((PASS + 1))
	else
		echo "FAIL: $desc (proxy.log missing: $needle)"
		sed 's/^/    /' "$log"
		FAIL=$((FAIL + 1))
	fi
}

assert_proxy_log_contains allowed-domain "proxy.log records the allowed host" \
	"allowed: httpbin.test"

assert_proxy_log_contains blocked-domain "proxy.log still records the blocked host" \
	"blocked domain: example.com"

# Loopback never reaches the proxy now, so it is absent from that run's log.
# Asserted so a regression that removes NO_PROXY shows up here as well as in
# the reachability tests above. A missing log fails rather than passes, or the
# assertion would hold without ever reading the run it is about.
log=$(proxy_log_in loopback)
if [ -z "$log" ]; then
	echo "FAIL: the loopback run wrote no proxy.log to inspect"
	FAIL=$((FAIL + 1))
elif grep -qF -- "127.0.0.1:$ALLOWED_PORT" "$log"; then
	echo "FAIL: the proxy saw a loopback request it should have been exempted from"
	sed 's/^/    /' "$log"
	FAIL=$((FAIL + 1))
else
	echo "PASS: the proxy never saw the loopback request"
	PASS=$((PASS + 1))
fi

print_results
exit_status
