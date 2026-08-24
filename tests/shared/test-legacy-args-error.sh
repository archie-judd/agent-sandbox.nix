#!/usr/bin/env bash
# Legacy-argument migration errors (shared across platforms).
#
# Each removed/renamed mkSandbox argument (extraEnv, stateDirs, stateFiles,
# restrictNetwork) must fail at *eval* time with the migration message from
# shared.assertNoLegacyArgs — never silently build under the old name.
#
# We force the wrapper to WHNF with `builtins.seq wrapper "ok"`, which fires
# the assertNoLegacyArgs `seq` guard without realising the derivation (so no
# closure is built — the eval stays cheap).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

source "$SCRIPT_DIR/../lib.sh"

REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Evaluate mkSandbox with the given extra argument(s) spliced in. Returns
# nix-instantiate's exit code; stderr is folded into stdout for inspection.
eval_with() {
	local extra_args="$1"
	nix-instantiate --eval -E "
    let
      pkgs = import ${TESTS_DIR}/pinned-nixpkgs.nix { };
      sandbox = import ${REPO_ROOT}/default.nix { inherit pkgs; };
      wrapper = sandbox.mkSandbox {
        pkg = pkgs.bashInteractive;
        binName = \"bash\";
        outName = \"legacy-args-test\";
        allowedPackages = [ pkgs.coreutils ];
        ${extra_args}
      };
    in builtins.seq wrapper \"ok\"
  " 2>&1
}

# Assert that splicing `$extra` makes eval fail AND that the throw message
# contains `$needle` (so we know it failed for the migration reason, not some
# unrelated eval error).
expect_legacy_throw() {
	local desc="$1" extra="$2" needle="$3"
	local out
	if out=$(eval_with "$extra"); then
		echo "FAIL: $desc (eval succeeded; expected a migration error)"
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

echo "=== Legacy argument migration errors (shared) ==="
echo

# Control: a valid call (no legacy args) must evaluate cleanly. Guards against
# the throw cases passing for the wrong reason (e.g. a broken expression that
# would fail no matter what).
if eval_with '' >/dev/null; then
	echo "PASS: valid config evaluates without error"
	PASS=$((PASS + 1))
else
	echo "FAIL: valid config did not evaluate cleanly"
	eval_with '' | sed 's/^/    /' || true
	FAIL=$((FAIL + 1))
fi

expect_legacy_throw "extraEnv is rejected with migration hint" \
	'extraEnv = { };' "Use 'env' instead."
expect_legacy_throw "stateDirs is rejected with migration hint" \
	'stateDirs = [ ];' "Use 'rwDirs' instead."
expect_legacy_throw "stateFiles is rejected with migration hint" \
	'stateFiles = [ ];' "Use 'rwFiles' instead."
expect_legacy_throw "restrictNetwork is rejected with migration hint" \
	'restrictNetwork = true;' "'restrictNetwork' argument is deprecated"

print_results
exit_status
