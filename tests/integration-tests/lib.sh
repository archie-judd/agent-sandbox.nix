#!/usr/bin/env bash
# Shared test utilities

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Shared with the unit suites, so it sits above this directory.
PINNED_NIXPKGS="$TESTS_DIR/../pinned-nixpkgs.nix"

PASS=0
FAIL=0

# Keep session directories out of the developer's real sessions root, whose
# prune would otherwise evict real sessions. Set here rather than in
# run-all.sh so a test file run on its own is scoped too; skipped when the
# caller has already chosen a root. Under gitignored .tmp-test rather than
# mktemp -d, so a failed test's session directory is still there to read.
if [ -z "${AGENT_SANDBOX_SESSIONS_ROOT:-}" ]; then
	AGENT_SANDBOX_SESSIONS_ROOT="$TESTS_DIR/../../.tmp-test/sessions/$(basename "$0")"
	export AGENT_SANDBOX_SESSIONS_ROOT
	rm -rf "$AGENT_SANDBOX_SESSIONS_ROOT"
	mkdir -p "$AGENT_SANDBOX_SESSIONS_ROOT"
fi

_usage_error() {
	echo "HARNESS ERROR: $*" >&2
	exit 2
}

# Build a derivation and print its store path, memoised into TEST_BUILD_CACHE
# when run-all.sh provides one; a test file run on its own simply builds.
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
	_build_memoised "host-$1" -E "(import $PINNED_NIXPKGS { }).$1"
}

# expect_ok <runner> <desc> <command>
# <command> is one shell script string, not an argv: call sites rely on &&,
# redirections, and $HOME expanded inside the sandbox. Passing more than one
# is refused rather than joined.
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

# Capture stdout, stderr and exit status into CAP_OUT / CAP_ERR / CAP_STATUS
# for the assert_* helpers: capture once, assert many.
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
