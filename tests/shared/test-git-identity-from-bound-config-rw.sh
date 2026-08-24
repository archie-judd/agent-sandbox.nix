#!/usr/bin/env bash
# Git identity — read from a gitconfig bound via rwDirs (legacy mode).
#
# Regression test for the rwDirs-bound flow. The recommended secure path is
# now roFiles (see test-git-identity-from-bound-config-ro.sh); this test
# remains so we'd notice if the legacy mode broke.
#
# A host gitconfig bound into the sandbox via rwDirs is read by git at its
# normal XDG-default global-config path ($HOME/.config/git/config). The
# injected useConfigOnly rides alongside without clobbering the bound [user],
# so the declared identity resolves and a commit is attributed to it.
#
# The bind is exercised through the rwDir's OWN grant: we override HOME to a
# throwaway dir so $HOME/.config/git resolves under the test tree.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

source "$SCRIPT_DIR/../lib.sh"

SANDBOXED=$(build_fixture bound-git-config-rw.nix)
SHELL_BIN="$SANDBOXED/bin/sandboxed-bash"

TESTDIR_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)/.tmp-test"
mkdir -p "$TESTDIR_ROOT"
TESTDIR=$(mktemp -d "$TESTDIR_ROOT/git-identity-bound-config.XXXXXX")
trap 'rm -rf "$TESTDIR"' EXIT

# Throwaway HOME with a gitconfig carrying a [user] block. The fixture binds
# "$HOME/.config/git" via rwDirs, so this resolves under the test tree.
FAKE_HOME="$TESTDIR/home"
mkdir -p "$FAKE_HOME/.config/git"
cat >"$FAKE_HOME/.config/git/config" <<'EOF'
[user]
	name = Bound Config User
	email = bound-config@example.com
EOF

REPO="$TESTDIR/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q

echo "=== Git identity: read from a bound gitconfig (shared) ==="
echo

cd "$REPO"
capture env HOME="$FAKE_HOME" "$SHELL_BIN" -c 'git config --get user.email'
assert_exit_code "bound gitconfig is readable inside the sandbox" 0
assert_output_equals "user.email resolves from the bound gitconfig" \
	"bound-config@example.com"

capture env HOME="$FAKE_HOME" "$SHELL_BIN" -c \
	'git commit --allow-empty -q -m bound-identity && git log -1 --format="%ae"'
assert_exit_code "commit succeeds with the bound identity" 0
assert_output_equals "commit attributed to the bound identity" \
	"bound-config@example.com"

print_results
exit_status
