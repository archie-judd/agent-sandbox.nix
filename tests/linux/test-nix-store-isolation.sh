#!/usr/bin/env bash
# Nix store isolation tests (Linux-specific)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

source "$SCRIPT_DIR/../lib.sh"

SANDBOXED=$(build_fixture nix-store-isolation.nix)
SHELL="$SANDBOXED/bin/sandboxed-bash-store-isolation"

run() { "$SHELL" --norc --noprofile -c "$1" >/dev/null 2>&1; }

TESTDIR_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)/.tmp-test"
mkdir -p "$TESTDIR_ROOT"
TESTDIR=$(mktemp -d "$TESTDIR_ROOT/store-isolation-linux.XXXXXX")
trap 'rm -rf "$TESTDIR"' EXIT
cd "$TESTDIR"

echo "=== Nix store isolation tests (Linux) ==="
echo

# On Linux, nix store paths outside the closure should not be readable or listable
expect_fail run "cannot read disallowed store path binary" 'cat "$DISALLOWED_STORE_PATH/bin/hello"'
expect_fail run "cannot list disallowed store path" 'ls "$DISALLOWED_STORE_PATH"'

print_results
exit_status
