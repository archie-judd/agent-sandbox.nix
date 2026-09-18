#!/usr/bin/env bash
# Test: allowNix = true against a nix daemon that does not sandbox its builds
# is allowed only after confirmation on /dev/tty, and refused outright with no
# terminal to ask on. The daemon runs outside the sandbox, so an unsandboxed
# builder runs with the build user's access to the host.
#
# Which branch runs depends on the host, and cannot be chosen here: the
# launcher reads the host's own nix config with NIX_CONFIG, NIX_CONF_DIR and
# the user's nix.conf stripped, because the daemon never read them either.
# sandbox defaults to true on Linux and false everywhere else, so CI covers
# both branches across its matrix.
#
# A trusted user is refused before any of that, and gets the third branch: it
# cannot be arranged here without root, but it is the posture a developer who
# installed nix single-handed is usually in, so the suite reports on it rather
# than failing mysteriously.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

source "$SCRIPT_DIR/../lib.sh"

NIX_SUPPORT=$(build_fixture nix-support.nix)
SHELL_BIN="$NIX_SUPPORT/bin/sandboxed-bash-nix-support"
HOST_PYTHON3=$(build_host_pkg python3Minimal)/bin/python3

TESTDIR_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)/.tmp-test"
mkdir -p "$TESTDIR_ROOT"
TESTDIR=$(mktemp -d "$TESTDIR_ROOT/nix-sandbox-confirm.XXXXXX")
trap 'rm -rf "$TESTDIR"' EXIT
cd "$TESTDIR"

# The same reads the launcher makes, so the assertions name what it saw.
HOST_SANDBOX=$(env -u NIX_CONFIG -u NIX_CONF_DIR NIX_USER_CONF_FILES= \
	nix --extra-experimental-features nix-command config show |
	awk '$1 == "sandbox" { print $3 }')
HOST_SANDBOX=${HOST_SANDBOX:-unreadable}

HOST_TRUSTED=$(env -u NIX_CONFIG -u NIX_CONF_DIR NIX_USER_CONF_FILES= \
	NIX_REMOTE=daemon nix --extra-experimental-features nix-command \
	store info --json 2>/dev/null |
	"$HOST_PYTHON3" -c 'import json, sys
print(json.load(sys.stdin).get("trusted"))' 2>/dev/null || true)

# No controlling terminal at all: os.setsid() detaches the session, so opening
# /dev/tty fails. setsid(1) is not portable to macOS.
run_no_tty() {
	"$HOST_PYTHON3" -c 'import os, sys; os.setsid(); os.execv(sys.argv[1], sys.argv[1:])' \
		"$@"
}

echo "=== allowNix daemon sandbox confirmation tests (shared) ==="
echo "host nix daemon: sandbox = $HOST_SANDBOX, trusted user = $HOST_TRUSTED"
echo

if [ "$HOST_TRUSTED" = "True" ]; then
	# Refused outright, so there is nothing to confirm and no prompt to feed.
	capture run_no_tty "$SHELL_BIN" --norc --noprofile -c 'echo LAUNCHED'
	assert_exit_code "refuses allowNix for a trusted user" 1
	assert_stderr_contains "the refusal names the trust" \
		"you are a trusted user of the host's nix daemon"
	assert_output_not_contains "the agent never ran" "LAUNCHED"
elif [ "$HOST_SANDBOX" = "true" ]; then
	# Nothing to confirm, so an unattended launch must still work.
	capture run_no_tty "$SHELL_BIN" --norc --noprofile -c 'echo LAUNCHED'
	assert_exit_code "a sandboxing daemon launches with no terminal" 0
	assert_output_contains "the agent ran" "LAUNCHED"
	assert_stderr_not_contains "nothing warned about the daemon" "your nix daemon"
else
	# 1. No terminal to confirm on: refuse rather than proceed unattended.
	capture run_no_tty "$SHELL_BIN" --norc --noprofile -c 'echo LAUNCHED'
	assert_exit_code "refuses with no terminal to confirm on" 1
	assert_stderr_contains "the refusal names what it read" \
		"sandbox = $HOST_SANDBOX"
	assert_stderr_contains "the refusal says why it stopped" \
		"no terminal to confirm on"
	assert_output_not_contains "the agent never ran" "LAUNCHED"

	# 2. Declining the prompt aborts.
	capture run_on_tty n "$SHELL_BIN" --norc --noprofile -c 'echo LAUNCHED'
	assert_exit_code "declining the confirmation aborts" 1
	assert_output_contains "the warning is about the host's daemon" \
		"your nix daemon"
	assert_output_contains "the warning says how to fix the host" \
		"set sandbox = true in /etc/nix/nix.conf"
	assert_output_not_contains "the agent never ran" "LAUNCHED"

	# 3. Confirming proceeds.
	capture run_on_tty y "$SHELL_BIN" --norc --noprofile -c 'echo LAUNCHED'
	assert_exit_code "confirming the prompt launches" 0
	assert_output_contains "the agent ran" "LAUNCHED"
fi

print_results
exit_status
