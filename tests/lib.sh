#!/usr/bin/env bash
# Shared test utilities

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PASS=0
FAIL=0

_usage_error() {
	echo "HARNESS ERROR: $*" >&2
	exit 2
}

# Build a derivation and print its store path, memoised into TEST_BUILD_CACHE
# when the harness provides one. run-all.sh exports a cache so one evaluation
# is shared by every test file in a suite run; a test file run on its own has
# no cache and simply builds. The cache is per-run rather than persistent, so
# an edit under lib/ is always picked up.
_build_memoised() {
	local key="$1"
	shift
	if [ -z "${TEST_BUILD_CACHE:-}" ]; then
		nix-build --no-out-link "$@"
		return
	fi
	local link
	link="$TEST_BUILD_CACHE/$(printf '%s' "$key" | tr -c 'A-Za-z0-9._-' '_')"
	[ -e "$link" ] || nix-build --out-link "$link" "$@" >/dev/null
	readlink "$link"
}

# build_fixture <fixture.nix> [nix-build args...]
build_fixture() {
	local fixture="$1"
	shift
	_build_memoised "$fixture $*" "$TESTS_DIR/fixtures/$fixture" "$@"
}

# build_host_pkg <attr> — for the host-side tools tests run outside the
# sandbox. The argument is appended to `(import pinned-nixpkgs.nix { }).`, so
# both `python3Minimal` and `writeText "name" "body"` are valid.
build_host_pkg() {
	_build_memoised "host-$1" -E "(import $TESTS_DIR/pinned-nixpkgs.nix { }).$1"
}

# expect_ok <runner> <desc> <command>
#
# <runner> is a function or command taking the command as its single argument.
# Each test file declares its own and names it at every call site, so a file
# that asserts against more than one sandbox says which one it means at the
# point it means it.
#
# <command> is one shell script string, not an argv: call sites rely on &&,
# redirections, and $HOME expanded inside the sandbox rather than out here.
# Passing more than one is a mistake, so it is refused rather than joined.
expect_ok() {
	[ "$#" -eq 3 ] || _usage_error "expect_ok takes <runner> <desc> <command>, got $# arguments"
	local runner="$1" desc="$2" command="$3"
	if "$runner" "$command"; then
		echo "PASS: $desc"
		PASS=$((PASS + 1))
	else
		echo "FAIL: $desc (should have succeeded)"
		FAIL=$((FAIL + 1))
	fi
}

expect_fail() {
	[ "$#" -eq 3 ] || _usage_error "expect_fail takes <runner> <desc> <command>, got $# arguments"
	local runner="$1" desc="$2" command="$3"
	if "$runner" "$command"; then
		echo "FAIL: $desc (should have been denied)"
		FAIL=$((FAIL + 1))
	else
		echo "PASS: $desc"
		PASS=$((PASS + 1))
	fi
}

expect_status() {
	[ "$#" -eq 4 ] || _usage_error "expect_status takes <runner> <desc> <expected> <command>, got $# arguments"
	local runner="$1" desc="$2" expected="$3" command="$4" status
	if "$runner" "$command"; then
		status=0
	else
		status=$?
	fi
	if [ "$status" -eq "$expected" ]; then
		echo "PASS: $desc"
		PASS=$((PASS + 1))
	else
		echo "FAIL: $desc (exit $status, expected $expected)"
		FAIL=$((FAIL + 1))
	fi
}

# Run a command, capturing its stdout, stderr, and exit status separately into
# CAP_OUT / CAP_ERR / CAP_STATUS for the assert_* helpers below. Capture once,
# then assert many — so a side-effecting command (e.g. `git commit`) runs only
# once even when several properties are checked.
capture() {
	local _out _err
	_out=$(mktemp)
	_err=$(mktemp)
	CAP_STATUS=0
	"$@" >"$_out" 2>"$_err" || CAP_STATUS=$?
	CAP_OUT=$(cat "$_out")
	CAP_ERR=$(cat "$_err")
	rm -f "$_out" "$_err"
}

assert_exit_code() {
	local desc="$1" expected="$2"
	if [ "$CAP_STATUS" -eq "$expected" ]; then
		echo "PASS: $desc"
		PASS=$((PASS + 1))
	else
		echo "FAIL: $desc (exit $CAP_STATUS, expected $expected)"
		FAIL=$((FAIL + 1))
	fi
}

assert_output_equals() {
	local desc="$1" expected="$2"
	if [ "$CAP_OUT" = "$expected" ]; then
		echo "PASS: $desc"
		PASS=$((PASS + 1))
	else
		echo "FAIL: $desc (got '$CAP_OUT', expected '$expected')"
		FAIL=$((FAIL + 1))
	fi
}

assert_output_contains() {
	local desc="$1" needle="$2"
	if printf '%s' "$CAP_OUT" | grep -qF "$needle"; then
		echo "PASS: $desc"
		PASS=$((PASS + 1))
	else
		echo "FAIL: $desc (stdout missing: $needle)"
		printf '%s\n' "$CAP_OUT" | sed 's/^/    /'
		FAIL=$((FAIL + 1))
	fi
}

assert_output_not_contains() {
	local desc="$1" needle="$2"
	if printf '%s' "$CAP_OUT" | grep -qF "$needle"; then
		echo "FAIL: $desc (stdout unexpectedly contains: $needle)"
		printf '%s\n' "$CAP_OUT" | sed 's/^/    /'
		FAIL=$((FAIL + 1))
	else
		echo "PASS: $desc"
		PASS=$((PASS + 1))
	fi
}

assert_stderr_contains() {
	local desc="$1" needle="$2"
	if printf '%s' "$CAP_ERR" | grep -qF "$needle"; then
		echo "PASS: $desc"
		PASS=$((PASS + 1))
	else
		echo "FAIL: $desc (stderr missing: $needle)"
		printf '%s\n' "$CAP_ERR" | sed 's/^/    /'
		FAIL=$((FAIL + 1))
	fi
}

assert_stderr_not_contains() {
	local desc="$1" needle="$2"
	if printf '%s' "$CAP_ERR" | grep -qF "$needle"; then
		echo "FAIL: $desc (stderr unexpectedly contains: $needle)"
		printf '%s\n' "$CAP_ERR" | sed 's/^/    /'
		FAIL=$((FAIL + 1))
	else
		echo "PASS: $desc"
		PASS=$((PASS + 1))
	fi
}

print_results() {
	echo
	echo "=== Results: $PASS passed, $FAIL failed ==="
}

exit_status() {
	[ "$FAIL" -eq 0 ]
}
