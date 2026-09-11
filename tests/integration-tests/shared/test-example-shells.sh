#!/usr/bin/env bash
# The example shells in shells/ and debug/ must still evaluate against the
# current library. They are the copy-paste surface of the README, and nothing
# else in the suite reads them, so a renamed or removed mkSandbox argument
# breaks them silently.
#
# The shells/ examples import the published tree from GitHub so that they work
# when copied out of the repository, which also means a local change cannot
# fail them: each is copied with that import rewritten to this checkout.
# debug/ already imports this checkout and is evaluated in place.
#
# Instantiating rather than building keeps it cheap: every check in this class
# (legacy arguments, port validation, unknown arguments) throws at eval time,
# and building would download an agent per shell.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

source "$SCRIPT_DIR/../lib.sh"

REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# The exact expression the copy-paste examples use to reach the published
# library. Substituting it is what points an example at this checkout.
IMPORT_EXPR='(fetchTarball "https://github.com/archie-judd/agent-sandbox.nix/archive/main.tar.gz")'

# Any other mention of the published repository means the file reaches it in a
# shape the substitution above misses. Failing beats evaluating against GitHub
# and calling it a pass. Files that already import this checkout (debug/) match
# neither and are evaluated where they sit.
PUBLISHED_REPO='github.com/archie-judd/agent-sandbox.nix'

# The examples resolve nixpkgs through <nixpkgs>, so pin it to the revision the
# flake locks rather than whatever channel the machine has, matching
# pinned-nixpkgs.nix.
NIXPKGS_URL=$(nix-instantiate --eval --raw -E "
  let
    lock = builtins.fromJSON (builtins.readFile ${REPO_ROOT}/flake.lock);
    n = lock.nodes.nixpkgs.locked;
  in \"https://github.com/\${n.owner}/\${n.repo}/archive/\${n.rev}.tar.gz\"
")

WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

# expect_shell_evaluates <path relative to REPO_ROOT>
expect_shell_evaluates() {
	local rel="$1"
	local src="$REPO_ROOT/$rel"
	local copy="$WORK_DIR/$(printf '%s' "$rel" | tr '/' '_')"
	local out

	if grep -qF "$IMPORT_EXPR" "$src"; then
		# An absolute path, because a relative one in the copy would resolve
		# against WORK_DIR rather than the checkout. `|` delimits because the
		# expression is full of slashes.
		sed "s|$IMPORT_EXPR|($REPO_ROOT)|" "$src" >"$copy"
	elif grep -qF "$PUBLISHED_REPO" "$src"; then
		echo "FAIL: $rel (reaches the published tree in a form this test does not rewrite, so it would not have been checked against this checkout)"
		FAIL=$((FAIL + 1))
		return
	else
		# Already imports this checkout, so it is evaluated where it sits: a
		# copy would break the relative path it uses to get here.
		copy="$src"
	fi

	if out=$(nix-instantiate -I "nixpkgs=$NIXPKGS_URL" "$copy" 2>&1); then
		echo "PASS: $rel evaluates"
		PASS=$((PASS + 1))
	else
		echo "FAIL: $rel did not evaluate"
		printf '%s\n' "$out" | sed 's/^/    /'
		FAIL=$((FAIL + 1))
	fi
}

echo "=== Example shells evaluate against this checkout (shared) ==="
echo

FOUND=0
for src in "$REPO_ROOT"/shells/*.nix "$REPO_ROOT"/debug/*.nix; do
	[ -e "$src" ] || continue
	FOUND=$((FOUND + 1))
	expect_shell_evaluates "${src#"$REPO_ROOT"/}"
done

# Guards against the globs silently matching nothing, which would report a
# clean pass while checking no examples at all.
if [ "$FOUND" -eq 0 ]; then
	echo "FAIL: no example shells found under shells/ or debug/"
	FAIL=$((FAIL + 1))
fi

print_results
exit_status
