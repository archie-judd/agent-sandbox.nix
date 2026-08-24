#!/usr/bin/env bash
# Tests for exposeRepoRoot parameter (shared across platforms)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

source "$SCRIPT_DIR/../lib.sh"

SANDBOXED=$(build_fixture expose-repo-root.nix)
SHELL="$SANDBOXED/bin/sandboxed-bash"

# Set up a git repo with a subdirectory.
# IMPORTANT: the repo must NOT be under /tmp, because the sandbox allows
# full read-write access to /tmp. Using a gitignored directory inside this
# repo ensures the sandbox rules for REPO_ROOT (read-only) and CWD
# (read-write) are actually exercised.
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)/.tmp-test"
mkdir -p "$REPO_DIR"
REPO=$(mktemp -d "$REPO_DIR/bind-test.XXXXXX")
trap 'rm -rf "$REPO"' EXIT
git -C "$REPO" init -q
git -C "$REPO" config user.email "test@test.com"
git -C "$REPO" config user.name "Test"

mkdir -p "$REPO/subdir"
echo "root-file-content" >"$REPO/root-file.txt"
echo "sub-file-content" >"$REPO/subdir/sub-file.txt"
git -C "$REPO" add -A
git -C "$REPO" commit -q -m "initial"

# Create an unstaged change in root to verify git diff works
echo "modified" >"$REPO/root-file.txt"

# All tests run from the subdirectory
cd "$REPO/subdir"

run() { "$SHELL" --norc --noprofile -c "$1" >/dev/null 2>&1; }
run_output() { "$SHELL" --norc --noprofile -c "$1" 2>/dev/null; }

echo "=== exposeRepoRoot tests (shared) ==="
echo

expect_ok run "git diff works from subdirectory" "git diff --exit-code --quiet -- ../subdir/sub-file.txt"

# git diff should detect the change we made to root-file.txt
if [ -n "$(run_output 'git diff --name-only')" ]; then
	echo "PASS: git diff reflects changes outside CWD"
	PASS=$((PASS + 1))
else
	echo "FAIL: git diff does not reflect changes outside CWD"
	FAIL=$((FAIL + 1))
fi

expect_ok run "can read files outside CWD but inside repo root" "cat ../root-file.txt"
expect_fail run "cannot write files outside CWD but inside repo root" "echo test > ../outside-cwd.txt"
expect_ok run "CWD remains writable" "touch ./test-write && rm ./test-write"
expect_ok run ".git remains writable (git commit works)" "git add -A && git commit --allow-empty -m test-commit"

print_results
exit_status
