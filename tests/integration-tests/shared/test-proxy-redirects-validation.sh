#!/usr/bin/env bash
# _proxyRedirects maps a hostname to "addr:port". Both halves are shape
# checked so neither can carry the "," or "=" the launcher joins them with.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

source "$SCRIPT_DIR/../lib.sh"

# Not build_fixture: the build is what this file asserts on, so it must run
# every time and its failure output is the subject rather than an error.
build_with_redirects() {
	local redirects="$1"
	nix-build --no-out-link --arg redirects "$redirects" "$SCRIPT_DIR/../fixtures/proxy-redirects.nix" 2>&1
}

expect_ok_redirects() {
	local desc="$1" redirects="$2"
	local out
	if out=$(build_with_redirects "$redirects"); then
		echo "PASS: $desc"
		PASS=$((PASS + 1))
	else
		echo "FAIL: $desc (build failed)"
		printf '%s\n' "$out" | sed 's/^/    /'
		FAIL=$((FAIL + 1))
	fi
}

expect_invalid_redirects() {
	local desc="$1" redirects="$2" needle="$3"
	local out
	if out=$(build_with_redirects "$redirects"); then
		echo "FAIL: $desc (build succeeded; expected validation error)"
		FAIL=$((FAIL + 1))
	elif printf '%s' "$out" | grep -qF "$needle"; then
		echo "PASS: $desc"
		PASS=$((PASS + 1))
	else
		echo "FAIL: $desc (threw, but message missing: $needle)"
		printf '%s\n' "$out" | sed 's/^/    /'
		FAIL=$((FAIL + 1))
	fi
}

echo "=== _proxyRedirects validation ==="
echo

expect_ok_redirects "hostname to loopback address is accepted" '{ "httpbin.test" = "127.0.0.1:18918"; }'
expect_ok_redirects "bracketed IPv6 address is accepted" '{ "a.test" = "[::1]:18918"; }'
expect_ok_redirects "empty attrset is accepted" "{ }"
expect_invalid_redirects "comma in the host is rejected" \
	'{ "a.test,b.test=127.0.0.1:1" = "127.0.0.1:18918"; }' \
	"_proxyRedirects hosts must not contain"
expect_invalid_redirects "equals in the host is rejected" \
	'{ "a.test=127.0.0.1:1" = "127.0.0.1:18918"; }' \
	"_proxyRedirects hosts must not contain"
expect_invalid_redirects "comma in the address is rejected" \
	'{ "a.test" = "127.0.0.1:18918,b.test=127.0.0.1:1"; }' \
	"_proxyRedirects hosts must not contain"
expect_invalid_redirects "non-string address is rejected" \
	'{ "a.test" = 18918; }' \
	"_proxyRedirects hosts must not contain"
expect_invalid_redirects "list instead of an attrset is rejected" \
	'[ "a.test=127.0.0.1:18918" ]' \
	"_proxyRedirects must be an attrset"

print_results
exit_status
