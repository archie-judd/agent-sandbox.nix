#!/usr/bin/env bash
# Test: .git/hooks and .git/config are read-only from inside the sandbox,
# even when invoked from a worktree. Regression for SANDBOX-FINDINGS.md §5.
#
# Both backends resolve GIT_DIR via `git rev-parse --git-common-dir`, which
# from a worktree returns the *main repo's* .git. Without the fix, the
# common gitdir was fully writable, so a sandboxed process could plant
# .git/hooks/post-checkout or alter .git/config and fire arbitrary code
# the next time the host ran git in any worktree of the repo.
#
# Linux fix: ro-bind hooks/ and config on top of the rw bind of GIT_DIR
# (lib/linux/default.nix). Darwin fix: seatbelt deny rules on
# (subpath GIT_HOOKS_DIR) and (literal GIT_CONFIG_FILE) layered over the
# rw allow on (subpath GIT_DIR) (lib/darwin/seatbelt-profile.nix —
# last-match-wins). Both fixes keep objects/ and refs/ writable so
# commits and fetches still work from a worktree.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

source "$SCRIPT_DIR/../lib.sh"

SANDBOXED=$(nix-build --no-out-link "$SCRIPT_DIR/../fixtures/expose-repo-root.nix")
SHELL_BIN="$SANDBOXED/bin/sandboxed-bash"

TESTDIR_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)/.tmp-test"
mkdir -p "$TESTDIR_ROOT"
TESTDIR=$(mktemp -d "$TESTDIR_ROOT/git-hook-injection.XXXXXX")
trap 'rm -rf "$TESTDIR"' EXIT

# Main repo with one commit so we can create a worktree from it.
MAIN_REPO="$TESTDIR/main"
mkdir -p "$MAIN_REPO"
git -C "$MAIN_REPO" init -q
git -C "$MAIN_REPO" config user.email "test@test.com"
git -C "$MAIN_REPO" config user.name "Test"
echo "init" >"$MAIN_REPO/file.txt"
git -C "$MAIN_REPO" add -A
git -C "$MAIN_REPO" commit -q -m "initial"
git -C "$MAIN_REPO" worktree add -q "$MAIN_REPO/.worktrees/feat" -b feat

WT="$MAIN_REPO/.worktrees/feat"
COMMON_GIT="$MAIN_REPO/.git"

# Sanity: the wrapper's git-detection resolves --git-common-dir to the main
# repo's .git when invoked from the worktree — the whole reason this
# finding existed. If this assumption changes, the rest of the test is moot.
DETECTED=$(cd "$WT" && git rev-parse --path-format=absolute --git-common-dir)
if [ "$DETECTED" != "$COMMON_GIT" ]; then
	echo "ERROR: expected --git-common-dir=$COMMON_GIT, got $DETECTED" >&2
	exit 1
fi

cd "$WT"
run() { "$SHELL_BIN" --norc --noprofile -c "$@" >/dev/null 2>&1; }

echo "=== Git hook injection protection (shared, worktree invocation) ==="
echo

# Persistence vectors: writes denied.
expect_fail "cannot create .git/hooks/post-checkout" \
	"touch '$COMMON_GIT/hooks/post-checkout'"
expect_fail "cannot create .git/hooks/pre-commit" \
	"touch '$COMMON_GIT/hooks/pre-commit'"
expect_fail "cannot append to .git/config (core.hooksPath bypass)" \
	"echo '' >> '$COMMON_GIT/config'"
expect_fail "cannot overwrite .git/config" \
	"echo '[evil]' > '$COMMON_GIT/config'"
# git writes config atomically: stage to config.lock, then rename onto
# config. The rename target is read-only, so the atomic write still fails.
expect_fail "cannot rename a lockfile onto .git/config" \
	"touch '$COMMON_GIT/config.sandbox-evil' && mv '$COMMON_GIT/config.sandbox-evil' '$COMMON_GIT/config'"

# Reads still work — git needs to run existing hooks and read existing config.
expect_ok "can read .git/config" "head -c 1 '$COMMON_GIT/config' >/dev/null"
expect_ok "can list .git/hooks/" "ls '$COMMON_GIT/hooks/' >/dev/null"

# Sanity: commit still works from the worktree. This is the whole reason
# the fix keeps GIT_DIR rw and only narrows hooks/ and config — objects/
# and refs/ must remain writable, otherwise git commit and git fetch
# would fail.
expect_ok ".git remains writable for commits from worktree" \
	"git commit --allow-empty -m sandbox-test-commit"

print_results
exit_status
