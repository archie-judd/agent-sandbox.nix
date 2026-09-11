#!/usr/bin/env bash
# Test: AF_UNIX sockets are denied by default on Linux, via the seccomp
# filter bubblewrap loads from the descriptor apply_network_rules leaves
# open (launcher/lib/launch_config/linux/seccomp.py).
#
# The precise assertions matter: socket(AF_UNIX, ...) must fail with EPERM
# for every type, while socketpair(2) — anonymous pairs that reach nothing
# on the host, which runtimes use for internal IPC — and AF_INET sockets
# must keep working. The flag-on behaviour is covered by
# test-unix-socket-allowed.sh.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

source "$SCRIPT_DIR/../lib.sh"

SANDBOXED=$(build_fixture unix-socket-default-sandbox.nix)
SHELL_BIN="$SANDBOXED/bin/sandboxed-bash"

run() { "$SHELL_BIN" --norc --noprofile -c "$1" >/dev/null 2>&1; }

echo "=== UNIX sockets denied by default (Linux) ==="
echo

# Sanity: the probe tool resolves inside the sandbox. If this fails, the
# denial assertions below are meaningless (a missing binary also exits
# non-zero).
expect_ok run "python3 is available inside the sandbox" "command -v python3"

expect_fail run "socket(AF_UNIX, SOCK_STREAM) is denied" 'python3 -c "
import socket
socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
"'

expect_fail run "socket(AF_UNIX, SOCK_DGRAM) is denied" 'python3 -c "
import socket
socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
"'

# The denial must be EPERM, not a kill: callers probe for AF_UNIX services
# (nscd, syslog) and fall back, and a killed process would turn each probe
# into a crash.
expect_ok run "the denial is EPERM, not a kill" 'python3 -c "
import socket
try:
    socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
except PermissionError:
    pass
else:
    raise SystemExit(1)
"'

expect_ok run "socketpair(AF_UNIX) still works" 'python3 -c "
import socket
a, b = socket.socketpair()
a.sendall(b\"x\")
assert b.recv(1) == b\"x\"
"'

expect_ok run "socket(AF_INET) still works" 'python3 -c "
import socket
socket.socket(socket.AF_INET, socket.SOCK_STREAM).close()
"'

print_results
exit_status
