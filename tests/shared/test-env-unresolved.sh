#!/usr/bin/env bash
# Unresolvable `env` values (shared across platforms).
#
# Values declared in `env` are shell expressions the stub expands at launch. A
# value referencing an unset variable used to abort the stub with bash's own
# "unbound variable" message, which named the generated fragment's store path
# instead of the env attribute and stopped at the first failure.
#
# The gate in lib/stub.sh must report every unresolvable value against the
# attribute it came from, and must run before prepare, so a launch that cannot
# start leaves no session directory and no proxy behind.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

source "$SCRIPT_DIR/../lib.sh"

SANDBOXED=$(build_fixture env-unresolved.nix)

TESTDIR_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)/.tmp-test"
mkdir -p "$TESTDIR_ROOT"
TESTDIR=$(mktemp -d "$TESTDIR_ROOT/env-unresolved.XXXXXX")
trap 'rm -rf "$TESTDIR"' EXIT

PROJECT="$TESTDIR/project"
SESSIONS="$TESTDIR/sessions"
mkdir -p "$PROJECT" "$SESSIONS"
export AGENT_SANDBOX_LOG_DIR="$SESSIONS"

echo "=== Unresolvable env values (shared) ==="
echo

cd "$PROJECT"

export SANDBOX_TEST_RESOLVED="resolved-value"
unset SANDBOX_TEST_MISSING_ONE SANDBOX_TEST_MISSING_TWO

capture "$SANDBOXED/bin/sandboxed-bash" -c 'true'

assert_exit_code "launch fails when an env value cannot be resolved" 1
assert_stderr_contains "failure is reported with the sandbox error prefix" \
	"[ERROR][agent-sandbox.nix] could not resolve these env values:"

# Both, not just the first: bash's own errexit-on-unset stopped at one.
assert_stderr_contains "first unresolvable value is named by its env attribute" \
	'ENV_MISSING_ONE = "$SANDBOX_TEST_MISSING_ONE"'
assert_stderr_contains "second unresolvable value is named by its env attribute" \
	'ENV_MISSING_TWO = "$SANDBOX_TEST_MISSING_TWO"'

assert_stderr_not_contains "bash's raw unbound-variable message is not shown" \
	"unbound variable"
# The message must point at the user's config, not at generated Nix output.
assert_stderr_not_contains "the generated env fragment's store path is not shown" \
	"sandboxed-bash-env"

if [ -z "$(ls -A "$SESSIONS")" ]; then
	echo "PASS: no session directory is created when env resolution fails"
	PASS=$((PASS + 1))
else
	echo "FAIL: a session directory was created despite the launch failing"
	ls -A "$SESSIONS" | sed 's/^/    /'
	FAIL=$((FAIL + 1))
fi

# Control: with every referenced variable set, the launch proceeds and the
# values arrive intact. Without this the assertions above would pass just as
# well against a stub that refused every launch.
export SANDBOX_TEST_MISSING_ONE="one"
export SANDBOX_TEST_MISSING_TWO="two"

capture "$SANDBOXED/bin/sandboxed-bash" -c 'printf "%s|%s|%s" "$ENV_RESOLVED" "$ENV_SPACED" "$ENV_MISSING_ONE"'

assert_exit_code "launch succeeds once every referenced variable is set" 0
assert_output_equals "declared values reach the sandbox with quoting intact" \
	"resolved-value|a b  c|one"

print_results
exit_status
