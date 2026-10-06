#!/usr/bin/env bash
# allowHeadlessBrowsers validation, enforced at eval time: it must be a list
# of distinct, known engines. Same mechanism as
# test-legacy-args-error.sh: `builtins.seq wrapper "ok"` fires the
# validation seqs without realising the derivation.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

source "$SCRIPT_DIR/../lib.sh"

REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# Evaluate mkSandbox with the given extra argument(s) spliced in. Returns
# nix-instantiate's exit code; stderr is folded into stdout for inspection.
eval_with() {
	local extra_args="$1"
	nix-instantiate --eval -E "
    let
      pkgs = import ${PINNED_NIXPKGS} { };
      sandbox = import ${REPO_ROOT}/default.nix { inherit pkgs; };
      wrapper = sandbox.mkSandbox {
        pkg = pkgs.bashInteractive;
        binName = \"bash\";
        outName = \"allow-headless-browsers-test\";
        allowedPackages = [ pkgs.coreutils ];
        ${extra_args}
      };
    in builtins.seq wrapper \"ok\"
  " 2>&1
}

expect_eval_ok() {
	local desc="$1" extra="$2"
	local out
	if out=$(eval_with "$extra"); then
		echo "PASS: $desc"
		PASS=$((PASS + 1))
	else
		echo "FAIL: $desc (eval failed)"
		printf '%s\n' "$out" | sed 's/^/    /'
		FAIL=$((FAIL + 1))
	fi
}

expect_eval_throw() {
	local desc="$1" extra="$2" needle="$3"
	local out
	if out=$(eval_with "$extra"); then
		echo "FAIL: $desc (eval succeeded; expected a validation error)"
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

echo "=== allowHeadlessBrowsers validation (shared) ==="
echo

expect_eval_ok "default (omitted) evaluates" ""
expect_eval_ok "empty list evaluates" \
	'allowHeadlessBrowsers = [ ];'
expect_eval_ok "chromium alone evaluates" \
	'allowHeadlessBrowsers = [ "chromium" ];'
expect_eval_ok "firefox alone evaluates" \
	'allowHeadlessBrowsers = [ "firefox" ];'
expect_eval_ok "both engines evaluate" \
	'allowHeadlessBrowsers = [ "chromium" "firefox" ];'
expect_eval_throw "true is rejected" \
	'allowHeadlessBrowsers = true;' "allowHeadlessBrowsers must be a list of browser engines"
expect_eval_throw "false is rejected" \
	'allowHeadlessBrowsers = false;' "allowHeadlessBrowsers must be a list of browser engines"
expect_eval_throw "unknown engine is rejected" \
	'allowHeadlessBrowsers = [ "chrome" ];' "allowHeadlessBrowsers entries must each be one of"
expect_eval_throw "non-string entry is rejected" \
	'allowHeadlessBrowsers = [ 1 ];' "allowHeadlessBrowsers entries must each be one of"
expect_eval_throw "repeated engine is rejected" \
	'allowHeadlessBrowsers = [ "firefox" "firefox" ];' "must not repeat an engine"

print_results
exit_status
