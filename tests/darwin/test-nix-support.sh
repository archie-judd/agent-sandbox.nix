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
TESTDIR=$(mktemp -d "$TESTDIR_ROOT/nix-support-darwin.XXXXXX")
trap 'rm -rf "$TESTDIR"' EXIT
cd "$TESTDIR"

echo "=== Nix support tests (Darwin) ==="
echo

run_nix_support() { "$NIX_SUPPORT_SHELL" --norc --noprofile -c "$1" >/dev/null 2>&1; }

# allowNix grants read and exec over the whole store, not just the closure: the
# daemon builds results after the sandbox starts, and their paths are not
# knowable when the profile is written.
expect_ok run_nix_support "non-closure store path is readable with allowNix" \
    'cat "$NON_CLOSURE_STORE_PATH/bin/hello"'

expect_ok run_nix_support "non-closure store path is exec-able with allowNix" \
    '"$NON_CLOSURE_STORE_PATH/bin/hello"'

# Daemon socket reachability: stat on /nix/var must succeed for the client to
# locate the socket. /etc/nix stat must succeed for the flake CLI to resolve
# indirect refs (nix run nixpkgs#...) via the global registry.
expect_ok run_nix_support "/nix/var metadata is accessible with allowNix" \
    '[ -d /nix/var ]'

expect_ok run_nix_support "/etc/nix metadata is accessible with allowNix" \
    '[ -d /etc/nix ]'

run_store_isolation() { "$STORE_ISOLATION_SHELL" --norc --noprofile -c "$1" >/dev/null 2>&1; }

# Same store path, neither readable nor exec-able without allowNix. Reaching it
# takes a grant of its own: membership of the closure, or a symlink in a
# declared path that names it (tests/darwin/test-symlinks.sh).
expect_fail run_store_isolation "non-closure store path is not readable without allowNix" \
    'cat "$DISALLOWED_STORE_PATH/bin/hello"'

expect_fail run_store_isolation "non-closure store path is not exec-able without allowNix" \
    '"$DISALLOWED_STORE_PATH/bin/hello"'

# The store listing itself: stat resolves a path through /nix/store without
# readdir enumerating what the host has built.
expect_fail run_store_isolation "store is not listable without allowNix" \
    'ls /nix/store'

expect_ok run_store_isolation "store stays traversable to closure paths" \
    '[ -d /nix/store ]'

expect_fail run_store_isolation "/nix/var metadata is not accessible without allowNix" \
    '[ -d /nix/var ]'

expect_fail run_store_isolation "/etc/nix metadata is not accessible without allowNix" \
    '[ -d /etc/nix ]'

print_results
exit_status
