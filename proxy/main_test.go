package main

import (
	"bufio"
	"bytes"
	"crypto/tls"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// readRequest parses a raw HTTP/1.1 request the way the proxy does, so tests
// exercise the same framing the wire produces rather than a hand-built struct.
func readRequest(t *testing.T, raw string) *http.Request {
	t.Helper()
	req, err := http.ReadRequest(bufio.NewReader(strings.NewReader(raw)))
	if err != nil {
		t.Fatalf("parse request: %v", err)
	}
	return req
}

var (
	getOnlyPolicy  = Config{"example.com": {HasBase: true, Methods: map[string]bool{"GET": true, "HEAD": true}}}
	wildcardPolicy = Config{"example.com": {HasBase: true, AllowAll: true}}
)

func TestIsBlockedAddr(t *testing.T) {
	cases := []struct {
		addr    string
		blocked bool
	}{
		{"127.0.0.1", true},
		{"127.1.2.3", true},
		{"::1", true},
		{"::ffff:127.0.0.1", true},
		{"0.0.0.0", true},
		{"::", true},
		{"::ffff:0.0.0.0", true},
		{"169.254.169.254", true},
		{"::ffff:169.254.169.254", true},
		{"fe80::1", true},
		// Private ranges stay dialable: allowlisting an internal company
		// server is legitimate, and allowedHostPorts cannot express it.
		{"10.0.0.5", false},
		{"172.16.0.1", false},
		{"192.168.1.1", false},
		{"fc00::1", false},
		{"93.184.216.34", false},
		{"2606:4700:4700::1111", false},
	}
	for _, c := range cases {
		ip := net.ParseIP(c.addr)
		if ip == nil {
			t.Fatalf("test bug: %q is not an IP", c.addr)
		}
		if got := isBlockedAddr(ip); got != c.blocked {
			t.Errorf("isBlockedAddr(%s) = %v, want %v", c.addr, got, c.blocked)
		}
	}
}

// A redirect skips resolveVetted, so an entry the caller never wrote is
// worth as much as one it did. "a=b=c" is what reaches the proxy when a key
// of "a=b" is written: taking the first "=" would silently redirect "a".
func TestParseRedirectEnvRejectsExtraEquals(t *testing.T) {
	if _, err := parseRedirectEnv("a=b=c"); err == nil {
		t.Error("parseRedirectEnv(\"a=b=c\") succeeded, want an error")
	}
}

func TestParseRedirectEnv(t *testing.T) {
	got, err := parseRedirectEnv("Example.com=127.0.0.1:8080, other.test=[::1]:9090")
	if err != nil {
		t.Fatalf("parseRedirectEnv errored: %v", err)
	}
	want := Redirects{"example.com": "127.0.0.1:8080", "other.test": "[::1]:9090"}
	if len(got) != len(want) {
		t.Fatalf("parseRedirectEnv = %v, want %v", got, want)
	}
	for host, addr := range want {
		if got[host] != addr {
			t.Errorf("parseRedirectEnv[%q] = %q, want %q", host, got[host], addr)
		}
	}
}

// An allowlisted name whose address is loopback must be refused: the proxy
// runs on the host, so dialing it would reach the host services that
// allowedHostPorts exists to gate.
func TestResolveVettedRefusesLoopback(t *testing.T) {
	for _, host := range []string{"127.0.0.1", "::1", "localhost", "169.254.169.254"} {
		addr, err := resolveVetted(host, "443")
		if !errors.Is(err, errBlockedAddress) {
			t.Errorf("resolveVetted(%q) = (%q, %v), want errBlockedAddress", host, addr, err)
		}
	}
}

func TestResolveVettedAllowsPublicAndPrivate(t *testing.T) {
	cases := []struct {
		host string
		want string
	}{
		{host: "93.184.216.34", want: "93.184.216.34:443"},
		{host: "10.0.0.5", want: "10.0.0.5:443"},
		{host: "192.168.1.1", want: "192.168.1.1:443"},
		{host: "2606:4700:4700::1111", want: "[2606:4700:4700::1111]:443"},
	}
	for _, c := range cases {
		got, err := resolveVetted(c.host, "443")
		if err != nil {
			t.Errorf("resolveVetted(%q) errored: %v", c.host, err)
			continue
		}
		if got != c.want {
			t.Errorf("resolveVetted(%q) = %q, want %q", c.host, got, c.want)
		}
	}
}

func TestDialFailureStatus(t *testing.T) {
	if got := dialFailureStatus(errBlockedAddress); got != http.StatusForbidden {
		t.Errorf("blocked address status = %d, want 403", got)
	}
	if got := dialFailureStatus(errors.New("connection refused")); got != http.StatusBadGateway {
		t.Errorf("dial failure status = %d, want 502", got)
	}
}

func TestApplyFilters(t *testing.T) {
	longQuery := strings.Repeat("x", maxURLBytes+1)

	cases := []struct {
		name   string
		cfg    Config
		host   string
		raw    string
		status int
	}{
		{
			name:   "plain GET allowed",
			cfg:    getOnlyPolicy,
			raw:    "GET /thing HTTP/1.1\r\nHost: example.com\r\n\r\n",
			status: 0,
		},
		{
			name:   "GET with an explicitly empty body allowed",
			cfg:    getOnlyPolicy,
			raw:    "GET /thing HTTP/1.1\r\nHost: example.com\r\nContent-Length: 0\r\n\r\n",
			status: 0,
		},
		{
			name:   "GET carrying a Content-Length body refused",
			cfg:    getOnlyPolicy,
			raw:    "GET /thing HTTP/1.1\r\nHost: example.com\r\nContent-Length: 5\r\n\r\nhello",
			status: http.StatusForbidden,
		},
		{
			name:   "GET carrying a chunked body refused",
			cfg:    getOnlyPolicy,
			raw:    "GET /thing HTTP/1.1\r\nHost: example.com\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\n\r\n",
			status: http.StatusForbidden,
		},
		{
			name:   "HEAD carrying a body refused",
			cfg:    getOnlyPolicy,
			raw:    "HEAD /thing HTTP/1.1\r\nHost: example.com\r\nContent-Length: 5\r\n\r\nhello",
			status: http.StatusForbidden,
		},
		{
			// curl -X get: the policy check uppercases, so the method passes.
			// The body check must see the same normalised value or the
			// GET-only policy stops being read-only.
			name:   "lowercase get carrying a body refused",
			cfg:    getOnlyPolicy,
			raw:    "get /thing HTTP/1.1\r\nHost: example.com\r\nContent-Length: 5\r\n\r\nhello",
			status: http.StatusForbidden,
		},
		{
			name:   "lowercase get subject to the URL cap",
			cfg:    getOnlyPolicy,
			raw:    "get /thing?q=" + longQuery + " HTTP/1.1\r\nHost: example.com\r\n\r\n",
			status: http.StatusRequestURITooLong,
		},
		{
			name:   "URL cap applies to POST",
			cfg:    wildcardPolicy,
			raw:    "POST /thing?q=" + longQuery + " HTTP/1.1\r\nHost: example.com\r\nContent-Length: 0\r\n\r\n",
			status: http.StatusRequestURITooLong,
		},
		{
			name:   "POST with a body allowed under a wildcard policy",
			cfg:    wildcardPolicy,
			raw:    "POST /thing HTTP/1.1\r\nHost: example.com\r\nContent-Length: 5\r\n\r\nhello",
			status: 0,
		},
		{
			name:   "POST refused under a GET-only policy",
			cfg:    getOnlyPolicy,
			raw:    "POST /thing HTTP/1.1\r\nHost: example.com\r\nContent-Length: 5\r\n\r\nhello",
			status: http.StatusForbidden,
		},
		{
			name:   "lowercase post refused under a GET-only policy",
			cfg:    getOnlyPolicy,
			raw:    "post /thing HTTP/1.1\r\nHost: example.com\r\nContent-Length: 5\r\n\r\nhello",
			status: http.StatusForbidden,
		},
		{
			name:   "WebSocket upgrade refused under a method policy",
			cfg:    getOnlyPolicy,
			raw:    "GET /thing HTTP/1.1\r\nHost: example.com\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n",
			status: http.StatusForbidden,
		},
		{
			name:   "WebSocket upgrade allowed under a wildcard policy",
			cfg:    wildcardPolicy,
			raw:    "GET /thing HTTP/1.1\r\nHost: example.com\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n",
			status: 0,
		},
		{
			// The wildcard makes every name allowlisted, so only the
			// comparison against the CONNECT host can refuse this.
			name:   "Host naming another host refused",
			cfg:    Config{"*": {HasBase: true, AllowAll: true}},
			raw:    "GET /thing HTTP/1.1\r\nHost: other.example\r\n\r\n",
			status: http.StatusForbidden,
		},
		{
			name:   "Host bracketing the CONNECT host refused",
			cfg:    Config{"*": {HasBase: true, AllowAll: true}},
			raw:    "GET /thing HTTP/1.1\r\nHost: [example.com]\r\n\r\n",
			status: http.StatusForbidden,
		},
		{
			name:   "Host carrying the port allowed",
			cfg:    wildcardPolicy,
			raw:    "GET /thing HTTP/1.1\r\nHost: example.com:443\r\n\r\n",
			status: 0,
		},
		{
			name:   "Host differing in case allowed",
			cfg:    wildcardPolicy,
			raw:    "GET /thing HTTP/1.1\r\nHost: EXAMPLE.CoM\r\n\r\n",
			status: 0,
		},
		{
			name:   "Host carrying a trailing dot allowed",
			cfg:    wildcardPolicy,
			raw:    "GET /thing HTTP/1.1\r\nHost: example.com.\r\n\r\n",
			status: 0,
		},
		{
			name:   "IPv6 CONNECT host matched through its brackets",
			cfg:    Config{"2606:4700:4700::1111": {HasBase: true, AllowAll: true}},
			host:   "2606:4700:4700::1111",
			raw:    "GET /thing HTTP/1.1\r\nHost: [2606:4700:4700::1111]:443\r\n\r\n",
			status: 0,
		},
		{
			name:   "request without a Host refused",
			cfg:    Config{"*": {HasBase: true, AllowAll: true}},
			raw:    "GET /thing HTTP/1.0\r\n\r\n",
			status: http.StatusBadRequest,
		},
		{
			// handle refuses a non-ASCII authority, so the CONNECT host is
			// ASCII and a Host that only folds onto it under Unicode is a
			// different name: it reaches the origin punycoded as a third.
			name:   "Host folding onto the CONNECT host under Unicode refused",
			cfg:    Config{"*": {HasBase: true, AllowAll: true}},
			host:   "k.example",
			raw:    "GET /thing HTTP/1.1\r\nHost: \u212A.example\r\n\r\n",
			status: http.StatusForbidden,
		},
	}

	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			host := c.host
			if host == "" {
				host = "example.com"
			}
			req := readRequest(t, c.raw)
			status, reason := applyFilters(req, host, c.cfg)
			if status != c.status {
				t.Errorf("applyFilters = (%d, %q), want status %d", status, reason, c.status)
			}
		})
	}
}

// The Host header selects the origin on an upstream that serves several names
// from one address, while the allowlist was applied to the CONNECT host.
func TestApplyFiltersReportsHostMismatch(t *testing.T) {
	req := readRequest(t, "GET /thing HTTP/1.1\r\nHost: other.example\r\n\r\n")
	status, reason := applyFilters(req, "example.com", Config{"*": {HasBase: true, AllowAll: true}})
	if status != http.StatusForbidden {
		t.Fatalf("applyFilters = (%d, %q), want 403", status, reason)
	}
	if !strings.Contains(reason, "CONNECT host") {
		t.Errorf("reason = %q, want it to name the CONNECT host", reason)
	}
}

func TestHostOnly(t *testing.T) {
	cases := []struct {
		addr string
		want string
		ok   bool
	}{
		{addr: "example.com:443", want: "example.com", ok: true},
		{addr: "example.com", want: "example.com", ok: true},
		{addr: "[::1]:443", want: "::1", ok: true},
		{addr: "[2606:4700:4700::1111]", want: "2606:4700:4700::1111", ok: true},
		// Brackets wrap an IPv6 literal and nothing else. SplitHostPort strips
		// them without reading what is inside, so a name written this way
		// would otherwise pass as the bare name it contains.
		{addr: "[example.com]:443", ok: false},
		{addr: "[example.com]", ok: false},
		{addr: "[127.0.0.1]:443", ok: false},
		{addr: "[::1", ok: false},
		{addr: "[::1]x", ok: false},
	}
	for _, c := range cases {
		got, ok := hostOnly(c.addr)
		if ok != c.ok || (ok && got != c.want) {
			t.Errorf("hostOnly(%q) = (%q, %v), want (%q, %v)", c.addr, got, ok, c.want, c.ok)
		}
	}
}

func TestLowerASCII(t *testing.T) {
	cases := []struct {
		in   string
		want string
	}{
		{in: "EXAMPLE.CoM", want: "example.com"},
		// U+212A KELVIN SIGN and U+0130 lowercase to "k" and "i" under a
		// Unicode fold. They are their own names to the resolver and to the
		// origin, and must stay their own names here.
		{in: "\u212A.example", want: "\u212A.example"},
		{in: "\u0130.example", want: "\u0130.example"},
	}
	for _, c := range cases {
		if got := lowerASCII(c.in); got != c.want {
			t.Errorf("lowerASCII(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}

func TestHasNonASCII(t *testing.T) {
	cases := []struct {
		in   string
		want bool
	}{
		{in: "example.com:443", want: false},
		{in: "[2606:4700:4700::1111]:443", want: false},
		{in: "\u212A.example:443", want: true},
		{in: "sub.\u0130.example", want: true},
	}
	for _, c := range cases {
		if got := hasNonASCII(c.in); got != c.want {
			t.Errorf("hasNonASCII(%q) = %v, want %v", c.in, got, c.want)
		}
	}
}

func TestLookupPolicyFoldsOnlyASCII(t *testing.T) {
	cfg := Config{"k.example": {HasBase: true, AllowAll: true}, "i.example": {HasBase: true, AllowAll: true}}
	for _, host := range []string{"\u212A.example", "\u0130.example", "sub.\u212A.example"} {
		if isDomainAllowed(host, cfg) {
			t.Errorf("isDomainAllowed(%q) = true, want false: it is not the allowlisted name", host)
		}
	}
	for _, host := range []string{"K.EXAMPLE", "sub.K.example"} {
		if !isDomainAllowed(host, cfg) {
			t.Errorf("isDomainAllowed(%q) = false, want true: ASCII case must still fold", host)
		}
	}
}

// An allowlist key folded to ASCII would admit a host the operator never
// wrote: a key spelled with U+0130 would be stored, and allowed, as
// "i.example".
func TestLoadConfigKeepsNonASCIIDomainUnmatched(t *testing.T) {
	path := filepath.Join(t.TempDir(), "allowlist.json")
	if err := os.WriteFile(path, []byte(`{"\u0130.example": "*"}`), 0o600); err != nil {
		t.Fatalf("write config: %v", err)
	}

	stderr := captureStderr(t)
	cfg, err := loadConfig(path)
	log := stderr()
	if err != nil {
		t.Fatalf("loadConfig: %v", err)
	}
	if isDomainAllowed("i.example", cfg) {
		t.Error("i.example allowed: the key folded onto an ASCII name the operator never wrote")
	}
	if !strings.Contains(log, "punycode") {
		t.Errorf("stderr = %q, want a warning telling the operator to write punycode", log)
	}
}

func TestLoadConfigWarnsOnCatchAll(t *testing.T) {
	cases := []struct {
		name  string
		raw   string
		want  string
		quiet bool
	}{
		{name: "all methods", raw: `{"*": "*"}`, want: "all methods"},
		{name: "method list", raw: `{"*": ["post","GET"]}`, want: "GET, POST"},
		{name: "no catch-all", raw: `{"example.com": "*"}`, quiet: true},
		{name: "empty method list", raw: `{"*": []}`, quiet: true},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			path := filepath.Join(t.TempDir(), "allowlist.json")
			if err := os.WriteFile(path, []byte(c.raw), 0o600); err != nil {
				t.Fatalf("write config: %v", err)
			}

			stderr := captureStderr(t)
			_, err := loadConfig(path)
			log := stderr()
			if err != nil {
				t.Fatalf("loadConfig: %v", err)
			}
			if c.quiet {
				if strings.Contains(log, "WARNING") {
					t.Errorf("stderr = %q, want no warning: nothing here reaches an unlisted domain", log)
				}
				return
			}
			if !strings.Contains(log, c.want) {
				t.Errorf("stderr = %q, want it to name the methods %q permits", log, c.want)
			}
			if !strings.Contains(log, "every domain not listed") {
				t.Errorf("stderr = %q, want it to name what the entry reaches", log)
			}
		})
	}
}

func TestHasRequestBody(t *testing.T) {
	cases := []struct {
		name string
		raw  string
		want bool
	}{
		{"no body", "GET /x HTTP/1.1\r\nHost: example.com\r\n\r\n", false},
		{"zero length", "GET /x HTTP/1.1\r\nHost: example.com\r\nContent-Length: 0\r\n\r\n", false},
		{"content length", "GET /x HTTP/1.1\r\nHost: example.com\r\nContent-Length: 5\r\n\r\nhello", true},
		{"chunked", "GET /x HTTP/1.1\r\nHost: example.com\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n", true},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := hasRequestBody(readRequest(t, c.raw)); got != c.want {
				t.Errorf("hasRequestBody = %v, want %v", got, c.want)
			}
		})
	}
}

func TestWebSocketTunnel(t *testing.T) {
	upstream, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen upstream: %v", err)
	}
	defer upstream.Close()
	go func() {
		conn, err := upstream.Accept()
		if err != nil {
			return
		}
		defer conn.Close()
		br := bufio.NewReader(conn)
		req, err := http.ReadRequest(br)
		if err != nil {
			return
		}
		if !isWebSocketUpgrade(req) {
			fmt.Fprintf(conn, "HTTP/1.1 400 Bad Request\r\n\r\n")
			return
		}
		fmt.Fprintf(conn, "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n")
		io.Copy(conn, br)
	}()

	ca, err := newCertAuthority()
	if err != nil {
		t.Fatalf("new cert authority: %v", err)
	}
	proxyLn, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen proxy: %v", err)
	}
	defer proxyLn.Close()
	redirects := Redirects{"example.com": upstream.Addr().String()}
	go func() {
		conn, err := proxyLn.Accept()
		if err != nil {
			return
		}
		handle(conn, wildcardPolicy, ca, redirects)
	}()

	conn, err := net.Dial("tcp", proxyLn.Addr().String())
	if err != nil {
		t.Fatalf("dial proxy: %v", err)
	}
	defer conn.Close()
	conn.SetDeadline(time.Now().Add(10 * time.Second))

	fmt.Fprintf(conn, "CONNECT example.com:443 HTTP/1.1\r\nHost: example.com:443\r\n\r\n")
	br := bufio.NewReader(conn)
	status, err := br.ReadString('\n')
	if err != nil || !strings.HasPrefix(status, "HTTP/1.1 200") {
		t.Fatalf("CONNECT response = %q, err = %v", status, err)
	}
	if _, err := br.ReadString('\n'); err != nil {
		t.Fatalf("read CONNECT header terminator: %v", err)
	}

	tlsConn := tls.Client(conn, &tls.Config{ServerName: "example.com", InsecureSkipVerify: true})
	if err := tlsConn.Handshake(); err != nil {
		t.Fatalf("TLS handshake: %v", err)
	}

	fmt.Fprintf(tlsConn, "GET /ws HTTP/1.1\r\nHost: example.com\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n")
	tlsBr := bufio.NewReader(tlsConn)
	status, err = tlsBr.ReadString('\n')
	if err != nil || !strings.HasPrefix(status, "HTTP/1.1 101") {
		t.Fatalf("upgrade response = %q, err = %v", status, err)
	}
	for {
		line, err := tlsBr.ReadString('\n')
		if err != nil {
			t.Fatalf("read upgrade headers: %v", err)
		}
		if line == "\r\n" {
			break
		}
	}

	if _, err := tlsConn.Write([]byte("ping")); err != nil {
		t.Fatalf("write through tunnel: %v", err)
	}
	echo := make([]byte, 4)
	if _, err := io.ReadFull(tlsBr, echo); err != nil {
		t.Fatalf("read echo: %v", err)
	}
	if string(echo) != "ping" {
		t.Errorf("echo = %q, want %q", echo, "ping")
	}
}

func TestFirstContact(t *testing.T) {
	key := "GET first-contact.test/"
	if !firstContact(key) {
		t.Errorf("firstContact(%q) = false on first call, want true", key)
	}
	if firstContact(key) {
		t.Errorf("firstContact(%q) = true on repeat call, want false", key)
	}
	if !firstContact("GET other.first-contact.test/") {
		t.Errorf("firstContact of an unseen key = false, want true")
	}
}

func TestLogAllowed(t *testing.T) {
	cases := []struct {
		name string
		raw  string
		host string
		want []string
	}{
		{
			name: "method, host and path",
			raw:  "POST /graphql HTTP/1.1\r\nHost: log-a.test\r\n\r\n",
			host: "log-a.test",
			want: []string{"allowed: POST log-a.test/graphql\n"},
		},
		{
			name: "query string is left out",
			raw:  "GET /search?q=secret HTTP/1.1\r\nHost: log-b.test\r\n\r\n",
			host: "log-b.test",
			want: []string{"allowed: GET log-b.test/search\n"},
		},
		{
			name: "path is normalised",
			raw:  "GET /a/../b//c HTTP/1.1\r\nHost: log-c.test\r\n\r\n",
			host: "log-c.test",
			want: []string{"allowed: GET log-c.test/b/c\n"},
		},
		{
			name: "unreadable path is logged as sent",
			raw:  "GET /a%2fb HTTP/1.1\r\nHost: log-d.test\r\n\r\n",
			host: "log-d.test",
			want: []string{"allowed: GET log-d.test/a%2fb\n"},
		},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			stderr := captureStderr(t)
			logAllowed(readRequest(t, c.raw), c.host)
			log := stderr()
			for _, want := range c.want {
				if !strings.Contains(log, want) {
					t.Errorf("stderr = %q, want it to contain %q", log, want)
				}
			}
		})
	}
}

func TestLogAllowedLogsEachMethodHostAndPathOnce(t *testing.T) {
	requests := []struct {
		raw    string
		logged bool
	}{
		{"GET /x HTTP/1.1\r\nHost: log-once.test\r\n\r\n", true},
		{"GET /x HTTP/1.1\r\nHost: log-once.test\r\n\r\n", false},
		{"GET /x/ HTTP/1.1\r\nHost: log-once.test\r\n\r\n", false},
		{"GET /x?q=1 HTTP/1.1\r\nHost: log-once.test\r\n\r\n", false},
		{"get /x HTTP/1.1\r\nHost: log-once.test\r\n\r\n", false},
		{"GET /y HTTP/1.1\r\nHost: log-once.test\r\n\r\n", true},
		{"POST /x HTTP/1.1\r\nHost: log-once.test\r\n\r\n", true},
		{"GET /x HTTP/1.1\r\nHost: other.log-once.test\r\n\r\n", true},
	}
	for _, r := range requests {
		stderr := captureStderr(t)
		req := readRequest(t, r.raw)
		host, _ := hostOnly(req.Host)
		logAllowed(req, host)
		if got := stderr() != ""; got != r.logged {
			t.Errorf("logAllowed(%q) logged = %v, want %v", r.raw, got, r.logged)
		}
	}
}

type countingWriter struct {
	writes int
	buf    bytes.Buffer
}

func (c *countingWriter) Write(p []byte) (int, error) {
	c.writes++
	return c.buf.Write(p)
}

func TestWriteSwitchingProtocolsSingleWrite(t *testing.T) {
	resp := &http.Response{
		StatusCode: http.StatusSwitchingProtocols,
		Header: http.Header{
			"Upgrade":                {"websocket"},
			"Connection":             {"Upgrade"},
			"Sec-Websocket-Accept":   {"s3pPLMBiTxaQ9kYGzzhZRbK+xOo="},
			"Sec-Websocket-Protocol": {"chat"},
			"Date":                   {"Fri, 05 Sep 2026 12:46:33 GMT"},
			"Server":                 {"cloudflare"},
			"Cf-Ray":                 {"deadbeefcafe-LHR"},
		},
	}
	var w countingWriter
	if err := writeSwitchingProtocols(&w, resp); err != nil {
		t.Fatalf("writeSwitchingProtocols: %v", err)
	}
	if w.writes != 1 {
		t.Errorf("writes = %d, want 1: a TLS conn emits a record per write, and clients reject a drip-fed handshake", w.writes)
	}
	got := w.buf.String()
	if !strings.HasPrefix(got, "HTTP/1.1 101 Switching Protocols\r\n") {
		t.Errorf("status line = %q", got)
	}
	if !strings.HasSuffix(got, "\r\n\r\n") {
		t.Errorf("header block not terminated: %q", got)
	}
	for _, want := range []string{"Upgrade: websocket", "Sec-Websocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo="} {
		if !strings.Contains(got, want) {
			t.Errorf("missing %q in %q", want, got)
		}
	}
}

func TestHeaderLimitReader(t *testing.T) {
	src := strings.Repeat("a", maxHeaderBytes*2)

	h := &headerLimitReader{r: strings.NewReader(src)}
	h.arm()
	n, err := io.Copy(io.Discard, h)
	if !errors.Is(err, errHeaderTooLarge) {
		t.Errorf("armed read error = %v, want errHeaderTooLarge", err)
	}
	if n != maxHeaderBytes {
		t.Errorf("armed read passed %d bytes, want %d", n, maxHeaderBytes)
	}

	h = &headerLimitReader{r: strings.NewReader(src)}
	h.arm()
	h.disarm()
	n, err = io.Copy(io.Discard, h)
	if err != nil {
		t.Errorf("disarmed read error = %v, want nil", err)
	}
	if n != int64(len(src)) {
		t.Errorf("disarmed read passed %d bytes, want %d", n, len(src))
	}
}

func TestHandleRejectsOversizedHeader(t *testing.T) {
	ca, err := newCertAuthority()
	if err != nil {
		t.Fatalf("new cert authority: %v", err)
	}
	client, server := net.Pipe()
	defer client.Close()
	go handle(server, wildcardPolicy, ca, Redirects{})

	client.SetDeadline(time.Now().Add(10 * time.Second))
	go func() {
		fmt.Fprintf(client, "GET / HTTP/1.1\r\nHost: example.com\r\nX-Big: %s\r\n\r\n", strings.Repeat("a", maxHeaderBytes*2))
	}()

	// The header never completes, so the proxy closes without answering
	// rather than forwarding it upstream.
	got, err := io.ReadAll(client)
	if err != nil && !errors.Is(err, io.ErrClosedPipe) && !errors.Is(err, io.EOF) {
		t.Fatalf("read after oversized header: %v", err)
	}
	if len(got) != 0 {
		t.Errorf("proxy answered %q, want the connection closed with nothing written", got)
	}
}

// The allowlist entry here is the ASCII name the requested authority folds
// onto under Unicode, so nothing after this point would refuse it: CONNECT
// answers 200 and runs the client handshake before any per-request check.
func TestHandleRefusesNonASCIIHost(t *testing.T) {
	cases := []struct {
		name string
		raw  string
	}{
		{name: "CONNECT", raw: "CONNECT \u212A.example:443 HTTP/1.1\r\nHost: \u212A.example:443\r\n\r\n"},
		{name: "plaintext", raw: "GET /thing HTTP/1.1\r\nHost: \u212A.example\r\n\r\n"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			ca, err := newCertAuthority()
			if err != nil {
				t.Fatalf("new cert authority: %v", err)
			}
			client, server := net.Pipe()
			defer client.Close()

			stderr := captureStderr(t)
			done := make(chan struct{})
			go func() {
				defer close(done)
				handle(server, Config{"k.example": {HasBase: true, AllowAll: true}}, ca, Redirects{})
			}()

			client.SetDeadline(time.Now().Add(10 * time.Second))
			go fmt.Fprint(client, c.raw)
			status, err := bufio.NewReader(client).ReadString('\n')
			<-done
			log := stderr()
			if err != nil {
				t.Fatalf("read response: %v", err)
			}
			if !strings.HasPrefix(status, "HTTP/1.1 403") {
				t.Errorf("response = %q, want 403: the authority is not the allowlisted name", status)
			}
			if !strings.Contains(log, "non-ASCII host") {
				t.Errorf("log = %q, want it to name the refusal", log)
			}
		})
	}
}

func TestHandleMITMDeadlinesClientHandshake(t *testing.T) {
	old := clientHandshakeTimeout
	clientHandshakeTimeout = 50 * time.Millisecond
	defer func() { clientHandshakeTimeout = old }()

	ca, err := newCertAuthority()
	if err != nil {
		t.Fatalf("new cert authority: %v", err)
	}
	client, server := net.Pipe()
	defer client.Close()

	done := make(chan struct{})
	go func() {
		defer close(done)
		handle(server, wildcardPolicy, ca, Redirects{})
	}()

	client.SetDeadline(time.Now().Add(10 * time.Second))
	go fmt.Fprintf(client, "CONNECT example.com:443 HTTP/1.1\r\nHost: example.com:443\r\n\r\n")

	// The 200 is written before the handshake, so a client that stops here
	// holds a connection slot until the deadline gives it back.
	br := bufio.NewReader(client)
	status, err := br.ReadString('\n')
	if err != nil || !strings.HasPrefix(status, "HTTP/1.1 200") {
		t.Fatalf("CONNECT response = %q, err = %v", status, err)
	}

	select {
	case <-done:
	case <-time.After(10 * time.Second):
		t.Fatal("handle did not return: a client that never sends a ClientHello parks the goroutine")
	}
}

// fakeListener drives serve from a closure, so a test can script accept
// failures the network will not produce on demand.
type fakeListener struct {
	accept func() (net.Conn, error)
}

func (f *fakeListener) Accept() (net.Conn, error) { return f.accept() }
func (f *fakeListener) Close() error              { return nil }
func (f *fakeListener) Addr() net.Addr            { return &net.TCPAddr{IP: net.IPv4(127, 0, 0, 1)} }

func captureStderr(t *testing.T) func() string {
	t.Helper()
	old := os.Stderr
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatalf("pipe: %v", err)
	}
	os.Stderr = w
	var buf bytes.Buffer
	done := make(chan struct{})
	go func() {
		io.Copy(&buf, r)
		close(done)
	}()
	return func() string {
		os.Stderr = old
		w.Close()
		<-done
		r.Close()
		return buf.String()
	}
}

func TestServeLogsAcceptBackoffOnce(t *testing.T) {
	stderr := captureStderr(t)
	stop := make(chan struct{})
	var calls atomic.Int32
	reached := make(chan struct{})
	var once sync.Once

	ln := &fakeListener{accept: func() (net.Conn, error) {
		if calls.Add(1) <= 3 {
			return nil, errors.New("accept tcp: too many open files")
		}
		once.Do(func() { close(reached) })
		<-stop
		return nil, errors.New("listener stopped")
	}}
	go serve(ln, wildcardPolicy, nil, Redirects{})

	select {
	case <-reached:
	case <-time.After(10 * time.Second):
		close(stop)
		stderr()
		t.Fatal("serve did not retry past the scripted accept failures")
	}
	close(stop)
	got := stderr()

	// One line for the storm, not one per failure: the point of the log is to
	// show up beside the traffic it explains, not to bury it.
	if n := strings.Count(got, "accept error, backing off"); n != 1 {
		t.Errorf("backoff logged %d times, want 1:\n%s", n, got)
	}
	if !strings.Contains(got, "too many open files") {
		t.Errorf("log does not carry the underlying error:\n%s", got)
	}
}

func TestServeRefusesBeyondMaxConns(t *testing.T) {
	stderr := captureStderr(t)
	defer func() {
		if t.Failed() {
			t.Log(stderr())
		}
	}()

	ca, err := newCertAuthority()
	if err != nil {
		t.Fatalf("new cert authority: %v", err)
	}

	// Built up front rather than inside the closure, which runs on serve's
	// goroutine while the cleanup below reads the slice from this one.
	held := make([]net.Conn, maxConns)
	ready := make([]net.Conn, maxConns)
	for i := range held {
		held[i], ready[i] = net.Pipe()
	}
	defer func() {
		for _, c := range held {
			c.Close()
		}
	}()
	refusedClient, refusedServer := net.Pipe()
	defer refusedClient.Close()

	stop := make(chan struct{})
	defer close(stop)
	handed := 0
	// Accept is serial and the slot is claimed before the next call, so by the
	// time the extra connection is handed over every slot is genuinely taken.
	ln := &fakeListener{accept: func() (net.Conn, error) {
		switch {
		case handed < maxConns:
			handed++
			return ready[handed-1], nil
		case handed == maxConns:
			handed++
			return refusedServer, nil
		default:
			<-stop
			return nil, errors.New("listener stopped")
		}
	}}
	go serve(ln, wildcardPolicy, ca, Redirects{})

	refusedClient.SetDeadline(time.Now().Add(10 * time.Second))
	status, err := bufio.NewReader(refusedClient).ReadString('\n')
	if err != nil {
		t.Fatalf("read refusal: %v", err)
	}
	if !strings.HasPrefix(status, "HTTP/1.1 503") {
		t.Errorf("connection %d got %q, want 503 once the cap is reached", maxConns+1, status)
	}
}

func mustLoadConfig(t *testing.T, raw string) Config {
	t.Helper()
	path := filepath.Join(t.TempDir(), "allowlist.json")
	if err := os.WriteFile(path, []byte(raw), 0o600); err != nil {
		t.Fatalf("write config: %v", err)
	}
	stderr := captureStderr(t)
	cfg, err := loadConfig(path)
	stderr()
	if err != nil {
		t.Fatalf("loadConfig: %v", err)
	}
	return cfg
}

func TestApplyFiltersPathRules(t *testing.T) {
	const upgrade = "Connection: Upgrade\r\nUpgrade: websocket\r\n"
	configs := map[string]string{
		"github": `{
			"github.com": ["GET", "HEAD"],
			"api.github.com/graphql": ["POST"]
		}`,
		"narrower than base": `{
			"wide.example": "*",
			"wide.example/admin": ["GET"]
		}`,
		"path only": `{"only.example/graphql": ["POST"]}`,
		"path only with catch-all": `{
			"only.example/graphql": ["POST"],
			"*": ["GET"]
		}`,
		"root path is the base": `{
			"r.example/": ["GET"],
			"r.example/x": ["POST"]
		}`,
		"nested": `{
			"n.example/a": ["GET"],
			"n.example/a/b": ["POST"]
		}`,
		"websocket": `{
			"ws.example": ["GET"],
			"ws.example/socket": "*"
		}`,
	}

	cases := []struct {
		name   string
		config string
		host   string
		method string
		target string
		extra  string
		allow  bool
	}{
		{"path rule allows its method", "github", "api.github.com", "POST", "/graphql", "", true},
		{"path rule replaces the base methods", "github", "api.github.com", "GET", "/graphql", "", false},
		{"path rule matches below the prefix", "github", "api.github.com", "POST", "/graphql/sub", "", true},
		{"trailing slash matches", "github", "api.github.com", "POST", "/graphql/", "", true},
		{"query string is not part of the path", "github", "api.github.com", "POST", "/graphql?x=/other", "", true},
		{"prefix stops at a segment boundary", "github", "api.github.com", "POST", "/graphqlfoo", "", false},
		{"other path falls through to the base", "github", "api.github.com", "GET", "/user", "", true},
		{"fall-through keeps the base methods", "github", "api.github.com", "POST", "/user", "", false},
		{"root falls through to the base", "github", "api.github.com", "GET", "/", "", true},
		{"host folds ASCII case", "github", "API.GITHUB.COM", "POST", "/graphql", "", true},
		{"dot segments resolve before matching", "github", "api.github.com", "POST", "/graphql/../user", "", false},
		{"dot segments resolve into the rule", "github", "api.github.com", "POST", "/user/../graphql", "", true},
		{"unrelated subdomain uses the base", "github", "gist.github.com", "GET", "/graphql", "", true},
		{"unrelated subdomain does not get the path rule", "github", "gist.github.com", "POST", "/graphql", "", false},

		{"base wider than path rule", "narrower than base", "wide.example", "POST", "/public", "", true},
		{"path rule narrows the base", "narrower than base", "wide.example", "POST", "/admin", "", false},
		{"path rule narrows below the prefix", "narrower than base", "wide.example", "POST", "/admin/x", "", false},
		{"path rule still allows its method", "narrower than base", "wide.example", "GET", "/admin/x", "", true},
		{"dot segments cannot dodge the rule", "narrower than base", "wide.example", "POST", "/a/../admin", "", false},
		{"double slash cannot dodge the rule", "narrower than base", "wide.example", "POST", "//admin", "", false},
		{"encoded letter cannot dodge the rule", "narrower than base", "wide.example", "POST", "/%61dmin", "", false},
		{"encoded slash is refused", "narrower than base", "wide.example", "POST", "/admin%2fx", "", false},
		{"encoded slash is refused in either case", "narrower than base", "wide.example", "POST", "/admin%2Fx", "", false},
		{"encoded dot is refused", "narrower than base", "wide.example", "POST", "/a/%2e%2e/admin", "", false},
		{"encoded backslash is refused", "narrower than base", "wide.example", "POST", "/admin%5cx", "", false},
		{"raw backslash is refused", "narrower than base", "wide.example", "POST", "/admin\\x", "", false},
		{"path parameter is refused", "narrower than base", "wide.example", "POST", "/admin;x", "", false},
		{"encoded NUL is refused", "narrower than base", "wide.example", "POST", "/admin%00", "", false},
		{"ambiguous path on a pathless host is unchanged", "github", "gist.github.com", "GET", "/a%2fb", "", true},

		{"path-only host allows its path", "path only", "only.example", "POST", "/graphql", "", true},
		{"path-only host denies other paths", "path only", "only.example", "GET", "/other", "", false},
		{"path-only host denies the root", "path only", "only.example", "POST", "/", "", false},
		{"path-only host denies the wrong method", "path only", "only.example", "GET", "/graphql", "", false},
		{"path-only host with catch-all is not rescued", "path only with catch-all", "only.example", "GET", "/other", "", false},
		{"catch-all still serves unlisted hosts", "path only with catch-all", "other.example", "GET", "/other", "", true},

		{"root path key is the base", "root path is the base", "r.example", "GET", "/y", "", true},
		{"root path base denies other methods", "root path is the base", "r.example", "POST", "/y", "", false},
		{"path rule beside a root path base", "root path is the base", "r.example", "POST", "/x", "", true},
		{"path rule replaces the root path base", "root path is the base", "r.example", "GET", "/x", "", false},

		{"shorter path rule", "nested", "n.example", "GET", "/a/c", "", true},
		{"longest path rule wins", "nested", "n.example", "POST", "/a/b/c", "", true},
		{"longest path rule replaces the shorter", "nested", "n.example", "GET", "/a/b", "", false},
		{"no rule and no base", "nested", "n.example", "GET", "/z", "", false},

		{"websocket allowed on a star path rule", "websocket", "ws.example", "GET", "/socket", upgrade, true},
		{"websocket denied outside the star path rule", "websocket", "ws.example", "GET", "/other", upgrade, false},
		{"plain GET allowed on the base", "websocket", "ws.example", "GET", "/other", "", true},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			cfg := mustLoadConfig(t, configs[c.config])
			raw := c.method + " " + c.target + " HTTP/1.1\r\nHost: " + c.host + "\r\n" + c.extra + "\r\n"
			status, reason := applyFilters(readRequest(t, raw), c.host, cfg)
			if c.allow && status != 0 {
				t.Errorf("%s %s on %s = (%d, %q), want allowed", c.method, c.target, c.host, status, reason)
			}
			if !c.allow && status != http.StatusForbidden {
				t.Errorf("%s %s on %s = (%d, %q), want 403", c.method, c.target, c.host, status, reason)
			}
		})
	}
}

func TestNormalisePath(t *testing.T) {
	cases := []struct {
		raw  string
		want string
		ok   bool
	}{
		{"/", "/", true},
		{"/a", "/a", true},
		{"/a/", "/a", true},
		{"/a//b", "/a/b", true},
		{"/a/./b", "/a/b", true},
		{"/a/b/..", "/a", true},
		{"/a/../../b", "/b", true},
		{"/%61", "/a", true},
		{"/a%20b", "/a b", true},
		{"/Admin", "/Admin", true},
		{"", "", false},
		{"*", "", false},
		{"a", "", false},
		{"/a%2fb", "", false},
		{"/a%2Fb", "", false},
		{"/a%2eb", "", false},
		{"/%2e%2e/a", "", false},
		{"/a%5Cb", "", false},
		{`/a\b`, "", false},
		{"/a;b", "", false},
		{"/a%00", "", false},
		{"/a%zz", "", false},
		{"/a%", "", false},
	}
	for _, c := range cases {
		t.Run(c.raw, func(t *testing.T) {
			got, ok := normalisePath(c.raw)
			if got != c.want || ok != c.ok {
				t.Errorf("normalisePath(%q) = (%q, %v), want (%q, %v)", c.raw, got, ok, c.want, c.ok)
			}
		})
	}
}

func TestIsDomainAllowedForPathOnlyHost(t *testing.T) {
	cfg := mustLoadConfig(t, `{"only.example/graphql": ["POST"], "github.com": ["GET"], "api.github.com/graphql": ["POST"]}`)
	cases := []struct {
		host  string
		allow bool
	}{
		{"only.example", true},
		{"ONLY.example", true},
		{"sub.only.example", true},
		{"other.example", false},
		{"api.github.com", true},
		{"gist.github.com", true},
	}
	for _, c := range cases {
		if got := isDomainAllowed(c.host, cfg); got != c.allow {
			t.Errorf("isDomainAllowed(%q) = %v, want %v", c.host, got, c.allow)
		}
	}
}

func TestLoadConfigPathKeys(t *testing.T) {
	cases := []struct {
		name    string
		raw     string
		wantErr string
		check   func(t *testing.T, cfg Config)
	}{
		{
			name: "base and path share a host entry",
			raw:  `{"api.github.com": ["GET"], "api.github.com/graphql": ["POST"]}`,
			check: func(t *testing.T, cfg Config) {
				p := cfg["api.github.com"]
				if !p.HasBase || !p.Methods["GET"] {
					t.Errorf("base = %+v, want HasBase with GET", p)
				}
				if rule, ok := p.Paths["/graphql"]; !ok || !rule.Methods["POST"] {
					t.Errorf("Paths = %+v, want /graphql with POST", p.Paths)
				}
			},
		},
		{
			name: "path listed before the base",
			raw:  `{"api.github.com/graphql": ["POST"], "api.github.com": ["GET"]}`,
			check: func(t *testing.T, cfg Config) {
				p := cfg["api.github.com"]
				if !p.HasBase || len(p.Paths) != 1 {
					t.Errorf("entry = %+v, want a base and one path rule", p)
				}
			},
		},
		{
			name: "path-only host has no base",
			raw:  `{"api.github.com/graphql": ["POST"]}`,
			check: func(t *testing.T, cfg Config) {
				if cfg["api.github.com"].HasBase {
					t.Error("HasBase = true, want false")
				}
			},
		},
		{
			name: "host folds case and path keeps it",
			raw:  `{"API.GitHub.com/GraphQL": "*"}`,
			check: func(t *testing.T, cfg Config) {
				if _, ok := cfg["api.github.com"].Paths["/GraphQL"]; !ok {
					t.Errorf("cfg = %+v, want api.github.com with /GraphQL", cfg)
				}
			},
		},
		{
			name: "path is normalised",
			raw:  `{"a.example/x/./y/": "*"}`,
			check: func(t *testing.T, cfg Config) {
				if _, ok := cfg["a.example"].Paths["/x/y"]; !ok {
					t.Errorf("Paths = %+v, want /x/y", cfg["a.example"].Paths)
				}
			},
		},
		{
			name: "root path is the base",
			raw:  `{"a.example/": ["GET"]}`,
			check: func(t *testing.T, cfg Config) {
				p := cfg["a.example"]
				if !p.HasBase || len(p.Paths) != 0 {
					t.Errorf("entry = %+v, want a base and no path rules", p)
				}
			},
		},
		{name: "catch-all with a path", raw: `{"*/foo": "*"}`, wantErr: "cannot have a path"},
		{name: "ambiguous path", raw: `{"a.example/x%2fy": "*"}`, wantErr: "ambiguous path"},
		{name: "parameter in path", raw: `{"a.example/x;y": "*"}`, wantErr: "ambiguous path"},
		{name: "duplicate after normalising", raw: `{"a.example/x": "*", "a.example/x/": "*"}`, wantErr: "duplicate"},
		{name: "duplicate root path and base", raw: `{"a.example": "*", "a.example/": "*"}`, wantErr: "duplicate"},
		{name: "bad policy on a path rule", raw: `{"a.example/x": "nope"}`, wantErr: "a.example/x"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if c.wantErr == "" {
				c.check(t, mustLoadConfig(t, c.raw))
				return
			}
			path := filepath.Join(t.TempDir(), "allowlist.json")
			if err := os.WriteFile(path, []byte(c.raw), 0o600); err != nil {
				t.Fatalf("write config: %v", err)
			}
			_, err := loadConfig(path)
			if err == nil || !strings.Contains(err.Error(), c.wantErr) {
				t.Errorf("loadConfig error = %v, want it to contain %q", err, c.wantErr)
			}
		})
	}
}

func TestLogBlocked(t *testing.T) {
	cfg := mustLoadConfig(t, `{
		"api.github.com/graphql": ["POST"],
		"read.example": ["GET"]
	}`)
	cases := []struct {
		name string
		raw  string
		host string
		want string
	}{
		{
			name: "path not allowed",
			raw:  "GET /user HTTP/1.1\r\nHost: api.github.com\r\n\r\n",
			host: "api.github.com",
			want: "blocked: GET api.github.com/user (path not allowed)\n",
		},
		{
			name: "method not allowed",
			raw:  "GET /graphql HTTP/1.1\r\nHost: api.github.com\r\n\r\n",
			host: "api.github.com",
			want: "blocked: GET api.github.com/graphql (method not allowed)\n",
		},
		{
			name: "unreadable path",
			raw:  "GET /a%2fb HTTP/1.1\r\nHost: api.github.com\r\n\r\n",
			host: "api.github.com",
			want: "blocked: GET api.github.com/a%2fb (path not allowed)\n",
		},
		{
			name: "query string is left out",
			raw:  "POST /user?token=secret HTTP/1.1\r\nHost: read.example\r\n\r\n",
			host: "read.example",
			want: "blocked: POST read.example/user (method not allowed)\n",
		},
		{
			name: "domain not allowed",
			raw:  "GET /user HTTP/1.1\r\nHost: github.com\r\n\r\n",
			host: "github.com",
			want: "blocked: GET github.com/user (domain not allowed)\n",
		},
		{
			name: "domain not allowed on CONNECT",
			raw:  "CONNECT github.com:443 HTTP/1.1\r\nHost: github.com:443\r\n\r\n",
			host: "github.com",
			want: "blocked: CONNECT github.com (domain not allowed)\n",
		},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			req := readRequest(t, c.raw)
			reason := "domain not allowed"
			if isDomainAllowed(c.host, cfg) {
				status, r := applyFilters(req, c.host, cfg)
				if status != http.StatusForbidden {
					t.Fatalf("applyFilters = (%d, %q), want 403", status, r)
				}
				reason = r
			}
			stderr := captureStderr(t)
			logBlocked(req, c.host, reason)
			if log := stderr(); !strings.Contains(log, c.want) {
				t.Errorf("stderr = %q, want it to contain %q", log, c.want)
			}
		})
	}
}
