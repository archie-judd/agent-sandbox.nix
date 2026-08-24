#!/usr/bin/env bash
# Test: the paths that let a sandboxed process run code on the host the next
# time git is used are read-only, for the whole repo the sandbox was launched
# in. Regression for SANDBOX-FINDINGS.md §5 and its follow-ups.
#
# The boundary is the repo you launched in, however you entered it. That repo
# owns more than the common gitdir's hooks/ and config:
#
#   hooks/, config                     content, for every gitdir it owns
#   config.worktree                    content, when extensions.worktreeConfig
#                                      is on (main and linked worktrees)
#   modules/**/{hooks,config}          content, for submodules at any depth
#   worktrees/*/commondir              pointer, redirects the host's git
#   a worktree's or submodule's .git   pointer, same
#
# Both backends bind the common gitdir read-write so commits and fetches keep
# working, then take these back: Linux ro-binds them on top, darwin appends
# deny rules to the end of the seatbelt profile where they outrank the
# read-write allow (last-match-wins). The list is enumerated from the gitdir
# itself, so it never searches the working tree.
#
# Repos that merely happen to sit under a writable launch directory are out of
# scope, and the last case here pins that as a decision rather than an
# accident.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

source "$SCRIPT_DIR/../lib.sh"

SANDBOXED=$(build_fixture expose-repo-root.nix)
SHELL_BIN="$SANDBOXED/bin/sandboxed-bash"

TESTDIR_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)/.tmp-test"
mkdir -p "$TESTDIR_ROOT"
TESTDIR=$(mktemp -d "$TESTDIR_ROOT/git-hook-injection.XXXXXX")
trap 'rm -rf "$TESTDIR"' EXIT

# A repo to be used as a submodule source.
SUB_SRC="$TESTDIR/sub-src"
mkdir -p "$SUB_SRC"
git -C "$SUB_SRC" init -q
git -C "$SUB_SRC" config user.email "test@test.com"
git -C "$SUB_SRC" config user.name "Test"
git -C "$SUB_SRC" commit -q --allow-empty -m "sub initial"

# Main repo: one commit, one submodule, worktree config enabled, one linked
# worktree checked out under the repo root, and an unrelated repo nested
# inside it.
MAIN_REPO="$TESTDIR/main"
mkdir -p "$MAIN_REPO"
git -C "$MAIN_REPO" init -q
git -C "$MAIN_REPO" config user.email "test@test.com"
git -C "$MAIN_REPO" config user.name "Test"
echo "init" >"$MAIN_REPO/file.txt"
git -C "$MAIN_REPO" add -A
git -C "$MAIN_REPO" commit -q -m "initial"
git -C "$MAIN_REPO" -c protocol.file.allow=always submodule add -q "$SUB_SRC" vendor/sub
git -C "$MAIN_REPO" commit -q -m "add submodule"
git -C "$MAIN_REPO" config extensions.worktreeConfig true
git -C "$MAIN_REPO" worktree add -q "$MAIN_REPO/.worktrees/feat" -b feat

NESTED="$MAIN_REPO/nested-unrelated"
mkdir -p "$NESTED"
git -C "$NESTED" init -q
git -C "$NESTED" config user.email "test@test.com"
git -C "$NESTED" config user.name "Test"
git -C "$NESTED" commit -q --allow-empty -m "nested initial"

WT="$MAIN_REPO/.worktrees/feat"
COMMON_GIT="$MAIN_REPO/.git"
SUB_GIT="$COMMON_GIT/modules/vendor/sub"

# Sanity: the wrapper's git-detection resolves --git-common-dir to the main
# repo's .git when invoked from the worktree — the whole reason this
# finding existed. If this assumption changes, the rest of the test is moot.
DETECTED=$(cd "$WT" && git rev-parse --path-format=absolute --git-common-dir)
if [ "$DETECTED" != "$COMMON_GIT" ]; then
	echo "ERROR: expected --git-common-dir=$COMMON_GIT, got $DETECTED" >&2
	exit 1
fi

run() { "$SHELL_BIN" --norc --noprofile -c "$1" >/dev/null 2>&1; }

echo "=== Git hook injection protection (shared) ==="
echo

cd "$WT"
echo "--- launched from a linked worktree ---"

# Persistence vectors: writes denied.
expect_fail run "cannot create .git/hooks/post-checkout" \
	"touch '$COMMON_GIT/hooks/post-checkout'"
expect_fail run "cannot create .git/hooks/pre-commit" \
	"touch '$COMMON_GIT/hooks/pre-commit'"
expect_fail run "cannot append to .git/config (core.hooksPath bypass)" \
	"echo '' >> '$COMMON_GIT/config'"
expect_fail run "cannot overwrite .git/config" \
	"echo '[evil]' > '$COMMON_GIT/config'"
# git writes config atomically: stage to config.lock, then rename onto
# config. The rename target is read-only, so the atomic write still fails.
expect_fail run "cannot rename a lockfile onto .git/config" \
	"touch '$COMMON_GIT/config.sandbox-evil' && mv '$COMMON_GIT/config.sandbox-evil' '$COMMON_GIT/config'"

# config.worktree is read instead of config for worktree-scoped settings once
# extensions.worktreeConfig is on, so it carries the same core.hooksPath
# vector. Neither file exists yet, so this also covers the masking of a
# protected path that is absent at launch.
expect_fail run "cannot create .git/config.worktree" \
	"echo '[core]' > '$COMMON_GIT/config.worktree'"
expect_fail run "cannot create worktrees/feat/config.worktree" \
	"echo '[core]' > '$COMMON_GIT/worktrees/feat/config.worktree'"

# Pointer vectors: redirect the host's git at a gitdir the agent controls and
# the content protections above never get consulted.
expect_fail run "cannot rewrite worktrees/feat/commondir" \
	"echo '/tmp/evil' > '$COMMON_GIT/worktrees/feat/commondir'"
expect_fail run "cannot rewrite the worktree's own .git pointer" \
	"echo 'gitdir: /tmp/evil' > '$WT/.git'"

# Submodule gitdirs live inside the common gitdir's read-write bind and have
# their own hooks and config.
expect_fail run "cannot create a submodule hook" \
	"touch '$SUB_GIT/hooks/pre-commit'"
expect_fail run "cannot append to a submodule config" \
	"echo '' >> '$SUB_GIT/config'"

# Reads still work — git needs to run existing hooks and read existing config.
expect_ok run "can read .git/config" "head -c 1 '$COMMON_GIT/config' >/dev/null"
expect_ok run "can list .git/hooks/" "ls '$COMMON_GIT/hooks/' >/dev/null"

# Sanity: commit still works from the worktree. This is the whole reason
# the fix keeps GIT_DIR rw and only narrows these paths — objects/ and refs/
# must remain writable, otherwise git commit and git fetch would fail.
expect_ok run ".git remains writable for commits from worktree" \
	"git commit --allow-empty -m sandbox-test-commit"

echo
cd "$MAIN_REPO"
echo "--- launched from the repo root ---"

# The gitdir is inside CWD here rather than reached by a bind of its own, so
# this position exercises a different path through the wrapper.
expect_fail run "cannot create .git/hooks/post-checkout" \
	"touch '$COMMON_GIT/hooks/post-checkout'"
expect_fail run "cannot append to .git/config" \
	"echo '' >> '$COMMON_GIT/config'"
expect_fail run "cannot create .git/config.worktree" \
	"echo '[core]' > '$COMMON_GIT/config.worktree'"
expect_fail run "cannot create a submodule hook" \
	"touch '$SUB_GIT/hooks/pre-commit'"
expect_fail run "cannot rewrite the submodule's .git pointer" \
	"echo 'gitdir: /tmp/evil' > '$MAIN_REPO/vendor/sub/.git'"
expect_fail run "cannot rewrite a worktree's .git pointer from the root" \
	"echo 'gitdir: /tmp/evil' > '$WT/.git'"

# Over-blocking guard: git init hard-fails if it cannot copy the hook
# templates, so a protection expressed as a pattern rather than a list of
# known paths would break creating repos inside the sandbox.
expect_ok run "can git init a new repo under CWD" \
	"mkdir -p '$MAIN_REPO/brand-new' && cd '$MAIN_REPO/brand-new' && git init -q ."
expect_ok run "can read the submodule's history" \
	"cd '$MAIN_REPO/vendor/sub' && git log --oneline >/dev/null"
expect_ok run "can write source files" \
	"echo change > '$MAIN_REPO/file.txt'"

# Boundary: a repo that merely sits under the launch directory is not covered.
# This is deliberate — covering it would mean searching the working tree — and
# is documented alongside the launch-directory warning.
expect_ok run "an unrelated nested repo's hooks stay writable (documented non-goal)" \
	"touch '$NESTED/.git/hooks/post-checkout'"

print_results
exit_status
