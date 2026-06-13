#!/usr/bin/env bash
# Git identity — declared via `env`.
#
# GIT_AUTHOR_*/GIT_COMMITTER_* declared through the sandbox's `env` are highest
# precedence and satisfy git even under useConfigOnly. A commit must succeed
# and be attributed to exactly that identity (both author and committer).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

source "$SCRIPT_DIR/../lib.sh"

SANDBOXED=$(nix-build --no-out-link "$SCRIPT_DIR/../fixtures/git-identity.nix")
SHELL_BIN="$SANDBOXED/bin/sandboxed-bash"

TESTDIR_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)/.tmp-test"
mkdir -p "$TESTDIR_ROOT"
TESTDIR=$(mktemp -d "$TESTDIR_ROOT/git-identity-from-env.XXXXXX")
trap 'rm -rf "$TESTDIR"' EXIT

REPO="$TESTDIR/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q

echo "=== Git identity: declared via env (shared) ==="
echo

cd "$REPO"
capture "$SHELL_BIN" -c \
	'git commit --allow-empty -q -m env-identity && git log -1 --format="%an <%ae>|%cn <%ce>"'

assert_exit_code "commit succeeds with identity declared via env" 0
assert_output_equals "commit attributed to the declared identity (author|committer)" \
	"Sandbox Tester <sandbox-tester@example.com>|Sandbox Tester <sandbox-tester@example.com>"

print_results
exit_status
