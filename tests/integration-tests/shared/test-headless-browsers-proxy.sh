#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEST_CWD="$(cd "$SCRIPT_DIR/../../.." && pwd)"

source "$SCRIPT_DIR/../lib.sh"

DRIVER_PORT=18950
MARIONETTE_PORT=18951
WEBSOCKET_PORT=18952
LOCAL_HTTPBIN_PORT=18953

for port in "$DRIVER_PORT" "$MARIONETTE_PORT" "$WEBSOCKET_PORT" "$LOCAL_HTTPBIN_PORT"; do
	if nc -z 127.0.0.1 "$port" 2>/dev/null; then
		echo "FAIL: test setup — 127.0.0.1:$port already in use" >&2
		exit 1
	fi
done

HTTPBIN_BIN=$(build_host_pkg go-httpbin)/bin/go-httpbin
"$HTTPBIN_BIN" -host 127.0.0.1 -port "$LOCAL_HTTPBIN_PORT" >/dev/null 2>&1 &
HTTPBIN_PID=$!
trap 'kill "$HTTPBIN_PID" 2>/dev/null || true' EXIT
_httpbin_ready=0
for _ in 1 2 3 4 5 6 7 8 9 10; do
	if nc -z 127.0.0.1 "$LOCAL_HTTPBIN_PORT" 2>/dev/null; then
		_httpbin_ready=1
		break
	fi
	sleep 0.2
done
if [ "$_httpbin_ready" -ne 1 ]; then
	echo "FAIL: test setup — go-httpbin never came up on 127.0.0.1:$LOCAL_HTTPBIN_PORT" >&2
	exit 1
fi

run_browser() {
	(cd "$TEST_CWD" && "$SHELL_BIN" --norc --noprofile -c \
		"bash '$SCRIPT_DIR/../helpers/inside-webdriver-title.sh' $1 $DRIVER_PORT $MARIONETTE_PORT $WEBSOCKET_PORT '$2'")
}

browsers="chrome firefox"
if [ "$(uname -s)" = "Linux" ]; then
	browsers="$browsers chromium"
fi

echo "=== allowHeadlessBrowsers: proxy and HTTPS (shared) ==="
echo

for browser in $browsers; do
	SANDBOXED=$(build_fixture headless-browser.nix \
		--argstr browser "$browser" --argstr httpbinPort "$LOCAL_HTTPBIN_PORT")
	SHELL_BIN="$SANDBOXED/bin/sandboxed-bash-headless-browser"

	capture run_browser "$browser" "https://httpbin.test/html"
	assert_exit_code "$browser: HTTPS page from an allowed domain loads through the proxy" 0
	assert_output_contains "$browser: allowed domain served over HTTPS, proxy CA trusted" "Herman Melville"
	if [ "$CAP_STATUS" -ne 0 ]; then
		printf '%s\n' "$CAP_ERR" | sed 's/^/    /'
	fi

	capture run_browser "$browser" "https://example.org/"
	assert_exit_code "$browser: HTTPS page from a blocked domain fails to load" 1
	assert_output_not_contains "$browser: blocked domain returns no page" "Example Domain"
	case "$browser" in
	chrome | chromium)
		assert_output_contains "$browser: blocked domain refused by the proxy" "ERR_TUNNEL_CONNECTION_FAILED"
		;;
	esac
done

print_results
exit_status
