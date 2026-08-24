package main

import (
	"bufio"
	"errors"
	"net"
	"net/http"
	"strings"
	"testing"
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
	getOnlyPolicy  = Config{"example.com": {Methods: map[string]bool{"GET": true, "HEAD": true}}}
	wildcardPolicy = Config{"example.com": {AllowAll: true}}
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
		// server is legitimate, and allowedLocalPorts cannot express it.
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

// An allowlisted name whose address is loopback must be refused: the proxy
// runs on the host, so dialing it would reach the host services that
// allowedLocalPorts exists to gate.
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
			name:   "WebSocket upgrade refused",
			cfg:    getOnlyPolicy,
			raw:    "GET /thing HTTP/1.1\r\nHost: example.com\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n",
			status: http.StatusForbidden,
		},
	}

	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			req := readRequest(t, c.raw)
			status, reason := applyFilters(req, "example.com", c.cfg)
			if status != c.status {
				t.Errorf("applyFilters = (%d, %q), want status %d", status, reason, c.status)
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
