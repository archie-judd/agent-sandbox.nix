#!/usr/bin/env bash
# Symlink target resolution tests (Darwin-specific)
#
# Without allowNix the store is not readable, so a symlink in a declared path
# that names a store path outside the closure only works because the launcher
# emits a read grant for that target. These cover the grant and its limits.
#
# Assertions are made at the store path, not at the declared name: on Darwin
# HOME is a fresh sandbox home with symlinks planted into it, and a declared
# path that resolves into the store gets no planted link.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

source "$SCRIPT_DIR/../lib.sh"

SANDBOXED=$(build_fixture symlinks-sandbox.nix)
SHELL="$SANDBOXED/bin/sandboxed-bash-symlinks"

run() { "$SHELL" --norc --noprofile -c "$1" >/dev/null 2>&1; }
run_output() { "$SHELL" --norc --noprofile -c "$1" 2>/dev/null; }

TESTDIR_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)/.tmp-test"
mkdir -p "$TESTDIR_ROOT"
TESTDIR=$(mktemp -d "$TESTDIR_ROOT/symlinks-darwin.XXXXXX")
# OOB_FILE lives in $HOME but outside every bound prefix, so it is only
# reachable if a symlink to it is wrongly honoured.
OOB_FILE=$(mktemp "$HOME/.sandbox-test-oob.XXXXXX")
echo "out-of-bounds content" > "$OOB_FILE"
# A sibling of the declared /tmp directory: declaring one entry under the temp
# root must not expose the rest of it.
OOB_TMP_FILE=$(mktemp "/tmp/sandbox-test-tmp-oob.XXXXXX")
echo "out-of-bounds content" > "$OOB_TMP_FILE"
trap 'rm -rf "$TESTDIR" "$OOB_FILE" "$OOB_TMP_FILE" "$HOME/.test-state-dir" "$HOME/.test-state-file" "$HOME/.test-ro-file" /tmp/test-parent-link-dir' EXIT
cd "$TESTDIR"

mkdir -p "$HOME/.test-state-dir"
touch "$HOME/.test-state-file"
touch "$HOME/.test-ro-file"
mkdir -p /tmp/test-parent-link-dir

echo "=== Symlink target resolution tests (Darwin) ==="
echo

CLOSURE_STORE_FILE=$(run_output 'echo $CLOSURE_STORE_FILE')
NONCLOSURE_STORE_FILE=$(run_output 'echo $NONCLOSURE_STORE_FILE')
NONCLOSURE_STORE_FILE2=$(run_output 'echo $NONCLOSURE_STORE_FILE2')

# --- Baseline: without a symlink naming it, a non-closure store path is not
# readable. This is what the per-target grants below are measured against. ---
expect_fail run "non-closure store file is not readable unprompted" \
    'cat "$NONCLOSURE_STORE_FILE"'

expect_ok run "closure store file is readable" \
    'cat "$CLOSURE_STORE_FILE"'

# --- Test A: roFile is itself a symlink to a non-closure store file ---
# The declared path resolves into the store, so host_state records the store
# path and the launcher grants it.
rm -f "$HOME/.test-ro-file"
ln -sfn "$NONCLOSURE_STORE_FILE" "$HOME/.test-ro-file"

expect_ok run "roFile symlink to non-closure store file: target readable" \
    'cat "$NONCLOSURE_STORE_FILE"'

expect_fail run "roFile symlink to non-closure store file: target not writable" \
    'echo x >> "$NONCLOSURE_STORE_FILE"'

expect_fail run "roFile symlink to non-closure store file: target not exec-able" \
    '"$NONCLOSURE_STORE_FILE"'

rm -f "$HOME/.test-ro-file"; touch "$HOME/.test-ro-file"

# --- Test B: rwDir contains a symlink to a non-closure store file ---
# The home-manager shape: a declared directory whose entries point into the
# store. Exercises inner_symlinks rather than hops.
ln -sfn "$NONCLOSURE_STORE_FILE" "$HOME/.test-state-dir/link-to-nonclosure"

expect_ok run "rwDir symlink to non-closure store file: target readable" \
    'cat "$NONCLOSURE_STORE_FILE"'

rm -f "$HOME/.test-state-dir/link-to-nonclosure"

# --- Test C: a symlink grants its own target and nothing beside it ---
# Both files live under the same store package. Naming one must not expose
# the other, or the grant is really a package-wide grant.
ln -sfn "$NONCLOSURE_STORE_FILE" "$HOME/.test-state-dir/link-to-nonclosure"

expect_ok run "sibling in the same store path: named target readable" \
    'cat "$NONCLOSURE_STORE_FILE"'

expect_fail run "sibling in the same store path: unnamed sibling not readable" \
    'cat "$NONCLOSURE_STORE_FILE2"'

rm -f "$HOME/.test-state-dir/link-to-nonclosure"

# --- Test D: two symlinks to one target ---
# Dedup: the launcher must emit one grant, and the sandbox must still start.
ln -sfn "$NONCLOSURE_STORE_FILE" "$HOME/.test-state-dir/dup-link-1"
ln -sfn "$NONCLOSURE_STORE_FILE" "$HOME/.test-state-dir/dup-link-2"

expect_ok run "deduplication: sandbox starts with two symlinks to one target" \
    'echo ok'

expect_ok run "deduplication: common target readable" \
    'cat "$NONCLOSURE_STORE_FILE"'

rm -f "$HOME/.test-state-dir/dup-link-1" "$HOME/.test-state-dir/dup-link-2"

# --- Test E: symlink to a path outside the store is ignored ---
# An agent could otherwise plant a symlink during a session to widen the
# sandbox on the next launch (e.g. ~/.claude/evil -> /etc/shadow). Targets
# outside /nix/store are dropped with a warning; the launch still succeeds.
ln -sfn "$OOB_FILE" "$HOME/.test-state-dir/link-to-oob"

expect_fail run "rwDir symlink to out-of-bounds path: target not accessible (security)" \
    "cat $OOB_FILE"

expect_ok run "rwDir symlink to out-of-bounds path: sandbox still starts cleanly" \
    'echo ok'

capture "$SHELL" --norc --noprofile -c 'echo ok'
assert_stderr_contains "rwDir symlink to out-of-bounds path: warns about the ignored target" \
    "ignoring symlink to '$OOB_FILE'"

rm -f "$HOME/.test-state-dir/link-to-oob"

# --- Test F: declared directory reached through a symlinked parent ---
# /tmp is a symlink to /private/tmp, so resolution passes through the link
# node. Grants derived from the physical path never name it, and the walk is
# refused at /tmp before the declared grant is ever consulted.
expect_ok run "symlinked parent: writable at the declared /tmp spelling" \
    'echo test > /tmp/test-parent-link-dir/file && cat /tmp/test-parent-link-dir/file'

expect_ok run "symlinked parent: writable at the physical /private/tmp spelling" \
    'echo test > /private/tmp/test-parent-link-dir/file && cat /private/tmp/test-parent-link-dir/file'

# The link node is granted stat only. If it were granted as a subpath instead,
# the temp root would be readable and these would pass.
expect_fail run "symlinked parent: temp root is not listable" \
    'ls /tmp'

expect_fail run "symlinked parent: sibling under the temp root not readable" \
    "cat $OOB_TMP_FILE"

print_results
exit_status
