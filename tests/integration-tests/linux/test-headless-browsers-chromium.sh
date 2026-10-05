#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEST_CWD="$(cd "$SCRIPT_DIR/../../.." && pwd)"

source "$SCRIPT_DIR/../lib.sh"

DRIVER_PORT=18950
MARIONETTE_PORT=18951
WEBSOCKET_PORT=18952

for port in "$DRIVER_PORT" "$MARIONETTE_PORT" "$WEBSOCKET_PORT"; do
	if nc -z 127.0.0.1 "$port" 2>/dev/null; then
		echo "FAIL: test setup — 127.0.0.1:$port already in use" >&2
		exit 1
	fi
done

run_browser() {
	(cd "$TEST_CWD" && "$SHELL_BIN" --norc --noprofile -c \
		"bash '$SCRIPT_DIR/../helpers/inside-webdriver-title.sh' $1 $DRIVER_PORT $MARIONETTE_PORT $WEBSOCKET_PORT")
}

echo "=== allowHeadlessBrowsers: chromium (Linux) ==="
echo

for browser in chromium; do
	SANDBOXED=$(build_fixture headless-browser.nix --argstr browser "$browser")
	SHELL_BIN="$SANDBOXED/bin/sandboxed-bash-headless-browser"
	capture run_browser "$browser"
	assert_exit_code "$browser: WebDriver session runs" 0
	assert_output_contains "$browser: headless page title read back" '"value":"headless-ok"'
	if [ "$CAP_STATUS" -ne 0 ]; then
		printf '%s\n' "$CAP_ERR" | sed 's/^/    /'
	fi
done

print_results
exit_status
