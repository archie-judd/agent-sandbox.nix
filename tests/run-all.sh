#!/usr/bin/env bash
# Run all sandbox tests
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

FAILED_SUITES=()

run_suite() {
	local name="$1"
	local script="$2"
	echo
	echo "========================================"
	echo "Running: $name"
	echo "========================================"
	if "$SCRIPT_DIR/$script"; then
		echo "Suite passed: $name"
	else
		echo "Suite FAILED: $name"
		FAILED_SUITES+=("$name")
	fi
}

run_suite "Basic sandbox tests" "test-basic.sh"
run_suite "stateDir/stateFile and symlink resolution tests" "test-symlinks.sh"
run_suite "Nix store isolation tests" "test-nix-store-isolation.sh"
run_suite "Network restriction tests" "test-network.sh"
run_suite "exposeRepoRoot tests" "test-expose-repo-root.sh"
run_suite "Deep CWD ancestor traversal tests" "test-deep-cwd.sh"

echo
echo "========================================"
echo "All test suites completed"
echo "========================================"

if [ ${#FAILED_SUITES[@]} -eq 0 ]; then
	echo "All suites passed."
	exit 0
else
	echo "Failed suites: ${FAILED_SUITES[*]}"
	exit 1
fi
