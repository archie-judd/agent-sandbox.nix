#!/usr/bin/env bash
# workspaceDir accepts a string that can become an absolute path. Nix cannot
# expand "$VAR", so all it checks is the first character; the launcher refuses
# what an expansion actually resolves to.
#
# null is refused by name rather than ignored: there is no no-workspace state,
# and "workspaceDir = null" is the obvious thing to reach for if you assume
# there is one.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

source "$SCRIPT_DIR/../lib.sh"

# Not build_fixture: the build is what this file asserts on, so it must run
# every time and its failure output is the subject rather than an error.
build_with() {
	nix-build --no-out-link "$@" "$SCRIPT_DIR/../fixtures/workspace-dir.nix" 2>&1
}

expect_valid() {
	local desc="$1"
	shift
	local out
	if out=$(build_with "$@"); then
		echo "PASS: $desc"
		PASS=$((PASS + 1))
	else
		echo "FAIL: $desc (build failed)"
		printf '%s\n' "$out" | sed 's/^/    /'
		FAIL=$((FAIL + 1))
	fi
}

expect_invalid() {
	local desc="$1" needle="$2"
	shift 2
	local out
	if out=$(build_with "$@"); then
		echo "FAIL: $desc (build succeeded; expected validation error)"
		FAIL=$((FAIL + 1))
	elif printf '%s' "$out" | grep -qF "$needle"; then
		echo "PASS: $desc"
		PASS=$((PASS + 1))
	else
		echo "FAIL: $desc (threw, but message missing: $needle)"
		printf '%s\n' "$out" | sed 's/^/    /'
		FAIL=$((FAIL + 1))
	fi
}

echo "=== workspaceDir validation ==="
echo

expect_valid "the default is accepted" --argstr workspaceDir '$PWD'
expect_valid "an absolute path is accepted" --argstr workspaceDir /tmp/workspace
expect_valid "a \$VAR reference is accepted" --argstr workspaceDir '$HOME/project'
expect_valid "a ~ path is accepted" --argstr workspaceDir '~/project'

expect_invalid "a relative path is refused" \
	"workspaceDir must be an absolute path" \
	--argstr workspaceDir .
expect_invalid "a bare name is refused" \
	"workspaceDir must be an absolute path" \
	--argstr workspaceDir project
expect_invalid "an empty string is refused" \
	"workspaceDir must be an absolute path" \
	--argstr workspaceDir ""
expect_invalid "null is refused" \
	"workspaceDir must be a string holding an absolute path" \
	--arg workspaceDir null

print_results
exit_status
