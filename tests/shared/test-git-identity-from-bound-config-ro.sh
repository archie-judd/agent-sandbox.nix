#!/usr/bin/env bash
# Git identity — read from a gitconfig bound read-only via roFiles.
#
# This is the recommended secure identity path: the agent reads [user]
# through git's normal global-config lookup, but writes to the bound
# config fail. That blocks core.hooksPath, core.fsmonitor, and alias.*
# settings that would otherwise fire host code on the next host
# `git` invocation.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

source "$SCRIPT_DIR/../lib.sh"

SANDBOXED=$(build_fixture bound-git-config-ro.nix)
SHELL_BIN="$SANDBOXED/bin/sandboxed-bash"

TESTDIR_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)/.tmp-test"
mkdir -p "$TESTDIR_ROOT"
TESTDIR=$(mktemp -d "$TESTDIR_ROOT/git-identity-bound-config-ro.XXXXXX")
trap 'rm -rf "$TESTDIR"' EXIT

# Throwaway HOME with a [user] gitconfig at git's XDG-default global-config
# path. The fixture binds it via roFiles, so this is the read grant inside
# the sandbox.
FAKE_HOME="$TESTDIR/home"
mkdir -p "$FAKE_HOME/.config/git"
cat >"$FAKE_HOME/.config/git/config" <<'EOF'
[user]
	name = Bound Config RO User
	email = bound-config-ro@example.com
EOF

REPO="$TESTDIR/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q

echo "=== Git identity: read-only bound gitconfig (shared) ==="
echo

cd "$REPO"
capture env HOME="$FAKE_HOME" "$SHELL_BIN" -c 'git config --get user.email'
assert_exit_code "bound gitconfig is readable inside the sandbox" 0
assert_output_equals "user.email resolves from the bound gitconfig" \
	"bound-config-ro@example.com"

capture env HOME="$FAKE_HOME" "$SHELL_BIN" -c \
	'git commit --allow-empty -q -m bound-identity && git log -1 --format="%ae"'
assert_exit_code "commit succeeds with the bound identity" 0
assert_output_equals "commit attributed to the bound identity" \
	"bound-config-ro@example.com"

# The bound config is read-only: in-sandbox writes to it must fail. This is
# the whole point of preferring roFiles over rwDirs for git identity — it
# blocks the core.hooksPath / aliases / core.fsmonitor exfil vectors.
capture env HOME="$FAKE_HOME" "$SHELL_BIN" -c \
	'echo "[core]" >> $HOME/.config/git/config'
assert_exit_code "appending to bound gitconfig fails" 1

print_results
exit_status
