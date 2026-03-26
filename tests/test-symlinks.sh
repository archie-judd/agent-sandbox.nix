#!/usr/bin/env bash
# stateDir/stateFile access and symlink resolution tests
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OS=$(uname)

source "$SCRIPT_DIR/lib.sh"

SANDBOXED=$(nix-build --no-out-link "$SCRIPT_DIR/symlinks-sandbox.nix")
SHELL="$SANDBOXED/bin/sandboxed-bash-symlinks"

run() { "$SHELL" --norc --noprofile -c "$@" >/dev/null 2>&1; }
run_output() { "$SHELL" --norc --noprofile -c "$@" 2>/dev/null; }

TESTDIR_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)/.tmp-test"
mkdir -p "$TESTDIR_ROOT"
TESTDIR=$(mktemp -d "$TESTDIR_ROOT/symlinks.XXXXXX")
trap 'rm -rf "$TESTDIR"' EXIT
cd "$TESTDIR"

echo "=== stateDir/stateFile and symlink resolution tests ($OS) ==="
echo

# --- stateDirs / stateFiles (regression: non-symlink paths) ---
expect_ok "can write to stateDir" "echo test > \$HOME/.test-state-dir/file && cat \$HOME/.test-state-dir/file"
expect_ok "can write to stateFile" "echo test > \$HOME/.test-state-file && cat \$HOME/.test-state-file"
expect_fail "stateDir does not weaken isolation" "ls \$HOME/.ssh"

if [ "$OS" = "Linux" ]; then
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

elif [ "$OS" = "Darwin" ]; then
  echo "NOTE: Darwin symlink resolution (stateFile/stateDir targets outside \$HOME) is not"
  echo "      implemented in mkDarwinSandbox — Linux-specific tests skipped."
fi

print_results
exit_status
