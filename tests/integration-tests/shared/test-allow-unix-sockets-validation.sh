#!/usr/bin/env bash
# allowUnixSockets validation, enforced at eval time: it must be a boolean,
# and allowNix = true requires it. Same mechanism as
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
        outName = \"allow-unix-sockets-test\";
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

echo "=== allowUnixSockets validation (shared) ==="
echo

expect_eval_ok "default (flag omitted) evaluates" ""
expect_eval_ok "allowUnixSockets = true evaluates" \
	'allowUnixSockets = true;'
expect_eval_ok "allowNix with allowUnixSockets evaluates" \
	'allowNix = true; allowUnixSockets = true;'
expect_eval_throw "allowNix without allowUnixSockets is rejected" \
	'allowNix = true;' "allowNix = true requires allowUnixSockets = true"
expect_eval_throw "allowNix with explicit allowUnixSockets = false is rejected" \
	'allowNix = true; allowUnixSockets = false;' \
	"allowNix = true requires allowUnixSockets = true"
expect_eval_throw "non-boolean allowUnixSockets is rejected" \
	'allowUnixSockets = "yes";' "allowUnixSockets must be a boolean"

print_results
exit_status
