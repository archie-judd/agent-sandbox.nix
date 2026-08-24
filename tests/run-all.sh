#!/usr/bin/env bash
# Run all sandbox tests
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OS=$(uname)

# One nix-build per unique fixture across the whole suite instead of one per
# test file. Removed at the end because out-links are GC roots.
TEST_BUILD_CACHE=$(mktemp -d)
export TEST_BUILD_CACHE
trap 'rm -rf "$TEST_BUILD_CACHE"' EXIT

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

# Run all shared tests
for test in "$SCRIPT_DIR/shared/"test-*.sh; do
	run_suite "$(basename "$test")" "shared/$(basename "$test")"
done

# Run platform-specific tests
if [ "$OS" = "Linux" ]; then
	for test in "$SCRIPT_DIR/linux/"test-*.sh; do
		run_suite "$(basename "$test") [Linux]" "linux/$(basename "$test")"
	done
elif [ "$OS" = "Darwin" ]; then
	for test in "$SCRIPT_DIR/darwin/"test-*.sh; do
		run_suite "$(basename "$test") [Darwin]" "darwin/$(basename "$test")"
	done
fi

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
