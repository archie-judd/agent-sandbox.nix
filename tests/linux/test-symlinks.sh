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
# OOB_FILE lives in $HOME but outside the repo and all other bound prefixes.
# Inside the sandbox $HOME is a tmpfs, so this file is invisible unless explicitly bound.
OOB_FILE=$(mktemp "$HOME/.sandbox-test-oob.XXXXXX")
echo "out-of-bounds content" > "$OOB_FILE"
trap 'rm -rf "$TESTDIR" "$OOB_FILE"' EXIT
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

# --- Test A: stateFile is a symlink to an out-of-bounds path is rejected ---
rm -f "$HOME/.test-state-file"
ln -sfn "$OOB_FILE" "$HOME/.test-state-file"

expect_fail "stateFile symlink to out-of-bounds path: target not accessible (security)" "cat $OOB_FILE"
expect_ok  "stateFile symlink to out-of-bounds path: sandbox still starts cleanly" "echo ok"

# --- Test B: stateFile is a symlink to a nix store file (in closure) ---
rm -f "$HOME/.test-state-file"
ln -sfn "$CLOSURE_STORE_FILE" "$HOME/.test-state-file"

expect_ok "stateFile symlink to in-closure store file: readable" "cat \$CLOSURE_STORE_FILE"

# --- Test C: stateDir symlink to out-of-bounds path is rejected ---
# Symlinks that point outside /nix/store (and paths already in BOUND_PREFIXES)
# are silently ignored at startup. An agent could otherwise plant a symlink
# during a session to expand the sandbox on the next startup
# (e.g. ~/.claude/evil -> /etc/shadow).
# Users who need such a target must declare it explicitly as a stateDir or stateFile.
rm -f "$HOME/.test-state-file"; touch "$HOME/.test-state-file"
mkdir -p "$HOME/.test-state-dir"
ln -sfn "$OOB_FILE" "$HOME/.test-state-dir/link-to-oob"

expect_fail "stateDir symlink to out-of-bounds path: target not accessible (security)" "cat $OOB_FILE"
expect_ok  "stateDir symlink to out-of-bounds path: sandbox still starts cleanly" "echo ok"

# --- Test D: stateDir contains a symlink to a nix store file NOT in closure ---
ln -sfn "$NONCLOSURE_STORE_FILE" "$HOME/.test-state-dir/link-to-nonclosure"

expect_ok "stateDir symlink to non-closure store file: readable" "test -e \$NONCLOSURE_STORE_FILE"
expect_fail "stateDir symlink to non-closure store file: not writable" "echo x >> \$NONCLOSURE_STORE_FILE"

# --- Test E: stateDir contains a symlink to a nix store file already in closure ---
ln -sfn "$CLOSURE_STORE_FILE" "$HOME/.test-state-dir/link-to-closure"

expect_ok "stateDir symlink to in-closure store file: readable" "cat \$CLOSURE_STORE_FILE"

# --- Test F: deduplication: two symlinks to the same Nix store target ---
# Both symlinks point at the same non-closure store path; bwrap must only
# receive one --ro-bind for that path. Exercises RESOLVED_TARGETS dedup.
ln -sfn "$NONCLOSURE_STORE_FILE" "$HOME/.test-state-dir/dup-link-1"
ln -sfn "$NONCLOSURE_STORE_FILE" "$HOME/.test-state-dir/dup-link-2"

expect_ok "deduplication: sandbox starts with two symlinks to same Nix target" "echo ok"
expect_ok "deduplication: common Nix target accessible" "test -e \$NONCLOSURE_STORE_FILE"

# Cleanup
rm -f "$HOME/.test-state-file"; touch "$HOME/.test-state-file"
rm -f "$HOME/.test-state-dir/link-to-oob" \
      "$HOME/.test-state-dir/link-to-nonclosure" \
      "$HOME/.test-state-dir/link-to-closure" \
      "$HOME/.test-state-dir/dup-link-1" \
      "$HOME/.test-state-dir/dup-link-2"

# --- Test H: stateDir double-symlink chain with an out-of-bounds intermediate ---
# Both the intermediate path (/tmp/...) and the final target are outside
# the permitted sandbox paths, so the first hop is rejected and the chain
# is not bound. The sandbox still starts cleanly.
# The real home-manager pattern (~/.claude/settings.json -> /nix/store/...)
# is a *direct* Nix store symlink and is covered by Tests D and E above.
_MID_SYM=$(mktemp -u /tmp/sandbox-chain-sym.XXXXXX)
ln -sfn "$REAL_FILE" "$_MID_SYM"
ln -sfn "$_MID_SYM" "$HOME/.test-state-dir/double-link"

expect_fail "double symlink via out-of-bounds intermediate: chain not accessible (security)" "cat \$HOME/.test-state-dir/double-link"
expect_ok  "double symlink via out-of-bounds intermediate: sandbox still starts cleanly" "echo ok"

rm -f "$_MID_SYM" "$HOME/.test-state-dir/double-link"

# --- Test I: sibling symlinks into a single non-closure nix-store directory ---
# Regression: both targets live under a shared non-closure ancestor. Earlier,
# the ancestor was pushed to BOUND_PREFIXES as a --dir (empty mountpoint),
# causing the second sibling to be skipped as "already bound" and left dangling.
#
# Part 1: out-of-bounds /tmp siblings are rejected (not /nix/store, not in BOUND_PREFIXES).
_HM_LIKE=$(mktemp -d /tmp/sandbox-hm-like.XXXXXX)
mkdir -p "$_HM_LIKE/cfg"
echo "content-a" > "$_HM_LIKE/cfg/a"
echo "content-b" > "$_HM_LIKE/cfg/b"
ln -sfn "$_HM_LIKE/cfg/a" "$HOME/.test-state-dir/sibling-a"
ln -sfn "$_HM_LIKE/cfg/b" "$HOME/.test-state-dir/sibling-b"

expect_fail "sibling symlinks to out-of-bounds /tmp: first target not accessible (security)" "cat \$HOME/.test-state-dir/sibling-a"
expect_fail "sibling symlinks to out-of-bounds /tmp: second target not accessible (security)" "cat \$HOME/.test-state-dir/sibling-b"
expect_ok  "sibling symlinks to out-of-bounds /tmp: sandbox still starts cleanly" "echo ok"

rm -rf "$_HM_LIKE" "$HOME/.test-state-dir/sibling-a" "$HOME/.test-state-dir/sibling-b"

# Part 2: Nix store siblings still work (ancestor-dedup regression coverage).
# NONCLOSURE_STORE_FILE and NONCLOSURE_STORE_FILE2 both live under pkgs.hello,
# so they share a common non-closure ancestor that exercises the dedup logic.
NONCLOSURE_STORE_FILE2=$(run_output 'echo $NONCLOSURE_STORE_FILE2')
ln -sfn "$NONCLOSURE_STORE_FILE" "$HOME/.test-state-dir/nix-sib-a"
ln -sfn "$NONCLOSURE_STORE_FILE2" "$HOME/.test-state-dir/nix-sib-b"

expect_ok "sibling Nix store symlinks: first target readable" "test -e \$NONCLOSURE_STORE_FILE"
expect_ok "sibling Nix store symlinks: second target readable (not shadowed by --dir ancestor)" "test -e \$NONCLOSURE_STORE_FILE2"

rm -f "$HOME/.test-state-dir/nix-sib-a" "$HOME/.test-state-dir/nix-sib-b"

print_results
exit_status
