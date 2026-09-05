#!/usr/bin/env bash
# Test: with allowUnixSockets = true, no seccomp filter is applied on Linux,
# and socket reachability follows the mount namespace: bind works wherever
# the path is writable (the launch directory, declared rwDirs), and connect
# works wherever the socket is visible — including read-only binds, because
# a read-only mount blocks inode creation but exempts connect() as a
# special-file operation. That split is what the darwin profile mirrors, so
# these assertions are the parity contract. The default (flag off) is
# covered by test-unix-socket-default-deny.sh.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

source "$SCRIPT_DIR/../lib.sh"

SANDBOXED=$(build_fixture unix-socket-allowed-sandbox.nix)
SANDBOXED_DECL=$(build_fixture unix-socket-allowed-sandbox.nix --arg withDeclaredPaths true)

# Host-side python3 for the listeners the connect assertions dial.
HOST_PYTHON3=$(build_host_pkg python3Minimal)/bin/python3

# Short /tmp paths throughout: sun_path is ~108 bytes on Linux, and a CI
# checkout prefix can push a socket path inside the repo past it — see the
# darwin twin of this file.
TESTDIR=$(mktemp -d /tmp/uxsock.XXXXXX)
RW_DIR=$(mktemp -d /tmp/uxsock-rw.XXXXXX)
RO_DIR=$(mktemp -d /tmp/uxsock-ro.XXXXXX)
RO_FILE_DIR=$(mktemp -d /tmp/uxsock-rof.XXXXXX)
RO_FILE="$RO_FILE_DIR/host.sock"

# A git repo launched from a subdirectory: the repo root is ro-bound, so
# per the ro rule it must allow connect and refuse bind.
REPO=$(mktemp -d /tmp/uxsock-git.XXXXXX)
git init -q "$REPO"
mkdir -p "$REPO/sub"

LISTENER_PIDS=""
cleanup() {
	if [ -n "$LISTENER_PIDS" ]; then
		# shellcheck disable=SC2086 # word-splitting the pid list is the point
		kill $LISTENER_PIDS 2>/dev/null || true
		# shellcheck disable=SC2086
		wait $LISTENER_PIDS 2>/dev/null || true
	fi
	rm -rf "$TESTDIR" "$RW_DIR" "$RO_DIR" "$RO_FILE_DIR" "$REPO"
}
trap cleanup EXIT

# start_listener <socket-path> <logfile> — a host-side listener that actually
# accept()s. Refuses over-long paths loudly: past sun_path, bind() fails no
# matter what the sandbox allows, and an expect_fail against the socket would
# pass for the wrong reason. Drains each connection to EOF before closing,
# same as the darwin twin: the assertions here connect() without writing, but
# any future byte-sending client would race an immediate close — on Linux a
# close with unread data resets the connection, failing the client every time.
start_listener() {
	local sock_path="$1" logfile="$2"
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
            while c.recv(4096):
                pass
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

# One listener inside the declared roDir, one AT the declared roFile path —
# the roFile must exist (and be the socket) before any launch.
RO_DIR_SOCK="$RO_DIR/listener.sock"
start_listener "$RO_DIR_SOCK" "$TESTDIR/listener-rodir.log"
start_listener "$RO_FILE" "$TESTDIR/listener-rofile.log"

# Host listener at the repo root, outside the launch subdirectory.
REPO_SOCK="$REPO/root.sock"
start_listener "$REPO_SOCK" "$TESTDIR/listener-repo.log"

# Launch from TESTDIR so the socket lands in a scratch launch directory
# rather than the repo.
run() {
	(cd "$TESTDIR" && "$SANDBOXED/bin/sandboxed-bash" --norc --noprofile -c "$1") >/dev/null 2>&1
}
run_declared() {
	(cd "$TESTDIR" && UNIX_TEST_RW="$RW_DIR" UNIX_TEST_RO="$RO_DIR" \
		UNIX_TEST_RO_FILE="$RO_FILE" \
		"$SANDBOXED_DECL/bin/sandboxed-bash" --norc --noprofile -c "$1") >/dev/null 2>&1
}
run_repo() {
	(cd "$REPO/sub" && "$SANDBOXED/bin/sandboxed-bash" --norc --noprofile -c "$1") >/dev/null 2>&1
}

echo "=== UNIX sockets allowed with allowUnixSockets (Linux) ==="
echo

expect_ok run "python3 is available inside the sandbox" "command -v python3"

# bind(), listen(), connect() and a byte each way, all on a socket in the
# CWD. One process plays both ends: the assertion is about the seccomp
# filter's absence, not about concurrency.
expect_ok run "bind+connect a socket in CWD" 'python3 -c "
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

expect_ok run "socketpair(AF_UNIX) works" 'python3 -c "
import socket
a, b = socket.socketpair()
a.sendall(b\"x\")
assert b.recv(1) == b\"x\"
"'

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
expect_ok run_declared "can connect() to a socket inside a declared roDir" "python3 -c \"
import socket
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect('$RO_DIR_SOCK')
\""
expect_ok run_declared "can connect() to a socket declared as roFile" "python3 -c \"
import socket
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect('$RO_FILE')
\""

# Launching from a repo subdirectory: the ro-bound repo root follows the ro
# rule — connect works, bind does not.
expect_ok run_repo "can connect() to a socket at the repo root" "python3 -c \"
import socket
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect('$REPO_SOCK')
\""
expect_fail run_repo "cannot bind() at the repo root" "python3 -c \"
import socket
socket.socket(socket.AF_UNIX, socket.SOCK_STREAM).bind('$REPO/deny.sock')
\""

print_results
exit_status
