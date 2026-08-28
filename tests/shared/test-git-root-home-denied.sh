#!/usr/bin/env bash
# Test: when the git root resolves to $HOME or an ancestor (a git init'd
# home directory), the sandbox disables git for the session instead of
# binding the whole home, which would leak SSH keys, other projects and the
# dotfiles repo's history. CWD stays fully usable. HOME is pointed at a
# throwaway git repo, so the guard fires without touching the real home.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

source "$SCRIPT_DIR/../lib.sh"

SANDBOXED=$(build_fixture git-topologies.nix)
SHELL="$SANDBOXED/bin/sandboxed-bash-git-topologies"

# The fake HOME must NOT be under /tmp, which each platform treats as a
# special case — that would mask the assertion. Use the gitignored .tmp-test
# dir inside this repo, matching test-git-topologies.sh.
TESTDIR_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)/.tmp-test"
mkdir -p "$TESTDIR_ROOT"
FAKE_HOME=$(mktemp -d "$TESTDIR_ROOT/git-root-home.XXXXXX")
trap 'rm -rf "$FAKE_HOME"' EXIT

# Make $FAKE_HOME itself a git repo, with a secret sibling to the project subdir.
git -C "$FAKE_HOME" init -q
git -C "$FAKE_HOME" config user.email "test@test.com"
git -C "$FAKE_HOME" config user.name "Test"
echo "home-secret-content" >"$FAKE_HOME/home-secret.txt"
mkdir -p "$FAKE_HOME/subdir"
echo "project-file" >"$FAKE_HOME/subdir/project.txt"

# Launch from the project subdir, with HOME pointed at the repo root so the
# detected git root (dirname of .git) equals $HOME and the guard fires.
cd "$FAKE_HOME/subdir"

run_home_root() { HOME="$FAKE_HOME" "$SHELL" --norc --noprofile -c "$1" >/dev/null 2>&1; }

echo "=== git-root-home-denied tests (shared) ==="
echo

# Sanity: git resolves inside the sandbox (otherwise the assertions below are
# meaningless — a missing binary also exits non-zero).
expect_ok run_home_root "git binary is available inside the sandbox" "command -v git"

# 1. The wrapper warns that git was disabled. The warning is emitted by the
#    outer wrapper (before sandbox entry) on stderr, so any command triggers it.
WARN_OUT=$(HOME="$FAKE_HOME" "$SHELL" --norc --noprofile -c 'true' 2>&1 >/dev/null || true)
if echo "$WARN_OUT" | grep -q "git is disabled for this session"; then
	echo "PASS: warns that git is disabled when root resolves to \$HOME"
	PASS=$((PASS + 1))
else
	echo "FAIL: expected home-git-root warning on stderr, got: $WARN_OUT"
	FAIL=$((FAIL + 1))
fi

# 2. The security property: the home directory is NOT exposed. The secret sits
#    in the (would-be) REPO_ROOT, one level above CWD. Without the fix this
#    succeeds via the REPO_ROOT read grant; with the fix home is never bound.
expect_fail run_home_root "cannot read sibling file in home-repo root" "cat ../home-secret.txt"

# 3. Git is disabled (not crashed): inside the sandbox there is no repo to find.
expect_fail run_home_root "git does not see the home repo from inside the sandbox" "git rev-parse --git-dir"

# 4. The project subdir (CWD) remains fully usable.
expect_ok run_home_root "CWD remains readable" "cat ./project.txt"
expect_ok run_home_root "CWD remains writable" "touch ./test-write && rm ./test-write"

# 5. A git root strictly *above* $HOME is refused the same way. This branch
#    stays unconditional: launching from $HOME itself grants the home by
#    consent (see test-home-cwd-confirm.sh), but a repo rooted above it would
#    reach further — other users' homes, system state — which no confirmation
#    covers. Layout: repo root / home / project, with HOME in the middle.
OUTER_REPO=$(mktemp -d "$TESTDIR_ROOT/git-root-above-home.XXXXXX")
trap 'rm -rf "$FAKE_HOME" "$OUTER_REPO"' EXIT
git -C "$OUTER_REPO" init -q
echo "outer-secret-content" >"$OUTER_REPO/outer-secret.txt"
mkdir -p "$OUTER_REPO/home/project"

run_above_home() { (cd "$OUTER_REPO/home/project" && HOME="$OUTER_REPO/home" "$SHELL" --norc --noprofile -c "$1") >/dev/null 2>&1; }

WARN_OUT=$( (cd "$OUTER_REPO/home/project" && HOME="$OUTER_REPO/home" "$SHELL" --norc --noprofile -c 'true') 2>&1 >/dev/null || true)
if echo "$WARN_OUT" | grep -q "git is disabled for this session"; then
	echo "PASS: warns that git is disabled when the root is above \$HOME"
	PASS=$((PASS + 1))
else
	echo "FAIL: expected above-home-git-root warning on stderr, got: $WARN_OUT"
	FAIL=$((FAIL + 1))
fi
expect_fail run_above_home "cannot read the repo root above home" "cat ../../outer-secret.txt"
expect_fail run_above_home "git does not see the repo rooted above home" "git rev-parse --git-dir"

print_results
exit_status
