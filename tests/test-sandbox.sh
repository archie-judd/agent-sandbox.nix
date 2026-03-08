#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OS=$(uname)

SANDBOXED=$(nix-build --no-out-link -E "
  let
    pkgs = import <nixpkgs> { };
    sandbox = import $SCRIPT_DIR/../default.nix { inherit pkgs; };
  in sandbox.mkSandbox {
    pkg = pkgs.bash;
    binName = \"bash\";
    outName = \"sandboxed-bash\";
    allowedPackages = [ pkgs.coreutils pkgs.bash ];
    stateDirs = [ \"\\\$HOME/.test-state-dir\" ];
    stateFiles = [ \"\\\$HOME/.test-state-file\" ];
    extraEnv = { TEST_VAR = \"test-value\"; };
  }
")
SHELL="$SANDBOXED/bin/sandboxed-bash"

run() { "$SHELL" --norc --noprofile -c "$@" >/dev/null 2>&1; }
run_output() { "$SHELL" --norc --noprofile -c "$@" 2>/dev/null; }

TESTDIR=$(mktemp -d)
trap 'rm -rf "$TESTDIR"' EXIT
cd "$TESTDIR"

PASS=0
FAIL=0

expect_ok() {
	local desc="$1"
	shift
	if run "$*"; then
		echo "PASS: $desc"
		PASS=$((PASS + 1))
	else
		echo "FAIL: $desc (should have succeeded)"
		FAIL=$((FAIL + 1))
	fi
}

expect_fail() {
	local desc="$1"
	shift
	if run "$*"; then
		echo "FAIL: $desc (should have been denied)"
		FAIL=$((FAIL + 1))
	else
		echo "PASS: $desc"
		PASS=$((PASS + 1))
	fi
}

echo "=== Sandbox tests ($OS) ==="
echo

# --- Isolation ---
expect_fail "cannot read ~/.ssh" "ls \$HOME/.ssh"
expect_fail "cannot read ~/.bash_history" "cat \$HOME/.bash_history"
expect_fail "cannot write to /nix/store" "touch /nix/store/test"
expect_fail "cannot read /root" "ls /root"

# --- Basic access ---
expect_ok "can write to CWD" "touch ./sandbox-test-file && rm ./sandbox-test-file"
expect_ok "can write to /tmp" "touch /tmp/sandbox-test && rm /tmp/sandbox-test"
expect_ok "can read /etc/resolv.conf" "cat /etc/resolv.conf > /dev/null"
expect_ok "can run allowed binaries" "ls / > /dev/null"

# --- stateDirs / stateFiles / extraEnv ---
expect_ok "can write to stateDir" "echo test > \$HOME/.test-state-dir/file && cat \$HOME/.test-state-dir/file"
expect_ok "can write to stateFile" "echo test > \$HOME/.test-state-file && cat \$HOME/.test-state-file"
expect_fail "stateDir does not weaken isolation" "ls \$HOME/.ssh"

if [ "$(run_output 'echo $TEST_VAR')" = "test-value" ]; then
	echo "PASS: extraEnv variable is accessible"
	PASS=$((PASS + 1))
else
	echo "FAIL: extraEnv variable not accessible"
	FAIL=$((FAIL + 1))
fi

# --- Environment isolation (env -i) ---
# Set a variable in the host that isn't in extraEnv and verify it's not propagated
export _TEST_HOST_VAR="should-not-propagate"
if [ -z "$(run_output 'echo $_TEST_HOST_VAR')" ]; then
	echo "PASS: host env vars not in extraEnv are not propagated"
	PASS=$((PASS + 1))
else
	echo "FAIL: host env var leaked into sandbox"
	FAIL=$((FAIL + 1))
fi

# --- Ephemeral HOME (both platforms) ---
expect_ok "home is empty tmpfs" "ls \$HOME"
expect_ok "home tmpfs is writable (ephemeral)" "touch \$HOME/.test-write && rm \$HOME/.test-write"
expect_fail "host dotfiles are not visible" "ls \$HOME/.bashrc"

# --- Platform-specific ---
if [ "$OS" = "Darwin" ]; then
	expect_fail "cannot write to /etc" "touch /etc/test"
	expect_ok "can exec /bin/sh subshell" "/bin/sh -c 'echo hello'"
elif [ "$OS" = "Linux" ]; then
	expect_ok "/etc is writable tmpfs (ephemeral)" "touch /etc/test && rm /etc/test"
	expect_fail "cannot read host /etc/shadow" "cat /etc/shadow"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
