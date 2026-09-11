#!/usr/bin/env bash
# The Python unit tests, which live beside this script.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
PINNED_NIXPKGS="$SCRIPT_DIR/../../pinned-nixpkgs.nix"

echo "=== Python unit tests ==="
echo

PYTEST=$(nix-build --no-out-link \
	-E "(import $PINNED_NIXPKGS { }).python3.withPackages (ps: [ ps.pytest ])")/bin/pytest

# PYTHONPATH because the launcher is not installed: Nix copies the source tree
# into the store and the stub points PYTHONPATH at it.
PYTHONPATH="$REPO_ROOT" "$PYTEST" -q -p no:cacheprovider "$SCRIPT_DIR"
