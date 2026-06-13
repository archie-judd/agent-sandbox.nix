#!/usr/bin/env bash
# Git identity — fail closed.
#
# With user.useConfigOnly=true injected (via GIT_CONFIG_COUNT) and no identity
# declared by any channel — no env GIT_AUTHOR_*/GIT_COMMITTER_*, no bound
# gitconfig, no repo-local user.* — git's gecos/hostname auto-detection is
# disabled, so `git commit` must FAIL (exit 128) rather than silently
# fabricating a <user>@<hostname> identity. This is the core no-fabrication
# guarantee that replaces the old silent mis-attribution.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

source "$SCRIPT_DIR/../lib.sh"

SANDBOXED=$(nix-build --no-out-link "$SCRIPT_DIR/../fixtures/no-git-identity.nix")
SHELL_BIN="$SANDBOXED/bin/sandboxed-bash"

TESTDIR_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)/.tmp-test"
mkdir -p "$TESTDIR_ROOT"
TESTDIR=$(mktemp -d "$TESTDIR_ROOT/git-identity-fail-closed.XXXXXX")
trap 'rm -rf "$TESTDIR"' EXIT

# A fresh repo with NO identity: the global config is unreachable inside the
# sandbox, and we deliberately set no repo-local user.name/user.email.
REPO="$TESTDIR/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q

echo "=== Git identity: fail closed (shared) ==="
echo

cd "$REPO"
capture "$SHELL_BIN" -c 'git commit --allow-empty -m sandbox-fail-closed'

assert_exit_code "git commit fails when no identity is declared" 128
assert_stderr_contains "failure is the auto-detection-disabled fatal" \
	"auto-detection is disabled"

# No commit object was created — nothing was mis-attributed. Checked against
# the host repo directly (a real directory, not only visible in-sandbox).
if [ "$(git -C "$REPO" rev-list --all --count)" -eq 0 ]; then
	echo "PASS: no commit object was created"
	PASS=$((PASS + 1))
else
	echo "FAIL: a commit was created despite missing identity"
	FAIL=$((FAIL + 1))
fi

print_results
exit_status
