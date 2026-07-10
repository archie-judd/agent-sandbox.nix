#!/usr/bin/env bash
# Shared test utilities

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

expect_status() {
	local desc="$1" expected="$2" status
	shift 2
	if run "$*"; then
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
