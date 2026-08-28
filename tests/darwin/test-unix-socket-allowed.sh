#!/usr/bin/env bash
# Test: with allowUnixSockets = true, AF_UNIX sockets work inside the
# directories the sandbox can write, and host sockets outside them stay
# unreachable. Both network modes are exercised, because the allows work by
# different mechanisms: additive over deny-default in filtered mode,
# outranking the blanket unix-socket deny by last-match in open mode. A
# third variant asserts the ro semantics inside the writable scope: connect
# works, bind is denied (issue #84). Flag-off behaviour is covered by
# test-unix-socket-egress-denied.sh.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

source "$SCRIPT_DIR/../lib.sh"

SANDBOXED_FILTERED=$(build_fixture unix-socket-allowed-sandbox.nix)
SANDBOXED_OPEN=$(build_fixture unix-socket-allowed-sandbox.nix --arg open true)
SANDBOXED_NESTED=$(build_fixture unix-socket-allowed-sandbox.nix --arg nestedRoDir true)
SANDBOXED_DECL=$(build_fixture unix-socket-allowed-sandbox.nix --arg withDeclaredPaths true)

# Host-side python3 from nixpkgs, for the UNIX-socket listeners below.
# /usr/bin/python3 on macOS is a Command Line Tools stub that isn't safe
# to depend on in CI; nix-provided python3 is reproducible.
HOST_PYTHON3=$(build_host_pkg python3Minimal)/bin/python3

# Under /private/tmp rather than the checkout's .tmp-test: sun_path is ~104
# bytes on macOS, and on the CI runner the checkout prefix alone pushes a
# socket path inside .tmp-test past it — bind() fails with "AF_UNIX path too
# long" before any assertion runs. Every socket this file touches lives under
# a path minted here, so the prefix has to stay short.
TESTDIR=$(mktemp -d /private/tmp/uxsock.XXXXXX)
# The declared "$PWD/nested-ro" roDir must exist before any nested launch.
mkdir -p "$TESTDIR/nested-ro"

# Launch from TESTDIR so the launch directory — the CWD the seatbelt scope
# covers — is a short scratch directory rather than the repo.
run_filtered() {
	(cd "$TESTDIR" && "$SANDBOXED_FILTERED/bin/sandboxed-bash" --norc --noprofile -c "$1") >/dev/null 2>&1
}
run_open() {
	(cd "$TESTDIR" && "$SANDBOXED_OPEN/bin/sandboxed-bash" --norc --noprofile -c "$1") >/dev/null 2>&1
}
run_nested() {
	(cd "$TESTDIR" && "$SANDBOXED_NESTED/bin/sandboxed-bash" --norc --noprofile -c "$1") >/dev/null 2>&1
}

# Declared paths OUTSIDE the launch dir, for the per-mode semantics: rw
# grants bind + connect, ro grants connect only. All short /private/tmp
# paths — see the sun_path note above.
RW_DIR=$(mktemp -d /private/tmp/uxsock-rw.XXXXXX)
RO_DIR=$(mktemp -d /private/tmp/uxsock-ro.XXXXXX)
RO_FILE_DIR=$(mktemp -d /private/tmp/uxsock-rof.XXXXXX)
RO_FILE="$RO_FILE_DIR/host.sock"

# A git repo launched from a subdirectory: the repo root is read-only
# visible, so per the ro rule it must allow connect and refuse bind.
REPO=$(mktemp -d /private/tmp/uxsock-git.XXXXXX)
git init -q "$REPO"
mkdir -p "$REPO/sub"
run_repo() {
	(cd "$REPO/sub" && "$SANDBOXED_FILTERED/bin/sandboxed-bash" --norc --noprofile -c "$1") >/dev/null 2>&1
}
run_declared() {
	(cd "$TESTDIR" && UNIX_TEST_RW="$RW_DIR" UNIX_TEST_RO="$RO_DIR" \
		UNIX_TEST_RO_FILE="$RO_FILE" \
		"$SANDBOXED_DECL/bin/sandboxed-bash" --norc --noprofile -c "$1") >/dev/null 2>&1
}

# bind(), listen(), connect() and a byte each way, all on a socket in the CWD.
# One process plays both ends: the assertion is about the seatbelt rules, not
# about concurrency.
IN_CWD_CHECK='python3 -c "
import socket, os
path = \"check.sock\"
try:
    os.unlink(path)
except FileNotFoundError:
    pass
srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
srv.bind(path)
srv.listen(1)
cli = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
cli.connect(path)
conn, _ = srv.accept()
cli.sendall(b\"x\")
assert conn.recv(1) == b\"x\"
"'

LISTENER_PIDS=""
cleanup() {
	if [ -n "$LISTENER_PIDS" ]; then
		# shellcheck disable=SC2086 # word-splitting the pid list is the point
		kill $LISTENER_PIDS 2>/dev/null || true
		# shellcheck disable=SC2086
		wait $LISTENER_PIDS 2>/dev/null || true
	fi
	rm -rf "$SOCK_DIR" "$TESTDIR" "$RW_DIR" "$RO_DIR" "$RO_FILE_DIR" "$REPO"
}
trap cleanup EXIT

# start_listener <socket-path> <logfile> — a host-side (unsandboxed)
# UNIX-socket listener that actually accept()s, so a successful connect()
# would observably complete, not just queue in the kernel backlog.
start_listener() {
	local sock_path="$1" logfile="$2"
	# Fail loudly instead of mysteriously: past this length bind() fails with
	# "AF_UNIX path too long" no matter what the sandbox allows, which also
	# makes every expect_fail against the socket pass for the wrong reason.
	if [ "${#sock_path}" -gt 100 ]; then
		echo "HARNESS ERROR: socket path exceeds sun_path budget (${#sock_path} > 100): $sock_path" >&2
		return 1
	fi
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
' "$sock_path" >"$logfile" 2>&1 &
	LISTENER_PIDS="$LISTENER_PIDS $!"
	local _i
	for _i in $(seq 1 50); do
		[ -S "$sock_path" ] && return 0
		sleep 0.1
	done
	echo "ERROR: host listener never bound $sock_path" >&2
	cat "$logfile" >&2 || true
	return 1
}

# Host listener OUTSIDE the writable-dir scope, in a directory the profile
# grants nothing on. A successful connect() would mean the socket rules leak
# beyond CWD + rwDirs. The listeners under the launch directory and at the
# repo root carry the sharper form of this: those paths are readable, so a
# denial there can only come from the socket scope.
SOCK_DIR=$(mktemp -d "/private/tmp/sandbox-unix-allowed.XXXXXX")
SOCK_PATH="$SOCK_DIR/listener.sock"
start_listener "$SOCK_PATH" "$TESTDIR/listener-outside.log"

# Host listener INSIDE the nested roDir, for the nested-scope assertions.
NESTED_SOCK="$TESTDIR/nested-ro/listener.sock"
start_listener "$NESTED_SOCK" "$TESTDIR/listener-nested.log"

# Host listeners for the ro semantics: one inside the declared roDir, and
# one AT the declared roFile path — the roFile must exist (and be the
# socket) before any launch of the declared variant.
RO_DIR_SOCK="$RO_DIR/listener.sock"
start_listener "$RO_DIR_SOCK" "$TESTDIR/listener-rodir.log"
start_listener "$RO_FILE" "$TESTDIR/listener-rofile.log"

# Host listener at the repo root, outside the launch subdirectory.
REPO_SOCK="$REPO/root.sock"
start_listener "$REPO_SOCK" "$TESTDIR/listener-repo.log"

echo "=== UNIX sockets allowed in writable dirs (Darwin) ==="
echo "TESTDIR=$TESTDIR"
echo "SOCK_PATH=$SOCK_PATH"
echo

expect_ok run_filtered "socat binary is available inside the sandbox" "command -v socat"

expect_ok run_filtered "filtered: bind+connect a socket in CWD" "$IN_CWD_CHECK"
expect_ok run_open "open: bind+connect a socket in CWD" "$IN_CWD_CHECK"

# The scope must not leak: a host socket outside CWD + rwDirs stays denied
# even with the flag on. printf sends a byte so socat really connect()s.
expect_fail run_filtered "filtered: cannot connect() to host socket outside scope" \
	"printf x | socat -t 1 - UNIX-CONNECT:'$SOCK_PATH'"
expect_fail run_open "open: cannot connect() to host socket outside scope" \
	"printf x | socat -t 1 - UNIX-CONNECT:'$SOCK_PATH'"

# A declared read-only directory nested inside the CWD: bind is denied back
# out of the enclosing subpath allow, connect works per the ro rule — while
# the rest of the CWD keeps working.
expect_ok run_nested "nested roDir declared: bind+connect in CWD still works" "$IN_CWD_CHECK"
expect_fail run_nested "cannot bind() inside a nested roDir" 'python3 -c "
import socket
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.bind(\"nested-ro/deny.sock\")
"'
expect_ok run_nested "can connect() to a socket inside a nested roDir (ro grants connect)" \
	"printf x | socat -t 1 - UNIX-CONNECT:'$NESTED_SOCK'"

# Declared paths outside the launch dir: rw grants bind + connect, ro
# grants connect only — for a directory and for a single declared file.
expect_ok run_declared "bind+connect a socket in a declared rwDir" "python3 -c \"
import socket, os
path = '$RW_DIR/rw.sock'
try:
    os.unlink(path)
except FileNotFoundError:
    pass
srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
srv.bind(path)
srv.listen(1)
cli = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
cli.connect(path)
srv.accept()
\""
expect_fail run_declared "cannot bind() inside a declared roDir" "python3 -c \"
import socket
socket.socket(socket.AF_UNIX, socket.SOCK_STREAM).bind('$RO_DIR/deny.sock')
\""
expect_ok run_declared "can connect() to a socket inside a declared roDir" \
	"printf x | socat -t 1 - UNIX-CONNECT:'$RO_DIR_SOCK'"
expect_ok run_declared "can connect() to a socket declared as roFile" \
	"printf x | socat -t 1 - UNIX-CONNECT:'$RO_FILE'"

# Launching from a repo subdirectory: the read-only-visible repo root
# follows the ro rule — connect works, bind does not.
expect_ok run_repo "can connect() to a socket at the repo root" \
	"printf x | socat -t 1 - UNIX-CONNECT:'$REPO_SOCK'"
expect_fail run_repo "cannot bind() at the repo root" "python3 -c \"
import socket
socket.socket(socket.AF_UNIX, socket.SOCK_STREAM).bind('$REPO/deny.sock')
\""

print_results
exit_status
