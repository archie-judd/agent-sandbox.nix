#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"

NIX_SUPPORT=$(build_fixture nix-support.nix)
NIX_SUPPORT_SHELL="$NIX_SUPPORT/bin/sandboxed-bash-nix-support"

BASIC=$(build_fixture basic-sandbox.nix)
BASIC_SHELL="$BASIC/bin/sandboxed-bash"

TESTDIR_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)/.tmp-test"
mkdir -p "$TESTDIR_ROOT"
TESTDIR=$(mktemp -d "$TESTDIR_ROOT/nix-support-shared.XXXXXX")
trap 'rm -rf "$TESTDIR"' EXIT
cd "$TESTDIR"

echo "=== Nix support tests (shared) ==="
echo

run_nix_support() { "$NIX_SUPPORT_SHELL" --norc --noprofile -c "$1" >/dev/null 2>&1; }

expect_ok run_nix_support "nix build succeeds with allowNix" \
    'nix build "path:$NIXPKGS_SRC#hello" --no-link'

expect_ok run_nix_support "nix run succeeds with allowNix" \
    'nix run "path:$NIXPKGS_SRC#hello"'

expect_ok run_nix_support "nix develop succeeds with allowNix" \
    'nix develop "path:$NIXPKGS_SRC#hello" -c true'

run_basic() { "$BASIC_SHELL" --norc --noprofile -c "$1" >/dev/null 2>&1; }

expect_fail run_basic "nix build unavailable without allowNix" \
    'nix build nixpkgs#hello --no-link'

expect_fail run_basic "nix run unavailable without allowNix" \
    'nix run nixpkgs#hello'

expect_fail run_basic "nix develop unavailable without allowNix" \
    'nix develop nixpkgs#hello -c true'

print_results
exit_status
