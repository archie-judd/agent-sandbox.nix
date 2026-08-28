#!/usr/bin/env bash
# Test: git works from every launch topology, and each one exposes its own
# work tree and nothing above it.
#
# The work tree root is what git needs to report on files above the launch
# directory: without it, git status and git diff call them deleted rather
# than fail. It is not the parent of the common git dir, which is the main
# checkout for a linked worktree and .git/modules for a submodule.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

source "$SCRIPT_DIR/../lib.sh"

SANDBOXED=$(build_fixture git-topologies.nix)
SHELL="$SANDBOXED/bin/sandboxed-bash-git-topologies"

# Not under /tmp, which each platform treats as a special case: Linux
# replaces it with a tmpfs, darwin denies it. A repository there would
# exercise none of the rules under test.
TESTDIR_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)/.tmp-test"
mkdir -p "$TESTDIR_ROOT"
BASE=$(mktemp -d "$TESTDIR_ROOT/git-topologies.XXXXXX")
trap 'chmod -R u+w "$BASE" 2>/dev/null; rm -rf "$BASE"' EXIT

MAIN="$BASE/main"
WORKTREE="$BASE/worktree"
SUPER="$BASE/super"

git_quiet() { git -c init.defaultBranch=main -c protocol.file.allow=always "$@"; }

make_repo() {
	local dir="$1"
	mkdir -p "$dir"
	git_quiet -C "$dir" init -q
	git_quiet -C "$dir" config user.email "test@test.com"
	git_quiet -C "$dir" config user.name "Test"
}

# The main checkout, and a linked worktree beside it rather than inside it:
# nested, the main checkout would be an ancestor of the worktree and the
# "cannot read the main checkout" assertions could not tell the two apart.
make_repo "$MAIN"
mkdir -p "$MAIN/subdir"
echo "main-root-content" >"$MAIN/root-file.txt"
echo "main-sub-content" >"$MAIN/subdir/sub-file.txt"
git_quiet -C "$MAIN" add -A
git_quiet -C "$MAIN" commit -q -m "initial"
git_quiet -C "$MAIN" worktree add -q -b wt-branch "$WORKTREE"

# A superproject with two submodules: the second exists so the sandbox can be
# asked whether it reaches a sibling's git dir, which is what
# .git/modules exposes when it is granted whole.
make_repo "$BASE/sub-a"
mkdir -p "$BASE/sub-a/nested"
echo "a-root-content" >"$BASE/sub-a/a-file.txt"
echo "a-nested-content" >"$BASE/sub-a/nested/deep.txt"
git_quiet -C "$BASE/sub-a" add -A
git_quiet -C "$BASE/sub-a" commit -q -m "sub-a initial"

make_repo "$BASE/sub-b"
echo "b-root-content" >"$BASE/sub-b/b-file.txt"
git_quiet -C "$BASE/sub-b" add -A
git_quiet -C "$BASE/sub-b" commit -q -m "sub-b initial"

make_repo "$SUPER"
echo "super-content" >"$SUPER/super-file.txt"
git_quiet -C "$SUPER" add -A
git_quiet -C "$SUPER" commit -q -m "super initial"
git_quiet -C "$SUPER" submodule -q add "$BASE/sub-a" sub-a
git_quiet -C "$SUPER" submodule -q add "$BASE/sub-b" sub-b
git_quiet -C "$SUPER" commit -q -m "add submodules"

# git submodule add clones into .git/modules/<name>, and a clone does not
# inherit the source repo's local config. On the host that goes unnoticed
# because git falls back to the developer's global config, but the sandbox
# masks $HOME and sets user.useConfigOnly, so git commit would have no
# identity to use.
for submodule in sub-a sub-b; do
	git_quiet -C "$SUPER/$submodule" config user.email "test@test.com"
	git_quiet -C "$SUPER/$submodule" config user.name "Test"
done

# Unstaged changes at each work tree root, so "git diff sees above cwd" is a
# real question rather than a vacuous one.
echo "modified" >"$MAIN/root-file.txt"
echo "modified" >"$WORKTREE/root-file.txt"
echo "modified" >"$SUPER/sub-a/a-file.txt"

# expect_ok/expect_fail call a runner with one argument, so the launch
# directory travels in a variable rather than as a second parameter.
LAUNCH_DIR=""
run() { (cd "$LAUNCH_DIR" && "$SHELL" --norc --noprofile -c "$1") >/dev/null 2>&1; }
run_output() { (cd "$LAUNCH_DIR" && "$SHELL" --norc --noprofile -c "$1") 2>/dev/null; }

assert_sees_change_above_cwd() {
	local desc="$1"
	if [ -n "$(run_output 'git diff --name-only')" ]; then
		echo "PASS: $desc"
		PASS=$((PASS + 1))
	else
		echo "FAIL: $desc (git diff reported nothing, so files above cwd read as unchanged or deleted)"
		FAIL=$((FAIL + 1))
	fi
}

echo "=== git launch topologies (shared) ==="

# --- 1. Repository root -----------------------------------------------------
echo
echo "--- launched at a repository root"
LAUNCH_DIR="$MAIN"
expect_ok run "git status works" "git status --porcelain >/dev/null"
expect_ok run "git log works" "git log --oneline -1 >/dev/null"
expect_ok run "can read a tracked file" "cat root-file.txt"
expect_ok run "can read a file in a subdirectory" "cat subdir/sub-file.txt"
expect_ok run "cwd is writable" "touch ./probe && rm ./probe"
expect_ok run "git commit works" "git commit --allow-empty -q -m sandbox-commit"

# --- 2. Repository subdirectory ---------------------------------------------
# The work tree root above cwd must be readable: withholding it makes git
# report every file above cwd as deleted instead of failing.
echo
echo "--- launched in a repository subdirectory"
LAUNCH_DIR="$MAIN/subdir"
expect_ok run "git status works" "git status --porcelain >/dev/null"
expect_ok run "git diff works on a path under cwd" "git diff --exit-code --quiet -- ../subdir/sub-file.txt"
assert_sees_change_above_cwd "git diff reflects changes above cwd"
expect_ok run "can read files above cwd inside the work tree" "cat ../root-file.txt"
expect_fail run "cannot write above cwd inside the work tree" "echo x > ../escape.txt"
expect_ok run "cwd is writable" "touch ./probe && rm ./probe"
expect_ok run "git commit works" "git commit --allow-empty -q -m sandbox-commit"

# --- 3. Worktree root -------------------------------------------------------
echo
echo "--- launched at a linked worktree root"
LAUNCH_DIR="$WORKTREE"
expect_ok run "git status works" "git status --porcelain >/dev/null"
expect_ok run "git log works" "git log --oneline -1 >/dev/null"
expect_ok run "can read a tracked file" "cat root-file.txt"
expect_fail run "cannot read the main checkout" "cat $MAIN/root-file.txt"
expect_ok run "cwd is writable" "touch ./probe && rm ./probe"
expect_ok run "git commit works" "git commit --allow-empty -q -m sandbox-commit"

# --- 4. Worktree subdirectory -----------------------------------------------
echo
echo "--- launched in a linked worktree subdirectory"
LAUNCH_DIR="$WORKTREE/subdir"
expect_ok run "git status works" "git status --porcelain >/dev/null"
assert_sees_change_above_cwd "git diff reflects changes above cwd"
expect_ok run "can read files above cwd inside the worktree" "cat ../root-file.txt"
expect_fail run "cannot read the main checkout" "cat $MAIN/root-file.txt"
expect_fail run "cannot write above cwd inside the worktree" "echo x > ../escape.txt"

# --- 5. Submodule root ------------------------------------------------------
echo
echo "--- launched at a submodule root"
LAUNCH_DIR="$SUPER/sub-a"
expect_ok run "git status works" "git status --porcelain >/dev/null"
expect_ok run "git log works" "git log --oneline -1 >/dev/null"
expect_ok run "can read a tracked file" "cat a-file.txt"
expect_fail run "cannot read the superproject work tree" "cat $SUPER/super-file.txt"
expect_fail run "cannot read a sibling submodule's git dir" "cat $SUPER/.git/modules/sub-b/HEAD"
expect_ok run "cwd is writable" "touch ./probe && rm ./probe"
expect_ok run "git commit works" "git commit --allow-empty -q -m sandbox-commit"

# --- 6. Submodule subdirectory ----------------------------------------------
echo
echo "--- launched in a submodule subdirectory"
LAUNCH_DIR="$SUPER/sub-a/nested"
expect_ok run "git status works" "git status --porcelain >/dev/null"
assert_sees_change_above_cwd "git diff reflects changes above cwd"
expect_ok run "can read files above cwd inside the submodule" "cat ../a-file.txt"
expect_fail run "cannot read the superproject work tree" "cat $SUPER/super-file.txt"
expect_fail run "cannot read a sibling submodule's git dir" "cat $SUPER/.git/modules/sub-b/HEAD"

print_results
exit_status
