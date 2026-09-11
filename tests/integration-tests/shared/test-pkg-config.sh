#!/usr/bin/env bash
# PKG_CONFIG_PATH is built from allowedPackages (shared across platforms)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

source "$SCRIPT_DIR/../lib.sh"

SANDBOXED=$(build_fixture pkg-config.nix)
SHELL="$SANDBOXED/bin/sandboxed-bash-pkg-config"

run() { "$SHELL" --norc --noprofile -c "$1" >/dev/null 2>&1; }

TESTDIR_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)/.tmp-test"
mkdir -p "$TESTDIR_ROOT"
TESTDIR=$(mktemp -d "$TESTDIR_ROOT/pkg-config.XXXXXX")
trap 'rm -rf "$TESTDIR"' EXIT
cd "$TESTDIR"

echo "=== pkg-config tests (shared) ==="
echo

expect_ok run "PKG_CONFIG_PATH is set" '[ -n "$PKG_CONFIG_PATH" ]'

expect_ok run "finds a .pc file in lib/pkgconfig" "pkg-config --exists libffi"
expect_ok run "finds a .pc file in share/pkgconfig" "pkg-config --exists zlib"
expect_ok run "finds a .pc file installed only to share/pkgconfig" \
	"pkg-config --exists sandbox-share-only"
expect_ok run "reads its version" \
	'[ "$(pkg-config --modversion sandbox-share-only)" = "1.0" ]'

expect_ok run "prints flags for a lib/pkgconfig package" "pkg-config --cflags --libs libffi"
expect_ok run "its include dir is readable" \
	'd=$(pkg-config --cflags-only-I libffi); d=${d#-I}; [ -n "$d" ] && [ -d "$d" ]'
expect_ok run "prints flags for a share/pkgconfig package" "pkg-config --cflags --libs zlib"
expect_ok run "its include dir is readable" \
	'd=$(pkg-config --cflags-only-I zlib); d=${d#-I}; [ -n "$d" ] && [ -d "$d" ]'
expect_ok run "the lib dir it names is readable" \
	'for f in $(pkg-config --libs-only-L zlib); do [ -d "${f#-L}" ] || exit 1; done'

expect_fail run "does not find a package outside allowedPackages" "pkg-config --exists openssl"

print_results
exit_status
