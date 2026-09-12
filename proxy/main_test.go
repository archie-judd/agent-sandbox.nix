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
			cfg:    Config{"*": {AllowAll: true}},
			raw:    "GET /thing HTTP/1.1\r\nHost: other.example\r\n\r\n",
			status: http.StatusForbidden,
		},
		{
			name:   "Host bracketing the CONNECT host refused",
			cfg:    Config{"*": {AllowAll: true}},
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
			cfg:    Config{"2606:4700:4700::1111": {AllowAll: true}},
			host:   "2606:4700:4700::1111",
			raw:    "GET /thing HTTP/1.1\r\nHost: [2606:4700:4700::1111]:443\r\n\r\n",
			status: 0,
		},
		{
			name:   "request without a Host refused",
			cfg:    Config{"*": {AllowAll: true}},
			raw:    "GET /thing HTTP/1.0\r\n\r\n",
			status: http.StatusBadRequest,
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
	status, reason := applyFilters(req, "example.com", Config{"*": {AllowAll: true}})
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
	host := "first-contact.test"
	if !firstContact(host) {
		t.Errorf("firstContact(%q) = false on first call, want true", host)
	}
	if firstContact(host) {
		t.Errorf("firstContact(%q) = true on repeat call, want false", host)
	}
	if !firstContact("other." + host) {
		t.Errorf("firstContact of an unseen host = false, want true")
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
