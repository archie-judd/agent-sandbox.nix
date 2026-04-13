#!/usr/bin/env bash
# stateDir/stateFile access and symlink resolution tests (Linux-specific)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

source "$SCRIPT_DIR/../lib.sh"

SANDBOXED=$(nix-build --no-out-link "$SCRIPT_DIR/../fixtures/symlinks-sandbox.nix")
SHELL="$SANDBOXED/bin/sandboxed-bash-symlinks"

run() { "$SHELL" --norc --noprofile -c "$@" >/dev/null 2>&1; }
run_output() { "$SHELL" --norc --noprofile -c "$@" 2>/dev/null; }

TESTDIR_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)/.tmp-test"
mkdir -p "$TESTDIR_ROOT"
TESTDIR=$(mktemp -d "$TESTDIR_ROOT/symlinks.XXXXXX")
trap 'rm -rf "$TESTDIR"' EXIT
cd "$TESTDIR"

echo "=== stateDir/stateFile and symlink resolution tests (Linux) ==="
echo

# --- stateDirs / stateFiles (regression: non-symlink paths) ---
expect_ok "can write to stateDir" "echo test > \$HOME/.test-state-dir/file && cat \$HOME/.test-state-dir/file"
expect_ok "can write to stateFile" "echo test > \$HOME/.test-state-file && cat \$HOME/.test-state-file"
expect_fail "stateDir does not weaken isolation" "ls \$HOME/.ssh"

# Retrieve store paths baked into the sandbox at build time
CLOSURE_STORE_FILE=$(run_output 'echo $CLOSURE_STORE_FILE')
NONCLOSURE_STORE_FILE=$(run_output 'echo $NONCLOSURE_STORE_FILE')

REAL_FILE="$TESTDIR/real-target-file"
echo "real content" > "$REAL_FILE"

# --- Test A: stateFile is a symlink to a regular (writable) file ---
rm -f "$HOME/.test-state-file"
ln -sfn "$REAL_FILE" "$HOME/.test-state-file"

expect_ok "stateFile symlink: resolved target is readable" "cat $REAL_FILE"
expect_ok "stateFile symlink: resolved target is writable" "echo updated > $REAL_FILE && cat $REAL_FILE"

# --- Test B: stateFile is a symlink to a nix store file (in closure) ---
rm -f "$HOME/.test-state-file"
ln -sfn "$CLOSURE_STORE_FILE" "$HOME/.test-state-file"

expect_ok "stateFile symlink to in-closure store file: readable" "cat \$CLOSURE_STORE_FILE"

# --- Test C: stateDir contains a symlink to an external writable file ---
rm -f "$HOME/.test-state-file"; touch "$HOME/.test-state-file"
mkdir -p "$HOME/.test-state-dir"
ln -sfn "$REAL_FILE" "$HOME/.test-state-dir/link-to-real"

expect_ok "stateDir symlink: resolved target is readable" "cat $REAL_FILE"
expect_ok "stateDir symlink: resolved target is writable" "echo updated2 > $REAL_FILE"

# --- Test D: stateDir contains a symlink to a nix store file NOT in closure ---
ln -sfn "$NONCLOSURE_STORE_FILE" "$HOME/.test-state-dir/link-to-nonclosure"

expect_ok "stateDir symlink to non-closure store file: readable" "test -e \$NONCLOSURE_STORE_FILE"
expect_fail "stateDir symlink to non-closure store file: not writable" "echo x >> \$NONCLOSURE_STORE_FILE"

# --- Test E: stateDir contains a symlink to a nix store file already in closure ---
ln -sfn "$CLOSURE_STORE_FILE" "$HOME/.test-state-dir/link-to-closure"

expect_ok "stateDir symlink to in-closure store file: readable" "cat \$CLOSURE_STORE_FILE"

# --- Test F: deduplication: two symlinks to the same target ---
ln -sfn "$REAL_FILE" "$HOME/.test-state-dir/dup-link-1"
ln -sfn "$REAL_FILE" "$HOME/.test-state-dir/dup-link-2"

expect_ok "deduplication: sandbox starts with two symlinks to same target" "echo ok"
expect_ok "deduplication: common target accessible once" "cat $REAL_FILE"

# Cleanup
rm -f "$HOME/.test-state-file"; touch "$HOME/.test-state-file"
rm -f "$HOME/.test-state-dir/link-to-real" \
      "$HOME/.test-state-dir/link-to-nonclosure" \
      "$HOME/.test-state-dir/link-to-closure" \
      "$HOME/.test-state-dir/dup-link-1" \
      "$HOME/.test-state-dir/dup-link-2"

# --- Test H: stateDir contains a multi-hop (double) symlink ---
# Mirrors ~/.claude/settings: home-manager creates a chain
# ~/.claude/settings -> /nix/var/nix/profiles/.../settings -> /nix/store/...
# readlink -f skips the intermediate hop and only binds the final target, so the
# kernel hits ENOENT at the intermediate when following the chain inside the sandbox.
# _follow_symlink_chain binds every hop so the full chain is traversable.
_MID_SYM=$(mktemp -u /tmp/sandbox-chain-sym.XXXXXX)
ln -sfn "$REAL_FILE" "$_MID_SYM"
ln -sfn "$_MID_SYM" "$HOME/.test-state-dir/double-link"

expect_ok "double symlink in stateDir: chain traversable inside sandbox" "cat \$HOME/.test-state-dir/double-link"

rm -f "$_MID_SYM" "$HOME/.test-state-dir/double-link"

# --- Test I: sibling symlinks into a single non-closure nix-store directory ---
# Regression for home-manager-files: both symlinks' targets live under a shared
# non-closure ancestor (home-manager-files/.config/...). Earlier, the ancestor
# was pushed to BOUND_PREFIXES as a --dir (empty mountpoint), causing the
# second sibling to be skipped as "already bound" and left dangling in the
# sandbox.
_HM_LIKE=$(mktemp -d /tmp/sandbox-hm-like.XXXXXX)
mkdir -p "$_HM_LIKE/cfg"
echo "content-a" > "$_HM_LIKE/cfg/a"
echo "content-b" > "$_HM_LIKE/cfg/b"
ln -sfn "$_HM_LIKE/cfg/a" "$HOME/.test-state-dir/sibling-a"
ln -sfn "$_HM_LIKE/cfg/b" "$HOME/.test-state-dir/sibling-b"

expect_ok "sibling symlinks: first target readable" "cat \$HOME/.test-state-dir/sibling-a"
expect_ok "sibling symlinks: second target readable (not shadowed by --dir ancestor)" "cat \$HOME/.test-state-dir/sibling-b"

rm -rf "$_HM_LIKE" "$HOME/.test-state-dir/sibling-a" "$HOME/.test-state-dir/sibling-b"

print_results
exit_status
