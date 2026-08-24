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
trap 'rm -rf "$TESTDIR"' EXIT
cd "$TESTDIR"

echo "=== Nix support tests (Linux) ==="
echo

run_nix_support() { "$NIX_SUPPORT_SHELL" --norc --noprofile -c "$1" >/dev/null 2>&1; }

expect_ok run_nix_support "non-closure store path is readable with allowNix" \
    'cat "$NON_CLOSURE_STORE_PATH/bin/hello" >/dev/null'

expect_ok run_nix_support "daemon socket is visible with allowNix" \
    '[ -S "$NIX_DAEMON_SOCKET_PATH" ]'

run_store_isolation() { "$STORE_ISOLATION_SHELL" --norc --noprofile -c "$1" >/dev/null 2>&1; }

expect_fail run_store_isolation "non-closure store path is not readable without allowNix" \
    'cat "$DISALLOWED_STORE_PATH/bin/hello" >/dev/null'

expect_fail run_store_isolation "daemon socket is not visible without allowNix" \
    '[ -e /nix/var/nix/daemon-socket/socket ]'

print_results
exit_status
