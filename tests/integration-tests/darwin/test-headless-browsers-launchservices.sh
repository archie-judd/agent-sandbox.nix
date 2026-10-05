#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEST_CWD="$(cd "$SCRIPT_DIR/../../.." && pwd)"

source "$SCRIPT_DIR/../lib.sh"

PROBE="$SCRIPT_DIR/../helpers/inside-launchservices-probe.py"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister
SCHEME="sbxtest-$$"

SANDBOXED=$(build_fixture headless-browser.nix --argstr browser chrome)
SHELL_BIN="$SANDBOXED/bin/sandboxed-bash-headless-browser"
HOST_PYTHON3=$(build_host_pkg python3)/bin/python3

TESTDIR_ROOT="$TEST_CWD/.tmp-test"
mkdir -p "$TESTDIR_ROOT"
TESTDIR=$(mktemp -d "$TESTDIR_ROOT/headless-browsers-launchservices.XXXXXX")
MARKER_DIR=$(mktemp -d)

cleanup() {
	"$LSREGISTER" -u "$TESTDIR/Sbx.app" 2>/dev/null || true
	rm -rf "$TESTDIR" "$MARKER_DIR"
	return 0
}
trap cleanup EXIT

printf '#!/bin/sh\ntouch "%s/escaped"\n' "$MARKER_DIR" >"$TESTDIR/escape.command"
chmod +x "$TESTDIR/escape.command"

mkdir -p "$TESTDIR/Sbx.app/Contents/MacOS"
printf '#!/bin/sh\ntouch "%s/handled"\n' "$MARKER_DIR" >"$TESTDIR/Sbx.app/Contents/MacOS/sbx"
chmod +x "$TESTDIR/Sbx.app/Contents/MacOS/sbx"
cat >"$TESTDIR/Sbx.app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>test.$SCHEME</string>
  <key>CFBundleExecutable</key><string>sbx</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleURLTypes</key><array><dict>
    <key>CFBundleURLSchemes</key><array><string>$SCHEME</string></array>
  </dict></array>
</dict></plist>
EOF

run() {
	(cd "$TEST_CWD" && "$SHELL_BIN" --norc --noprofile -c "$1") >/dev/null 2>&1
}

run_host() {
	bash -c "$1" >/dev/null 2>&1
}

echo "=== allowHeadlessBrowsers: LaunchServices stays closed (Darwin) ==="
echo

expect_ok run_host "probe resolves Calculator on the host" \
	"'$HOST_PYTHON3' '$PROBE' bundle com.apple.calculator"

expect_fail run "sandbox cannot open Calculator" \
	"python3 '$PROBE' open /System/Applications/Calculator.app"

expect_fail run "sandbox cannot open a .command file" \
	"python3 '$PROBE' open '$TESTDIR/escape.command'"

expect_fail run "sandbox cannot register an app bundle" \
	"python3 '$PROBE' register '$TESTDIR/Sbx.app'"

expect_fail run "sandbox cannot read the LaunchServices database" \
	"python3 '$PROBE' bundle com.apple.calculator"

sleep 3

expect_fail run_host "nothing ran on the host from the .command file" \
	"test -e '$MARKER_DIR/escaped'"

expect_fail run_host "host has no handler for the scheme the sandbox registered" \
	"'$HOST_PYTHON3' '$PROBE' handler '$SCHEME://x'"

print_results
exit_status
