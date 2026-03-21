#!/usr/bin/env bash
# Test that bash-interactive warning is shown on darwin
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OS=$(uname)

source "$SCRIPT_DIR/lib.sh"

echo "=== Bash-interactive warning test ($OS) ==="
echo

# Only test on darwin where the warning applies
if [ "$OS" != "Darwin" ]; then
	echo "SKIP: bash-interactive warning only applies on Darwin"
	exit 0
fi

# Build sandbox with bash-interactive
SANDBOXED=$(nix-build --no-out-link "$SCRIPT_DIR/bash-interactive-warning.nix")
SHELL="$SANDBOXED/bin/sandboxed-bash-interactive"

# Run the wrapper and capture stderr
STDERR_OUTPUT=$("$SHELL" -c "echo test" 2>&1 >/dev/null || true)

# Check if the warning appears
if echo "$STDERR_OUTPUT" | grep -q "bash-interactive will try to load profile files"; then
	echo "PASS: bash-interactive warning displayed"
	PASS=$((PASS + 1))
else
	echo "FAIL: bash-interactive warning not displayed"
	echo "Got stderr: $STDERR_OUTPUT"
	FAIL=$((FAIL + 1))
fi

# Check that bashNonInteractive doesn't produce the warning
SANDBOXED_NON=$(nix-build --no-out-link "$SCRIPT_DIR/basic-sandbox.nix")
SHELL_NON="$SANDBOXED_NON/bin/sandboxed-bash"
STDERR_NON=$("$SHELL_NON" -c "echo test" 2>&1 >/dev/null || true)

if echo "$STDERR_NON" | grep -q "bash-interactive"; then
	echo "FAIL: bashNonInteractive should not produce warning"
	echo "Got stderr: $STDERR_NON"
	FAIL=$((FAIL + 1))
else
	echo "PASS: bashNonInteractive does not produce warning"
	PASS=$((PASS + 1))
fi

print_results
exit_status
