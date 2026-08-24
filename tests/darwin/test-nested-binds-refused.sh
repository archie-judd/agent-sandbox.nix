#!/usr/bin/env bash
# Test: a bind declared underneath another declared bind is refused at launch,
# and the real host file it names is left untouched.
#
# On macOS each declared path is planted into the ephemeral sandbox HOME as a
# symlink, in declaration order. Planting one that sits under an already
# planted bind used to walk through that bind's symlink and back out into the
# real home: `mkdir -p` created directories there, and `ln -sfn` unlinked the
# destination it resolved to. Where the declared file was itself a host symlink
# (a dotfiles setup) that destroyed it, leaving a link pointing at itself.
#
# The wrapper now walks the destination from the sandbox HOME down and refuses
# to launch if any component is already planted or already occupied.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

source "$SCRIPT_DIR/../lib.sh"

SANDBOXED=$(build_fixture nested-binds.nix)
SHELL_BIN="$SANDBOXED/bin/sandboxed-bash-nested-binds"

TESTDIR_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)/.tmp-test"
mkdir -p "$TESTDIR_ROOT"
TESTDIR=$(mktemp -d "$TESTDIR_ROOT/nested-binds.XXXXXX")

# HOME is overridden so the nested pair lives entirely inside the test's own
# tree. It is a sibling of the launch directory, not a parent: launching from
# above $HOME is refused outright (see test-home-cwd-confirm.sh).
FAKE_HOME=$(mktemp -d "$TESTDIR_ROOT/nested-binds-home.XXXXXX")
trap 'rm -rf "$TESTDIR" "$FAKE_HOME"' EXIT
cd "$TESTDIR"

BIND_ROOT="$FAKE_HOME/.agent-sandbox-nested-binds"
NESTED_FILE="$BIND_ROOT/git/config"
PAYLOAD="$FAKE_HOME/dotfiles/gitconfig"

mkdir -p "$BIND_ROOT/git" "$FAKE_HOME/dotfiles"
printf '[user]\n\tname = Test\n' > "$PAYLOAD"
PAYLOAD_REFERENCE="$TESTDIR/gitconfig.reference"
cp "$PAYLOAD" "$PAYLOAD_REFERENCE"
# The declared roFile is a symlink into dotfiles, which is the case that used
# to lose data: ln -sfn replaced it with a link pointing at itself.
ln -s "$PAYLOAD" "$NESTED_FILE"
NESTED_TARGET=$(readlink "$NESTED_FILE")

echo "=== Nested binds refused (darwin) ==="
echo

# The refusal happens before the EXIT trap that removes the ephemeral home is
# installed, so the refusal path has to clean up after itself.
SANDBOX_HOMES_BEFORE=$(find /private/tmp -maxdepth 1 -name 'sandbox-home.*' | sort)

capture env HOME="$FAKE_HOME" "$SHELL_BIN" -c 'echo unreachable'

assert_exit_code "nested bind: launch fails" 1
assert_output_not_contains "nested bind: command does not run" "unreachable"
assert_stderr_contains "nested bind: the nested path is named" "$NESTED_FILE"
assert_stderr_contains "nested bind: the containing bind is named" "$BIND_ROOT"
assert_stderr_contains "nested bind: labelled by its declaration" "declared as roFile"

# --- the real host file survives untouched ---
if [ -L "$NESTED_FILE" ] && [ "$(readlink "$NESTED_FILE")" = "$NESTED_TARGET" ]; then
	echo "PASS: nested bind: host symlink still points at its original target"
	PASS=$((PASS + 1))
else
	echo "FAIL: nested bind: host symlink was replaced (now: $(readlink "$NESTED_FILE" 2>&1 || echo 'not a symlink'))"
	FAIL=$((FAIL + 1))
fi

# Read through the declared path, not just the file behind it: the failure
# mode leaves the payload intact but makes the declared roFile unreadable.
if cmp -s "$NESTED_FILE" "$PAYLOAD_REFERENCE"; then
	echo "PASS: nested bind: declared file still reads byte-identical"
	PASS=$((PASS + 1))
else
	echo "FAIL: nested bind: declared file no longer reads as it did"
	FAIL=$((FAIL + 1))
fi

# Nothing may be created inside the real bind directory either: the old
# `mkdir -p` walked out there through the planted symlink.
EXPECTED_TREE=$(printf '%s\n%s\n' "$BIND_ROOT/git" "$NESTED_FILE" | sort)
ACTUAL_TREE=$(find "$BIND_ROOT" -mindepth 1 | sort)
if [ "$ACTUAL_TREE" = "$EXPECTED_TREE" ]; then
	echo "PASS: nested bind: nothing created under the real bind directory"
	PASS=$((PASS + 1))
else
	echo "FAIL: nested bind: real bind directory changed:"
	diff <(printf '%s\n' "$EXPECTED_TREE") <(printf '%s\n' "$ACTUAL_TREE") | sed 's/^/    /'
	FAIL=$((FAIL + 1))
fi

if [ "$(find /private/tmp -maxdepth 1 -name 'sandbox-home.*' | sort)" = "$SANDBOX_HOMES_BEFORE" ]; then
	echo "PASS: nested bind: no sandbox home left behind"
	PASS=$((PASS + 1))
else
	echo "FAIL: nested bind: sandbox home left behind"
	FAIL=$((FAIL + 1))
fi

print_results
exit_status
