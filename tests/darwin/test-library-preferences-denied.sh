#!/usr/bin/env bash
# Test: /Library/Preferences is not reachable from inside the sandbox.
# Regression for SANDBOX-FINDINGS.md §3 — the plists under that tree leak
# host identity (hostname, MAC addresses, paired Bluetooth devices, recent
# users, WiFi private-MAC rotation keys), and the previous (subpath
# "/Library/Preferences") allow made them all readable. /usr/bin/plutil
# was also exec-allowed, giving a one-liner extraction primitive.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

source "$SCRIPT_DIR/../lib.sh"

SANDBOXED=$(build_fixture basic-sandbox.nix)
SHELL="$SANDBOXED/bin/sandboxed-bash"

run() { "$SHELL" --norc --noprofile -c "$1" >/dev/null 2>&1; }

TESTDIR_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)/.tmp-test"
mkdir -p "$TESTDIR_ROOT"
TESTDIR=$(mktemp -d "$TESTDIR_ROOT/library-preferences-denied.XXXXXX")
trap 'rm -rf "$TESTDIR"' EXIT
cd "$TESTDIR"

# Pre-create the rwDir / rwFile declared by basic-sandbox.nix. The wrapper no
# longer creates declared bind paths automatically.
mkdir -p "$HOME/.test-state-dir"
touch "$HOME/.test-state-file"

echo "=== /Library/Preferences denied (Darwin) ==="
echo

expect_fail run "cannot stat /Library/Preferences" "test -d /Library/Preferences"
expect_fail run "cannot enumerate /Library/Preferences" "ls /Library/Preferences/"
expect_fail run "cannot read SystemConfiguration/preferences.plist" \
  "cat /Library/Preferences/SystemConfiguration/preferences.plist"
expect_fail run "cannot read NetworkInterfaces.plist" \
  "cat /Library/Preferences/SystemConfiguration/NetworkInterfaces.plist"
expect_fail run "cannot read loginwindow.plist" \
  "cat /Library/Preferences/com.apple.loginwindow.plist"

# /usr/bin/plutil was the one-liner extraction primitive — its exec allow
# is dropped too. Even if the file allow regressed, plutil shouldn't run.
expect_fail run "cannot exec /usr/bin/plutil" "/usr/bin/plutil -p /etc/hosts"

# Sanity: the rest of the system-library allow set still works, so we
# know we narrowed only /Library/Preferences and didn't break /usr/lib
# or /System reads (which would break almost everything on macOS).
expect_ok run "can read /usr/lib" "test -d /usr/lib && ls /usr/lib >/dev/null"
expect_ok run "can read /System/Library" "test -d /System/Library"

print_results
exit_status
