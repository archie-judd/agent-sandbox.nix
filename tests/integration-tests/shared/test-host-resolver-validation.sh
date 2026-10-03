#!/usr/bin/env bash
# Nix-side validation only; no DNS listener or nested network namespace needed.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"

repo="$SCRIPT_DIR/../../.."

build_with_options() {
  local flag="$1" domains="$2"
  nix-build --no-out-link -E '
    let
      pkgs = import '"$repo"'/tests/pinned-nixpkgs.nix {};
      sandbox = import '"$repo"'/default.nix { inherit pkgs; };
    in sandbox.mkSandbox {
      pkg = pkgs.bash;
      binName = "bash";
      outName = "test-host-resolver-validation";
      allowedPackages = [ pkgs.bash ];
      useHostResolver = '"$flag"';
      allowedDomains = '"$domains"';
    }
  ' 2>&1
}

expect_valid() {
  local description="$1" flag="$2" domains="$3"
  if build_with_options "$flag" "$domains" >/dev/null; then
    echo "PASS: $description"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $description" >&2
    FAIL=$((FAIL + 1))
  fi
}

expect_invalid() {
  local description="$1" flag="$2" domains="$3" needle="$4" output
  if output=$(build_with_options "$flag" "$domains"); then
    echo "FAIL: $description (build succeeded)" >&2
    FAIL=$((FAIL + 1))
  elif grep -Fq "$needle" <<<"$output"; then
    echo "PASS: $description"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $description (missing error: $needle)" >&2
    printf '%s\n' "$output" >&2
    FAIL=$((FAIL + 1))
  fi
}

echo '=== useHostResolver validation ==='
expect_valid 'default mode unchanged' false null
expect_valid 'Linux open mode accepts host DNS' true null
expect_invalid 'only booleans accepted' '"yes"' null 'useHostResolver must be a boolean'
expect_invalid 'proxy mode rejects host DNS' true '[ "example.com" ]' 'useHostResolver requires Linux and open-network mode'
print_results
exit_status
