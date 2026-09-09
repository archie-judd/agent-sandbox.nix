#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"

NIX_SUPPORT=$(build_fixture nix-support.nix)
NIX_SUPPORT_SHELL="$NIX_SUPPORT/bin/sandboxed-bash-nix-support"

STORE_ISOLATION=$(build_fixture nix-store-isolation.nix)
STORE_ISOLATION_SHELL="$STORE_ISOLATION/bin/sandboxed-bash-store-isolation"

TESTDIR_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)/.tmp-test"
mkdir -p "$TESTDIR_ROOT"
TESTDIR=$(mktemp -d "$TESTDIR_ROOT/nix-support-linux.XXXXXX")
# For a daemon socket outside /nix/var, which the /nix/var bind does not
# reach. Under /tmp on purpose: inside the sandbox /tmp is a fresh tmpfs, so
# the only way the assertions below can see it is the bind the launcher adds
# for the socket itself.
SOCKET_DIR=$(mktemp -d /tmp/nix-daemon-socket.XXXXXX)
trap 'rm -rf "$TESTDIR" "$SOCKET_DIR"' EXIT

OUTSIDE_SOCKET="$SOCKET_DIR/socket"
HOST_PYTHON3=$(build_host_pkg python3Minimal)/bin/python3
# The listener exits immediately: the socket inode it leaves behind is all the
# launcher checks and all `[ -S ]` needs.
"$HOST_PYTHON3" -c 'import socket, sys
listener = socket.socket(socket.AF_UNIX)
listener.bind(sys.argv[1])
listener.listen(1)' "$OUTSIDE_SOCKET"
# A neighbour, so the bind can be shown to cover the socket and not the
# directory holding it.
touch "$SOCKET_DIR/host-only"

cd "$TESTDIR"

echo "=== Nix support tests (Linux) ==="
echo

run_nix_support() { "$NIX_SUPPORT_SHELL" --norc --noprofile -c "$1" >/dev/null 2>&1; }

expect_ok run_nix_support "non-closure store path is readable with allowNix" \
    'cat "$NON_CLOSURE_STORE_PATH/bin/hello" >/dev/null'

expect_ok run_nix_support "daemon socket is visible with allowNix" \
    '[ -S "$NIX_DAEMON_SOCKET_PATH" ]'

run_outside_socket() {
    env NIX_DAEMON_SOCKET_PATH="$OUTSIDE_SOCKET" \
        "$NIX_SUPPORT_SHELL" --norc --noprofile -c "$1" >/dev/null 2>&1
}

expect_ok run_outside_socket "daemon socket outside /nix/var is visible too" \
    '[ -S "$NIX_DAEMON_SOCKET_PATH" ]'

expect_fail run_outside_socket "the rest of its directory is not exposed" \
    '[ -e "$(dirname "$NIX_DAEMON_SOCKET_PATH")/host-only" ]'

run_store_isolation() { "$STORE_ISOLATION_SHELL" --norc --noprofile -c "$1" >/dev/null 2>&1; }

expect_fail run_store_isolation "non-closure store path is not readable without allowNix" \
    'cat "$DISALLOWED_STORE_PATH/bin/hello" >/dev/null'

expect_fail run_store_isolation "daemon socket is not visible without allowNix" \
    '[ -e /nix/var/nix/daemon-socket/socket ]'

print_results
exit_status
