#!/usr/bin/env bash
# Test: launching from $HOME exposes the whole home read-write, so it is
# allowed only after confirmation on /dev/tty, and refused outright with no
# terminal to ask on. A launch directory above $HOME is refused either way.
# Also covers a declared roFile that is a nix store symlink under a home CWD,
# which bwrap cannot mount over. HOME is pointed at a throwaway directory, so
# nothing touches the real home.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

source "$SCRIPT_DIR/../lib.sh"

SANDBOXED=$(build_fixture bound-git-config-ro.nix)
SHELL="$SANDBOXED/bin/sandboxed-bash"

HOST_PYTHON3=$(build_host_pkg python3Minimal)/bin/python3
STORE_GITCONFIG=$(build_host_pkg 'writeText "test-home-cwd-gitconfig" "[user]\n\tname = Test\n\temail = test@test.com\n"')

# The fake HOME must NOT be under /tmp, which each platform treats as a
# special case — that would mask the assertions below.
TESTDIR_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)/.tmp-test"
mkdir -p "$TESTDIR_ROOT"
FAKE_HOME=$(mktemp -d "$TESTDIR_ROOT/home-cwd.XXXXXX")
trap 'rm -rf "$FAKE_HOME"' EXIT

# A store symlink at the declared roFile path, as home-manager leaves it.
mkdir -p "$FAKE_HOME/.config/git"
ln -s "$STORE_GITCONFIG" "$FAKE_HOME/.config/git/config"
echo "home-secret-content" >"$FAKE_HOME/secret.txt"
mkdir -p "$FAKE_HOME/project"

# Make the fake home its own git repo. This dir lives under .tmp-test inside
# the checkout, so otherwise the nearest .git walking up is the project's own,
# whose root sits above $HOME — the wrapper's git-root guard would refuse to
# expose it and disable git, and on darwin the still-visible-but-denied
# ancestor .git turns the in-sandbox `git var` into a fatal. As its own repo,
# the nearest root is $HOME itself: the supported launch-from-a-home-repo case.
git init -q "$FAKE_HOME"

# Answer the confirmation prompt over a pty. The wrapper reads the reply from
# /dev/tty, so piping it on stdin deliberately does not satisfy the prompt.
# pty.spawn merges the child's stderr into its stdout, so assertions about
# wrapper messages look at CAP_OUT for these runs.
run_tty() {
  local reply="$1" home="$2" cwd="$3"
  shift 3
  printf '%s\n' "$reply" | (cd "$cwd" && HOME="$home" "$HOST_PYTHON3" -c \
    'import os, pty, sys; sys.exit(os.waitstatus_to_exitcode(pty.spawn(sys.argv[1:])))' \
    "$SHELL" --norc --noprofile -c "$1")
}

# Same launch with no controlling terminal at all: os.setsid() detaches the
# session, so opening /dev/tty fails. setsid(1) is not portable to macOS.
run_no_tty() {
  local home="$1" cwd="$2"
  shift 2
  (cd "$cwd" && HOME="$home" "$HOST_PYTHON3" -c \
    'import os, sys; os.setsid(); os.execv(sys.argv[1], sys.argv[1:])' \
    "$SHELL" --norc --noprofile -c "$1")
}

# A launch that must not prompt at all: no pty, no reply.
run_plain() {
  local home="$1" cwd="$2"
  shift 2
  (cd "$cwd" && HOME="$home" "$SHELL" --norc --noprofile -c "$1")
}

echo "=== launching from \$HOME tests (shared) ==="
echo

# 1. No terminal to confirm on: refuse rather than proceed unattended.
capture run_no_tty "$FAKE_HOME" "$FAKE_HOME" 'echo LAUNCHED'
assert_exit_code "refuses to launch from \$HOME with no tty" 1
assert_stderr_contains "explains why it refused" "no terminal to confirm on"
assert_output_not_contains "agent never ran" "LAUNCHED"

# 2. Declining the prompt aborts.
capture run_tty n "$FAKE_HOME" "$FAKE_HOME" 'echo LAUNCHED'
assert_exit_code "declining the confirmation aborts" 1
assert_output_not_contains "agent never ran after declining" "LAUNCHED"

# 3. Bare Enter defaults to no.
capture run_tty "" "$FAKE_HOME" "$FAKE_HOME" 'echo LAUNCHED'
assert_exit_code "empty answer defaults to declining" 1
assert_output_not_contains "agent never ran on empty answer" "LAUNCHED"

# 4. Confirming launches, warns loudly, and exposes the home read-write.
capture run_tty y "$FAKE_HOME" "$FAKE_HOME" '
	cat "$HOME/.config/git/config" >/dev/null && echo ROFILE-OK
	cat ./secret.txt >/dev/null && echo HOME-READ-OK
	touch ./written && echo HOME-WRITE-OK
	git var GIT_AUTHOR_IDENT >/dev/null && echo IDENT-OK'
assert_exit_code "confirming launches the sandbox" 0
assert_output_contains "warns that the home is not masked" "not masked in this session"
assert_output_contains "store-symlink roFile is readable from a home CWD" "ROFILE-OK"
assert_output_contains "home is readable" "HOME-READ-OK"
assert_output_contains "home is writable" "HOME-WRITE-OK"
assert_output_contains "git identity resolves from the bound gitconfig" "IDENT-OK"

# 5. A home-rooted repo (FAKE_HOME is a repo, set up above) keeps git, since the
#    home is exposed by consent already. Its hooks and config stay read-only
#    (git hook injection).
capture run_tty y "$FAKE_HOME" "$FAKE_HOME" '
	git rev-parse --show-toplevel
	git --no-pager config core.hooksPath /tmp/evil || echo HOOKS-PATH-DENIED'
assert_exit_code "home-rooted repo launches from \$HOME" 0
assert_output_not_contains "git is not disabled for a home-rooted repo" "git is disabled"
assert_output_contains "git resolves the home repo" "$FAKE_HOME"
assert_output_contains "git config stays read-only" "HOOKS-PATH-DENIED"

# 6. Above $HOME is refused even with a terminal to confirm on: those paths are
#    not the user's to hand over. HOME moves down a level so that CWD (the
#    unchanged FAKE_HOME) is strictly above it.
mkdir -p "$FAKE_HOME/inner/.config/git"
ln -s "$STORE_GITCONFIG" "$FAKE_HOME/inner/.config/git/config"
capture run_tty y "$FAKE_HOME/inner" "$FAKE_HOME" 'echo LAUNCHED'
assert_exit_code "refuses a launch directory above \$HOME" 1
assert_output_contains "explains why it refused" "sits above your home directory"
assert_output_not_contains "agent never ran from above \$HOME" "LAUNCHED"

# 7. Non-regression: a subdir of home is the ordinary case. No prompt, and the
#    home is masked as usual.
capture run_plain "$FAKE_HOME" "$FAKE_HOME/project" '
	echo LAUNCHED
	if cat "$HOME/secret.txt" >/dev/null 2>&1; then echo HOME-LEAKED; fi'
assert_exit_code "launching from a subdir of home still works" 0
assert_output_contains "agent ran without a prompt" "LAUNCHED"
assert_stderr_not_contains "no home-exposure warning from a subdir" "not masked in this session"
assert_output_not_contains "home stays masked from a subdir" "HOME-LEAKED"

print_results
exit_status
