#!/usr/bin/env bash
# Unit tests for the filtering proxy (Go, no sandbox launch).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== Proxy unit tests (shared) ==="
echo

GO_BIN=$(nix-build --no-out-link '<nixpkgs>' -A go)/bin/go

# The proxy has no module dependencies, so the tests run offline. Pinning the
# toolchain keeps it that way: without this, a go.mod directive newer than the
# nixpkgs Go would send the test run to the network for a toolchain.
export GOTOOLCHAIN=local

cd "$SCRIPT_DIR/../../proxy"
"$GO_BIN" test ./...
