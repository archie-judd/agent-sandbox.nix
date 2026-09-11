#!/usr/bin/env bash
# The Go unit tests. They live in proxy/ because Go only compiles _test.go
# files in the package's own directory; this is where they are run from.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
PINNED_NIXPKGS="$SCRIPT_DIR/../../pinned-nixpkgs.nix"

echo "=== Go unit tests ==="
echo

GO_BIN=$(nix-build --no-out-link -E "(import $PINNED_NIXPKGS { }).go")/bin/go

# The proxy has no module dependencies, so the tests run offline. Pinning the
# toolchain keeps it that way: without this, a go.mod directive newer than the
# nixpkgs Go would send the test run to the network for a toolchain.
export GOTOOLCHAIN=local

cd "$REPO_ROOT/proxy"
"$GO_BIN" test ./...
