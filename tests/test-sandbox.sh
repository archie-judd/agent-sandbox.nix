#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Build a sandboxed shell — same shape as a real agent wrapper
# but using bash so we can run arbitrary test commands inside.
SANDBOXED=$(nix-build --no-out-link -E "
  let
    pkgs = import <nixpkgs> { };
    sandbox = import $SCRIPT_DIR/sandbox.nix { inherit pkgs; };
  in sandbox.mkSandbox {
    pkg = pkgs.bash;
    binName = \"bash\";
    outName = \"sandboxed-bash\";
    allowedPackages = [ pkgs.coreutils pkgs.bash ];
    stateDirs = [ ];
  }
")

TESTDIR=$(mktemp -d)
trap 'rm -rf "$TESTDIR"' EXIT
cd "$TESTDIR"

SHELL="$SANDBOXED/bin/sandboxed-bash"
PASS=0
FAIL=0

expect_fail() {
	local desc="$1"
	shift
	if "$SHELL" -c "$*" 2>/dev/null; then
		echo "FAIL: $desc (should have been denied)"
		FAIL=$((FAIL + 1))
	else
		echo "PASS: $desc"
		PASS=$((PASS + 1))
	fi
}

expect_ok() {
	local desc="$1"
	shift
	if "$SHELL" -c "$*" 2>/dev/null; then
		echo "PASS: $desc"
		PASS=$((PASS + 1))
	else
		echo "FAIL: $desc (should have succeeded)"
		FAIL=$((FAIL + 1))
	fi
}

echo "=== Sandbox isolation tests ==="
echo

# --- Should be denied ---
expect_fail "cannot read ~/.ssh" "ls \$HOME/.ssh"
expect_fail "cannot read ~/.bash_history" "cat \$HOME/.bash_history"
expect_fail "cannot write to /etc" "touch /etc/test"
expect_fail "cannot write to /nix/store" "touch /nix/store/test"
expect_fail "cannot read /root" "ls /root"
expect_fail "cannot write to home" "touch \$HOME/.test-write"

# --- Should be allowed ---
expect_ok "can write to CWD" "touch ./sandbox-test-file && rm ./sandbox-test-file"
expect_ok "can write to /tmp" "touch /tmp/sandbox-test && rm /tmp/sandbox-test"
expect_ok "can read /etc/resolv.conf" "cat /etc/resolv.conf > /dev/null"
expect_ok "can run allowed binaries" "ls / > /dev/null"

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
