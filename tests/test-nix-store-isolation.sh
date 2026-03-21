#!/usr/bin/env bash
# Test that nix store paths outside the closure are not accessible
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OS=$(uname)

source "$SCRIPT_DIR/lib.sh"

SANDBOXED=$(nix-build --no-out-link "$SCRIPT_DIR/nix-store-isolation.nix")
SHELL="$SANDBOXED/bin/sandboxed-bash-store-isolation"

run() { "$SHELL" --norc --noprofile -c "$@" >/dev/null 2>&1; }
run_output() { "$SHELL" --norc --noprofile -c "$@" 2>/dev/null; }

TESTDIR=$(mktemp -d)
trap 'rm -rf "$TESTDIR"' EXIT
cd "$TESTDIR"

echo "=== Nix store isolation tests ($OS) ==="
echo

# --- Allowed packages should work ---
expect_ok "can run allowed binary (ls)" "ls / > /dev/null"
expect_ok "can run allowed binary (echo)" "echo hello"

# --- Disallowed package should be inaccessible ---
expect_fail "cannot execute disallowed store path" '"$DISALLOWED_STORE_PATH/bin/hello"'

# On Darwin, the nix store must be readable (but not executable) for code signing to work
if [ "$OS" = "Linux" ]; then
  expect_fail "cannot read disallowed store path binary" 'cat "$DISALLOWED_STORE_PATH/bin/hello"'
  expect_fail "cannot list disallowed store path" 'ls "$DISALLOWED_STORE_PATH"'
fi

print_results
exit_status
