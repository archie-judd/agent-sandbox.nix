#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 4 ]; then
	echo "usage: inside-webdriver-title.sh <browser> <driver-port> <marionette-port> <websocket-port>" >&2
	exit 2
fi

browser="$1"
driver_port="$2"
marionette_port="$3"
websocket_port="$4"
base="http://127.0.0.1:$driver_port"
driver_log="$TMPDIR/webdriver.log"
binary="${BROWSER_BINARY:?BROWSER_BINARY is not set}"

case "$browser" in
chrome | chromium)
	chromedriver --port="$driver_port" --log-path="$driver_log" &
	caps=$(printf '{"capabilities":{"alwaysMatch":{"goog:chromeOptions":{"binary":"%s","args":["--headless=new","--no-sandbox","--disable-gpu","--remote-debugging-pipe"]}}}}' "$binary")
	;;
firefox)
	geckodriver --port "$driver_port" --marionette-port "$marionette_port" \
		--websocket-port "$websocket_port" >"$driver_log" 2>&1 &
	caps=$(printf '{"capabilities":{"alwaysMatch":{"moz:firefoxOptions":{"binary":"%s","args":["-headless"]}}}}' "$binary")
	;;
*)
	echo "unknown browser: $browser" >&2
	exit 2
	;;
esac
driver=$!
trap 'kill "$driver" 2>/dev/null || true' EXIT

for _ in $(seq 1 50); do
	curl -sf "$base/status" >/dev/null && break
	sleep 0.2
done

if ! session=$(curl -sf --max-time 60 -H 'Content-Type: application/json' -d "$caps" "$base/session"); then
	echo "no session; driver log:" >&2
	tail -n 40 "$driver_log" >&2 || true
	exit 1
fi
id=$(printf '%s' "$session" | python3 -c 'import json, sys; print(json.load(sys.stdin)["value"]["sessionId"])')

curl -sf -H 'Content-Type: application/json' \
	-d '{"url":"data:text/html,<title>headless-ok</title>"}' "$base/session/$id/url" >/dev/null
curl -sf "$base/session/$id/title"
echo
curl -sf -X DELETE "$base/session/$id" >/dev/null || true
