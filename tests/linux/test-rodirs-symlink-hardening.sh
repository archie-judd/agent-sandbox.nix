#!/usr/bin/env bash
# Test: a symlink planted inside an roDir pointing to an out-of-bounds host
# path is rejected by the startup scan. Same hardening as for rwDirs in
# tests/linux/test-symlinks.sh — an agent could otherwise plant a symlink
# (e.g. ~/.test-ro-dir/leak -> /etc/shadow) during a session to widen its
# read access on the next startup.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

source "$SCRIPT_DIR/../lib.sh"

SANDBOXED=$(build_fixture ro-binds-sandbox.nix)
SHELL="$SANDBOXED/bin/sandboxed-bash-ro-binds"

run() { "$SHELL" --norc --noprofile -c "$1" >/dev/null 2>&1; }

TESTDIR_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)/.tmp-test"
mkdir -p "$TESTDIR_ROOT"
TESTDIR=$(mktemp -d "$TESTDIR_ROOT/rodirs-symlink-hardening.XXXXXX")
# OOB_FILE lives in $HOME but outside the repo and all other bound prefixes.
OOB_FILE=$(mktemp "$HOME/.sandbox-ro-test-oob.XXXXXX")
echo "out-of-bounds content" > "$OOB_FILE"
trap 'rm -rf "$TESTDIR" "$HOME/.test-ro-dir" "$HOME/.test-ro-file" "$OOB_FILE"' EXIT
cd "$TESTDIR"

# Pre-create the declared roDir / roFile, then plant a symlink to the OOB
# path inside the roDir.
mkdir -p "$HOME/.test-ro-dir"
touch "$HOME/.test-ro-file"
ln -sfn "$OOB_FILE" "$HOME/.test-ro-dir/link-to-oob"

echo "=== roDir symlink hardening (Linux) ==="
echo

expect_fail run "roDir symlink to OOB path: target not accessible (security)" "cat $OOB_FILE"
expect_ok run  "roDir symlink to OOB path: sandbox still starts cleanly" "echo ok"

print_results
exit_status
