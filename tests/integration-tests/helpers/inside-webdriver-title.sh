#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 4 ] && [ "$#" -ne 5 ]; then
  echo "usage: inside-webdriver-title.sh <browser> <driver-port> <marionette-port> <websocket-port> [url]" >&2
  exit 2
fi

browser="$1"
driver_port="$2"
marionette_port="$3"
websocket_port="$4"
url="${5:-}"
base="http://127.0.0.1:$driver_port"
# With allowedDomains set, the sandbox env carries proxy variables, and curl
# would send these loopback calls to the allowlist proxy, which answers 403.
export NO_PROXY=127.0.0.1,localhost no_proxy=127.0.0.1,localhost
driver_log="$TMPDIR/webdriver.log"
binary="${BROWSER_BINARY:?BROWSER_BINARY is not set}"

proxy_caps=""
if [ -n "$url" ]; then
  proxy_addr="${HTTPS_PROXY:?HTTPS_PROXY is not set}"
  proxy_addr="${proxy_addr#*://}"
  proxy_caps=$(printf '"proxy":{"proxyType":"manual","httpProxy":"%s","sslProxy":"%s"},' "$proxy_addr" "$proxy_addr")
fi

case "$browser" in
chrome | chromium)
  chromedriver --port="$driver_port" --log-path="$driver_log" &
  caps=$(printf '{"capabilities":{"alwaysMatch":{%s"goog:chromeOptions":{"binary":"%s","args":["--headless=new","--no-sandbox","--disable-gpu","--remote-debugging-pipe"]}}}}' "$proxy_caps" "$binary")
  ;;
firefox)
  geckodriver --port "$driver_port" --marionette-port "$marionette_port" \
    --websocket-port "$websocket_port" >"$driver_log" 2>&1 &
  caps=$(printf '{"capabilities":{"alwaysMatch":{%s"moz:firefoxOptions":{"binary":"%s","args":["-headless"]}}}}' "$proxy_caps" "$binary")
  ;;
*)
  echo "unknown browser: $browser" >&2
  exit 2
  ;;
esac
driver=$!
trap 'kill "$driver" 2>/dev/null || true' EXIT

for _ in $(seq 1 50); do
  curl -s "$base/status" >/dev/null && break
  sleep 0.2
done

curl_status=0
session=$(curl -sS --max-time 60 -w '\nhttp %{http_code}' -H 'Content-Type: application/json' -d "$caps" "$base/session") || curl_status=$?
case "$session" in
*'"sessionId"'*) session=${session%$'\n'http *} ;;
*)
  echo "no session (curl exit $curl_status): $session" >&2
  echo "caps: $caps" >&2
  echo "driver log:" >&2
  tail -n 40 "$driver_log" >&2 || true
  exit 1
  ;;
esac
id=$(printf '%s' "$session" | python3 -c 'import json, sys; print(json.load(sys.stdin)["value"]["sessionId"])')

status=0
if [ -n "$url" ]; then
  nav=$(curl -s -H 'Content-Type: application/json' \
    -d "$(printf '{"url":"%s"}' "$url")" "$base/session/$id/url")
  printf '%s\n' "$nav"
  case "$nav" in
  *'"error"'*) status=1 ;;
  *) curl -s "$base/session/$id/source" || status=1 ;;
  esac
else
  curl -s -H 'Content-Type: application/json' \
    -d '{"url":"data:text/html,<title>headless-ok</title>"}' "$base/session/$id/url" >/dev/null
  curl -s "$base/session/$id/title"
fi
echo
curl -s -X DELETE "$base/session/$id" >/dev/null || true
exit "$status"
