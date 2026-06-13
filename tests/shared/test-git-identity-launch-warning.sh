#!/usr/bin/env bash
# Git identity — launch-time warning.
#
# The commit-time fatal is only guaranteed to be loud to the agent (which can
# self-heal by inventing an identity). The pre-entry-script probes for a
# declared identity at launch and warns on the user's terminal when none is
# found — so the user learns the state before the agent runs. With an identity
# declared (here via env), the probe resolves and no warning is emitted.
#
# The env fixture MUST include git, or "no warning" would pass for the wrong
# reason (probe skipped because git is absent, not because identity resolved).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

source "$SCRIPT_DIR/../lib.sh"

SANDBOXED_NOID=$(nix-build --no-out-link "$SCRIPT_DIR/../fixtures/no-git-identity.nix")
SANDBOXED_ENV=$(nix-build --no-out-link "$SCRIPT_DIR/../fixtures/git-identity.nix")

TESTDIR_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)/.tmp-test"
mkdir -p "$TESTDIR_ROOT"
TESTDIR=$(mktemp -d "$TESTDIR_ROOT/git-identity-launch-warning.XXXXXX")
trap 'rm -rf "$TESTDIR"' EXIT

REPO="$TESTDIR/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q

echo "=== Git identity: launch-time warning (shared) ==="
echo

cd "$REPO"
capture "$SANDBOXED_NOID/bin/sandboxed-bash" -c 'true'
assert_stderr_contains "launch warning shown when no identity is declared" \
	"no git identity declared"

capture "$SANDBOXED_ENV/bin/sandboxed-bash" -c 'true'
assert_stderr_not_contains "no launch warning when identity is declared via env" \
	"no git identity declared"

print_results
exit_status
