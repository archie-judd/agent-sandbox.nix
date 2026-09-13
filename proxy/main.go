package main

import (
	"bufio"
	"bytes"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"math/big"
	"net"
	"net/http"
	"os"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

type DomainPolicy struct {
	AllowAll bool
	Methods  map[string]bool
}

// The "*" key matches every host no other entry matches, which is the rest of
// the internet rather than a floor beneath the hosts listed.
type Config map[string]DomainPolicy

// Redirects maps a lowercase hostname to a local "host:port" address the
// proxy dials instead of resolving the original host. A test-harness escape
// hatch, set via SANDBOX_PROXY_REDIRECT as "host=addr:port[,...]".
type Redirects map[string]string

// lowerASCII folds only ASCII, where strings.ToLower folds Unicode: under a
// Unicode fold U+212A KELVIN SIGN lowercases to "k" and U+0130 to "i", so a
// name the resolver and the origin both read as its own would match an
// allowlist entry it is not.
func lowerASCII(s string) string {
	b := []byte(s)
	for i := range b {
		if b[i] >= 'A' && b[i] <= 'Z' {
			b[i] += 'a' - 'A'
		}
	}
	return string(b)
}

func hasNonASCII(s string) bool {
	for i := 0; i < len(s); i++ {
		if s[i] >= 0x80 {
			return true
		}
	}
	return false
}

func parseRedirectEnv(s string) (Redirects, error) {
	out := make(Redirects)
	if s == "" {
		return out, nil
	}
	for _, entry := range strings.Split(s, ",") {
		entry = strings.TrimSpace(entry)
		if entry == "" {
			continue
		}
		eq := strings.IndexByte(entry, '=')
		if eq < 0 {
			return nil, fmt.Errorf("invalid redirect entry %q: missing '='", entry)
		}
		host := lowerASCII(strings.TrimSpace(entry[:eq]))
		addr := strings.TrimSpace(entry[eq+1:])
		if host == "" || addr == "" {
			return nil, fmt.Errorf("invalid redirect entry %q: empty host or address", entry)
		}
		// The split takes the first "=", so a second one means the host was
		// cut at an "=" the caller wrote inside its key: the entry is not the
		// one it set. The "," case cannot reach here, having split entries
		// first, and no address needs an "=" of its own.
		if strings.Contains(addr, "=") {
			return nil, fmt.Errorf("invalid redirect entry %q: extra '='", entry)
		}
		out[host] = addr
	}
	return out, nil
}

const maxURLBytes = 8192

const (
	// Upstream connect, covering the TLS handshake. Without it a host that
	// completes the TCP connect and then never sends ServerHello parks the
	// goroutine and both its file descriptors for the life of the proxy.
	dialTimeout = 10 * time.Second
	// The wait for upstream response headers.
	responseHeaderTimeout = 60 * time.Second
	// Reaps pooled upstream connections. Go's own Transport default.
	upstreamIdleTimeout = 90 * time.Second
	// Bounds the refusal written to a client the proxy has no slot for, which
	// is a client with no reason to read it.
	refusalWriteTimeout = 10 * time.Second

	maxConns = 256

	// Caps one request's header block. http.ReadRequest is called directly
	// rather than through http.Server, and the textproto reader beneath it
	// runs unbounded, so without this a single header line allocates without
	// limit in a process that runs on the host, outside whatever memory
	// confinement the sandbox has.
	maxHeaderBytes = 64 * 1024
)

// Bounds the client TLS handshake in handleMITM. A var rather than a const so
// the test can shorten it.
var clientHandshakeTimeout = 10 * time.Second

// headerLimitReader bounds how much is read while a request header block is
// being parsed. It is armed around http.ReadRequest and disarmed for the body
// and for anything tunnelled afterwards, which must not be capped.
type headerLimitReader struct {
	r         io.Reader
	remaining int64
}

var errHeaderTooLarge = errors.New("request header exceeds limit")

func (h *headerLimitReader) arm() {
	h.remaining = maxHeaderBytes
}

func (h *headerLimitReader) disarm() {
	h.remaining = -1
}

func (h *headerLimitReader) Read(p []byte) (int, error) {
	if h.remaining < 0 {
		return h.r.Read(p)
	}
	if h.remaining == 0 {
		return 0, errHeaderTooLarge
	}
	// Read no more than the budget, so the error surfaces on the read that
	// exhausts it rather than after the excess has been buffered.
	if int64(len(p)) > h.remaining {
		p = p[:h.remaining]
	}
	n, err := h.r.Read(p)
	h.remaining -= int64(n)
	return n, err
}

// Proxy nil rather than ProxyFromEnvironment, so the proxy itself does not
// route through another proxy on the host.
var directTransport = &http.Transport{
	Proxy:                 nil,
	DialContext:           (&net.Dialer{Timeout: dialTimeout}).DialContext,
	TLSHandshakeTimeout:   dialTimeout,
	ResponseHeaderTimeout: responseHeaderTimeout,
	IdleConnTimeout:       upstreamIdleTimeout,
}

var knownHTTPMethods = map[string]bool{
	"GET": true, "HEAD": true, "POST": true, "PUT": true,
	"DELETE": true, "CONNECT": true, "OPTIONS": true, "TRACE": true,
	"PATCH": true,
}

func loadConfig(path string) (Config, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()

	// JSON format: { "domain": "*" | ["GET","HEAD"], ... }
	var raw map[string]json.RawMessage
	if err := json.NewDecoder(f).Decode(&raw); err != nil {
		return nil, fmt.Errorf("parse config: %w", err)
	}

	cfg := make(Config)
	for domain, val := range raw {
		// A Unicode fold would store such a key under an ASCII name the
		// operator never wrote, and allow requests to it. Kept as written, it
		// matches nothing: a non-ASCII host is refused before any lookup.
		if hasNonASCII(domain) {
			fmt.Fprintf(os.Stderr, "WARNING: non-ASCII domain %q will never match; write it in punycode\n", domain)
		}
		domain = lowerASCII(domain)
		var star string
		if err := json.Unmarshal(val, &star); err == nil {
			if star == "*" {
				cfg[domain] = DomainPolicy{AllowAll: true}
			} else {
				return nil, fmt.Errorf("invalid policy for %q: string must be \"*\", got %q", domain, star)
			}
			continue
		}
		var methods []string
		if err := json.Unmarshal(val, &methods); err != nil {
			return nil, fmt.Errorf("invalid policy for %q: expected \"*\" or [\"METHOD\", ...]: %w", domain, err)
		}
		m := make(map[string]bool)
		for _, method := range methods {
			upper := strings.ToUpper(method)
			if !knownHTTPMethods[upper] {
				fmt.Fprintf(os.Stderr, "WARNING: unrecognized HTTP method %q for domain %q\n", method, domain)
			}
			m[upper] = true
		}
		cfg[domain] = DomainPolicy{Methods: m}
	}
	// Named at startup because the matching code is the only other place it is
	// visible, and "*" reads as a floor under the listed hosts rather than the
	// catch-all it is.
	if p, ok := cfg["*"]; ok && (p.AllowAll || len(p.Methods) > 0) {
		allows := "all methods"
		if !p.AllowAll {
			methods := make([]string, 0, len(p.Methods))
			for method := range p.Methods {
				methods = append(methods, method)
			}
			sort.Strings(methods)
			allows = strings.Join(methods, ", ")
		}
		fmt.Fprintf(os.Stderr, "WARNING: %q allows %s to every domain not listed, which is the rest of the internet\n", "*", allows)
	}
	return cfg, nil
}

// Exactly one entry applies and policies never merge: the exact key, else the
// longest matching suffix entry, else "*", else deny. A host that matched a
// name of its own does not also pick up what "*" allows.
func lookupPolicy(host string, cfg Config) (DomainPolicy, bool) {
	host = lowerASCII(host)
	if p, ok := cfg[host]; ok {
		return p, true
	}
	var bestDomain string
	var bestPolicy DomainPolicy
	for d, p := range cfg {
		if d != "*" && strings.HasSuffix(host, "."+d) {
			if len(d) > len(bestDomain) {
				bestDomain = d
				bestPolicy = p
			}
		}
	}
	if bestDomain != "" {
		return bestPolicy, true
	}
	if p, ok := cfg["*"]; ok {
		return p, true
	}
	return DomainPolicy{}, false
}

func isDomainAllowed(host string, cfg Config) bool {
	_, ok := lookupPolicy(host, cfg)
	return ok
}

func isMethodAllowed(host, method string, cfg Config) bool {
	policy, ok := lookupPolicy(host, cfg)
	if !ok {
		return false
	}
	if policy.AllowAll {
		return true
	}
	return policy.Methods[strings.ToUpper(method)]
}

// lookupRedirect matches like lookupPolicy, so a subdomain that passes the
// allowlist by suffix match also gets redirected.
func lookupRedirect(host string, redirects Redirects) (string, bool) {
	host = lowerASCII(host)
	if addr, ok := redirects[host]; ok {
		return addr, true
	}
	var bestDomain, bestAddr string
	for d, addr := range redirects {
		if strings.HasSuffix(host, "."+d) && len(d) > len(bestDomain) {
			bestDomain, bestAddr = d, addr
		}
	}
	return bestAddr, bestDomain != ""
}

// hostOnly returns the host part of an authority, reporting false for one it
// cannot read. Brackets wrap an IPv6 literal and nothing else: SplitHostPort
// strips them without reading what is inside, so "[name]:443" would otherwise
// yield a bare name carrying no sign of the form it arrived in.
func hostOnly(addr string) (string, bool) {
	if strings.HasPrefix(addr, "[") {
		end := strings.IndexByte(addr, ']')
		if end < 0 {
			return "", false
		}
		inner := addr[1:end]
		if ip := net.ParseIP(inner); ip == nil || ip.To4() != nil {
			return "", false
		}
		if rest := addr[end+1:]; rest != "" && rest[0] != ':' {
			return "", false
		}
		return inner, true
	}
	h, _, err := net.SplitHostPort(addr)
	if err != nil {
		return addr, true
	}
	return h, true
}

// normaliseHost renders the spellings of one name in a single form, so the
// comparison below refuses only a genuinely different host.
func normaliseHost(host string) string {
	return lowerASCII(strings.TrimSuffix(host, "."))
}

func portOf(addr string) string {
	_, p, err := net.SplitHostPort(addr)
	if err != nil {
		return ""
	}
	return p
}

const maxCachedCerts = 1024

// The ephemeral CA that mints per-host leaf certificates.
type certAuthority struct {
	cert      *x509.Certificate
	key       *ecdsa.PrivateKey
	cache     sync.Map // hostname -> *tls.Certificate
	cacheSize atomic.Int64
}

func newCertAuthority() (*certAuthority, error) {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return nil, err
	}
	serial, err := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 128))
	if err != nil {
		return nil, err
	}
	tmpl := &x509.Certificate{
		SerialNumber: serial,
		Subject: pkix.Name{
			CommonName:   "sandbox-proxy CA",
			Organization: []string{"sandbox-proxy"},
		},
		NotBefore:             time.Now().Add(-1 * time.Hour),
		NotAfter:              time.Now().Add(24 * time.Hour),
		KeyUsage:              x509.KeyUsageCertSign | x509.KeyUsageCRLSign,
		BasicConstraintsValid: true,
		IsCA:                  true,
		MaxPathLen:            0,
	}
	certDER, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &key.PublicKey, key)
	if err != nil {
		return nil, err
	}
	cert, err := x509.ParseCertificate(certDER)
	if err != nil {
		return nil, err
	}
	return &certAuthority{cert: cert, key: key}, nil
}

func (ca *certAuthority) writeCert(path string) error {
	f, err := os.Create(path)
	if err != nil {
		return err
	}
	defer f.Close()
	return pem.Encode(f, &pem.Block{Type: "CERTIFICATE", Bytes: ca.cert.Raw})
}

func (ca *certAuthority) mintCert(hostname string) (*tls.Certificate, error) {
	if cached, ok := ca.cache.Load(hostname); ok {
		return cached.(*tls.Certificate), nil
	}
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return nil, err
	}
	serial, err := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 128))
	if err != nil {
		return nil, err
	}
	tmpl := &x509.Certificate{
		SerialNumber: serial,
		Subject:      pkix.Name{CommonName: hostname},
		NotBefore:    time.Now().Add(-1 * time.Hour),
		NotAfter:     time.Now().Add(24 * time.Hour),
		KeyUsage:     x509.KeyUsageDigitalSignature,
		ExtKeyUsage:  []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		DNSNames:     []string{hostname},
	}
	if ip := net.ParseIP(hostname); ip != nil {
		tmpl.IPAddresses = []net.IP{ip}
	}
	certDER, err := x509.CreateCertificate(rand.Reader, tmpl, ca.cert, &key.PublicKey, ca.key)
	if err != nil {
		return nil, err
	}
	tlsCert := &tls.Certificate{
		Certificate: [][]byte{certDER},
		PrivateKey:  key,
	}
	if ca.cacheSize.Load() < maxCachedCerts {
		if _, loaded := ca.cache.LoadOrStore(hostname, tlsCert); !loaded {
			ca.cacheSize.Add(1)
		}
	}
	return tlsCert, nil
}

func isWebSocketUpgrade(req *http.Request) bool {
	for _, v := range req.Header["Upgrade"] {
		for _, token := range strings.Split(v, ",") {
			if strings.EqualFold(strings.TrimSpace(token), "websocket") {
				return true
			}
		}
	}
	return false
}

func requestURLLength(req *http.Request) int {
	return len(req.URL.String())
}

func hasRequestBody(req *http.Request) bool {
	if req.ContentLength > 0 {
		return true
	}
	for _, encoding := range req.TransferEncoding {
		if strings.EqualFold(encoding, "chunked") {
			return true
		}
	}
	return false
}

// applyFilters returns an HTTP status code and reason if blocked, or 0 if
// allowed. Callers must check isDomainAllowed first.
func applyFilters(req *http.Request, host string, cfg Config) (int, string) {
	// Every check below judges host, the name the connection was gated for,
	// while the request is forwarded carrying its own Host header. An upstream
	// serving several names from one address routes on that header, so the two
	// must name the same host or the gate decides nothing.
	if req.Host == "" {
		return http.StatusBadRequest, "missing host"
	}
	requested, ok := hostOnly(req.Host)
	if !ok || normaliseHost(requested) != normaliseHost(host) {
		return http.StatusForbidden, "Host header does not match CONNECT host"
	}
	// Normalised once and used for every check below, so "-X get" cannot
	// satisfy a GET policy and then skip the GET/HEAD restrictions.
	normalizedMethod := strings.ToUpper(req.Method)
	if !isMethodAllowed(host, normalizedMethod, cfg) {
		return http.StatusForbidden, "method not allowed"
	}
	if requestURLLength(req) > maxURLBytes {
		return http.StatusRequestURITooLong, "URL too long"
	}
	// A body on GET or HEAD is forwarded verbatim, so a read-only method
	// policy would not be read-only: the origin may act on what it carries.
	if (normalizedMethod == "GET" || normalizedMethod == "HEAD") && hasRequestBody(req) {
		return http.StatusForbidden, "body not allowed on this method"
	}
	if isWebSocketUpgrade(req) {
		policy, _ := lookupPolicy(host, cfg)
		if !policy.AllowAll {
			return http.StatusForbidden, "WebSocket not allowed"
		}
	}
	return 0, ""
}

// Assembled before writing because w is a TLS connection, which emits a record
// per Write, and Header.Write issues four per header. Clients that count small
// reads to spot a slow-drip attack reject a handshake split that finely.
func writeSwitchingProtocols(w io.Writer, resp *http.Response) error {
	var buf bytes.Buffer
	fmt.Fprintf(&buf, "HTTP/1.1 %d %s\r\n", resp.StatusCode, http.StatusText(resp.StatusCode))
	if err := resp.Header.Write(&buf); err != nil {
		return err
	}
	buf.WriteString("\r\n")
	_, err := w.Write(buf.Bytes())
	return err
}

func writeStatus(w io.Writer, code int) error {
	resp := &http.Response{
		StatusCode: code,
		Status:     fmt.Sprintf("%d %s", code, http.StatusText(code)),
		ProtoMajor: 1,
		ProtoMinor: 1,
		Header:     make(http.Header),
	}
	resp.Header.Set("Connection", "close")
	return resp.Write(w)
}

func tunnel(clientR io.Reader, clientW io.Writer, upstreamR io.Reader, upstreamW io.Writer) {
	done := make(chan struct{}, 2)
	go func() {
		io.Copy(upstreamW, clientR)
		done <- struct{}{}
	}()
	go func() {
		io.Copy(clientW, upstreamR)
		done <- struct{}{}
	}()
	<-done
}

// errBlockedAddress marks a policy refusal to dial, as distinct from a dial
// that was attempted and failed, so callers answer 403 rather than 502.
var errBlockedAddress = errors.New("host resolves to a blocked address")

// Hosts already recorded as allowed. A session touches few hosts but makes
// many requests, so the log records first contact per host: a line per
// request would bury the denials it sits beside.
var allowedHosts sync.Map

// firstContact reports whether host has not been allowed before, and marks it
// allowed. It is called only after a request has passed the filters, so a host
// whose every request is refused never appears as allowed.
func firstContact(host string) bool {
	_, seen := allowedHosts.LoadOrStore(host, struct{}{})
	return !seen
}

func logAllowed(host string) {
	if firstContact(host) {
		fmt.Fprintf(os.Stderr, "%s allowed: %s\n", time.Now().Format(time.RFC3339), host)
	}
}

// isBlockedAddr reports whether ip is an address the proxy must never dial.
// The allowlist matches names, and the address behind a name is chosen by
// whoever controls its DNS: an allowlisted name pointed at 127.0.0.1 would
// reach exactly the host services allowedHostPorts exists to gate, since
// the proxy runs on the host outside the sandbox's confinement. Private
// ranges are deliberately not blocked: allowlisting an internal server is a
// legitimate configuration.
func isBlockedAddr(ip net.IP) bool {
	// Judge an IPv4-mapped address such as ::ffff:127.0.0.1 by its v4 value.
	if v4 := ip.To4(); v4 != nil {
		ip = v4
	}
	return ip.IsLoopback() ||
		ip.IsUnspecified() ||
		ip.IsLinkLocalUnicast() ||
		ip.IsLinkLocalMulticast()
}

// resolveVetted resolves host once and returns an "ip:port" literal safe to
// dial. The caller dials the literal rather than the name, so a second
// lookup answering with a blocked address after the check has nothing to win.
func resolveVetted(host, port string) (string, error) {
	ips, err := net.LookupIP(host)
	if err != nil {
		return "", err
	}
	if len(ips) == 0 {
		return "", fmt.Errorf("no addresses for %q", host)
	}
	for _, ip := range ips {
		if isBlockedAddr(ip) {
			return "", fmt.Errorf("%q resolves to %s: %w", host, ip, errBlockedAddress)
		}
	}
	return net.JoinHostPort(ips[0].String(), port), nil
}

func dialFailureStatus(err error) int {
	if errors.Is(err, errBlockedAddress) {
		return http.StatusForbidden
	}
	return http.StatusBadGateway
}

// refuseConn answers a connection there is no slot for. Logged once, because
// the refusal is driven by the client: a line each would let it flood the log.
var connLimitLogged sync.Once

func refuseConn(conn net.Conn) {
	defer conn.Close()
	connLimitLogged.Do(func() {
		fmt.Fprintf(os.Stderr, "%s connection limit reached (%d)\n", time.Now().Format(time.RFC3339), maxConns)
	})
	conn.SetWriteDeadline(time.Now().Add(refusalWriteTimeout))
	writeStatus(conn, http.StatusServiceUnavailable)
}

func main() {
	if len(os.Args) < 3 {
		fmt.Fprintln(os.Stderr, "usage: sandbox-proxy <config-file> <ca-cert-output-path> [listen-addr]")
		os.Exit(1)
	}
	cfg, err := loadConfig(os.Args[1])
	if err != nil {
		fmt.Fprintln(os.Stderr, "load config:", err)
		os.Exit(1)
	}

	redirects, err := parseRedirectEnv(os.Getenv("SANDBOX_PROXY_REDIRECT"))
	if err != nil {
		fmt.Fprintln(os.Stderr, "parse SANDBOX_PROXY_REDIRECT:", err)
		os.Exit(1)
	}

	ca, err := newCertAuthority()
	if err != nil {
		fmt.Fprintln(os.Stderr, "generate CA:", err)
		os.Exit(1)
	}
	if err := ca.writeCert(os.Args[2]); err != nil {
		fmt.Fprintln(os.Stderr, "write CA cert:", err)
		os.Exit(1)
	}

	listenAddr := "127.0.0.1"
	if len(os.Args) >= 4 {
		listenAddr = os.Args[3]
	}
	ln, err := net.Listen("tcp", listenAddr+":0")
	if err != nil {
		fmt.Fprintln(os.Stderr, "listen:", err)
		os.Exit(1)
	}
	fmt.Println(ln.Addr().(*net.TCPAddr).Port)
	os.Stdout.Sync()

	serve(ln, cfg, ca, redirects)
}

func serve(ln net.Listener, cfg Config, ca *certAuthority, redirects Redirects) {
	conns := make(chan struct{}, maxConns)
	var retryDelay time.Duration
	for {
		conn, err := ln.Accept()
		if err != nil {
			// Backing off rather than retrying at once: the errors that
			// persist, a closed listener or an exhausted descriptor table,
			// would otherwise spin this loop at the cost of a whole core.
			if retryDelay == 0 {
				// Logged on entry to the backoff rather than once per
				// process, so a storm that clears and returns is not silent
				// the second time, and not once per failure, which would let
				// the storm flood the log it is meant to show up in.
				fmt.Fprintf(os.Stderr, "%s accept error, backing off: %v\n", time.Now().Format(time.RFC3339), err)
				retryDelay = 5 * time.Millisecond
			} else {
				retryDelay *= 2
			}
			if retryDelay > time.Second {
				retryDelay = time.Second
			}
			time.Sleep(retryDelay)
			continue
		}
		retryDelay = 0
		select {
		case conns <- struct{}{}:
			go func() {
				defer func() { <-conns }()
				handle(conn, cfg, ca, redirects)
			}()
		default:
			// In a goroutine, so one client that never reads its refusal
			// cannot stall the accept loop for the write deadline.
			go refuseConn(conn)
		}
	}
}

func handle(conn net.Conn, cfg Config, ca *certAuthority, redirects Redirects) {
	defer conn.Close()
	hlr := &headerLimitReader{r: conn}
	br := bufio.NewReader(hlr)
	hlr.arm()
	req, err := http.ReadRequest(br)
	hlr.disarm()
	if err != nil {
		return
	}

	// A non-ASCII authority is more than one name: the allowlist reads it
	// folded, the resolver may map it, and Request.Write puts it on the wire
	// punycoded. Refused here rather than per request, because the CONNECT
	// branch writes its 200 and runs the client handshake before any of those.
	if hasNonASCII(req.Host) {
		fmt.Fprintf(os.Stderr, "%s blocked non-ASCII host: %s\n", time.Now().Format(time.RFC3339), req.Host)
		fmt.Fprintf(conn, "HTTP/1.1 403 Forbidden\r\n\r\n")
		return
	}

	host, ok := hostOnly(req.Host)
	if !ok {
		fmt.Fprintf(os.Stderr, "%s blocked unreadable host: %s\n", time.Now().Format(time.RFC3339), req.Host)
		fmt.Fprintf(conn, "HTTP/1.1 403 Forbidden\r\n\r\n")
		return
	}

	if req.Method == http.MethodConnect {
		if portOf(req.Host) != "443" {
			fmt.Fprintf(os.Stderr, "%s blocked non-443 CONNECT: %s\n", time.Now().Format(time.RFC3339), req.Host)
			fmt.Fprintf(conn, "HTTP/1.1 403 Forbidden\r\n\r\n")
			return
		}
		if !isDomainAllowed(host, cfg) {
			fmt.Fprintf(os.Stderr, "%s blocked domain: %s\n", time.Now().Format(time.RFC3339), req.Host)
			fmt.Fprintf(conn, "HTTP/1.1 403 Forbidden\r\n\r\n")
			return
		}
		fmt.Fprintf(conn, "HTTP/1.1 200 Connection Established\r\n\r\n")
		handleMITM(conn, host, req.Host, cfg, ca, redirects)
	} else {
		if p := portOf(req.Host); p != "" && p != "80" {
			fmt.Fprintf(os.Stderr, "%s blocked non-80 plaintext: %s\n", time.Now().Format(time.RFC3339), req.Host)
			fmt.Fprintf(conn, "HTTP/1.1 403 Forbidden\r\n\r\n")
			return
		}
		if !isDomainAllowed(host, cfg) {
			fmt.Fprintf(os.Stderr, "%s blocked domain: %s\n", time.Now().Format(time.RFC3339), req.Host)
			fmt.Fprintf(conn, "HTTP/1.1 403 Forbidden\r\n\r\n")
			return
		}
		if code, reason := applyFilters(req, host, cfg); code != 0 {
			fmt.Fprintf(os.Stderr, "%s blocked %s %s (%s, host: %s)\n",
				time.Now().Format(time.RFC3339), req.Method, req.URL, reason, req.Host)
			fmt.Fprintf(conn, "HTTP/1.1 %d %s\r\n\r\n", code, http.StatusText(code))
			return
		}
		logAllowed(host)
		if req.URL.Host == "" {
			req.URL.Host = req.Host
		}
		// Unconditionally, not only when the request carried no scheme: the
		// port check and resolveVetted below have both committed to plaintext,
		// so an absolute-form https:// URL would otherwise send the transport
		// into a TLS handshake against port 80.
		req.URL.Scheme = "http"
		if addr, ok := lookupRedirect(host, redirects); ok {
			if req.Host == "" {
				req.Host = req.URL.Host
			}
			req.URL.Host = addr
		} else {
			// Dial the vetted literal, so the transport reaches the address
			// that was checked instead of resolving the name a second time.
			vetted, err := resolveVetted(host, "80")
			if err != nil {
				code := dialFailureStatus(err)
				fmt.Fprintf(os.Stderr, "%s blocked %s %s (%v)\n",
					time.Now().Format(time.RFC3339), req.Method, req.URL, err)
				fmt.Fprintf(conn, "HTTP/1.1 %d %s\r\n\r\n", code, http.StatusText(code))
				return
			}
			if req.Host == "" {
				req.Host = req.URL.Host
			}
			req.URL.Host = vetted
		}
		req.RequestURI = "" // Must be empty for RoundTrip
		resp, err := directTransport.RoundTrip(req)
		if err != nil {
			fmt.Fprintf(os.Stderr, "%s upstream error for %s: %v\n", time.Now().Format(time.RFC3339), req.URL, err)
			fmt.Fprintf(conn, "HTTP/1.1 502 Bad Gateway\r\n\r\n")
			return
		}
		defer resp.Body.Close()
		if resp.StatusCode == http.StatusSwitchingProtocols && isWebSocketUpgrade(req) {
			rw, ok := resp.Body.(io.ReadWriteCloser)
			if !ok {
				fmt.Fprintf(conn, "HTTP/1.1 502 Bad Gateway\r\n\r\n")
				return
			}
			if err := writeSwitchingProtocols(conn, resp); err != nil {
				return
			}
			tunnel(br, conn, rw, rw)
			return
		}
		resp.Write(conn)
	}
}

func handleMITM(clientConn net.Conn, host, hostPort string, cfg Config, ca *certAuthority, redirects Redirects) {
	leafCert, err := ca.mintCert(host)
	if err != nil {
		fmt.Fprintf(os.Stderr, "%s mint cert error for %s: %v\n", time.Now().Format(time.RFC3339), host, err)
		return
	}

	tlsConfig := &tls.Config{
		Certificates: []tls.Certificate{*leafCert},
	}
	clientTLS := tls.Server(clientConn, tlsConfig)
	// The 200 has already gone out, so a client that never sends a ClientHello
	// would otherwise park this goroutine and its slot for good.
	clientConn.SetDeadline(time.Now().Add(clientHandshakeTimeout))
	err = clientTLS.Handshake()
	// Cleared unconditionally: left set it would expire mid-session, cutting
	// the keep-alive loop and any tunnel below it.
	clientConn.SetDeadline(time.Time{})
	if err != nil {
		fmt.Fprintf(os.Stderr, "%s client TLS handshake error for %s: %v\n", time.Now().Format(time.RFC3339), host, err)
		return
	}
	defer clientTLS.Close()

	// The upstream connection is established lazily on the first allowed
	// request, so blocked requests never touch the remote server.
	var upstreamConn net.Conn
	var upstreamBuf *bufio.Reader
	dialUpstream := func() error {
		if upstreamConn != nil {
			return nil
		}
		var conn net.Conn
		var err error
		if addr, ok := lookupRedirect(host, redirects); ok {
			// Redirects deliberately point at a local address, so they skip
			// vetting.
			conn, err = net.DialTimeout("tcp", addr, dialTimeout)
		} else {
			port := portOf(hostPort)
			if port == "" {
				port = "443"
			}
			var vetted string
			vetted, err = resolveVetted(host, port)
			if err != nil {
				return err
			}
			// ServerName stays the requested name so the upstream
			// certificate is validated against it, not the literal. The
			// dialer's timeout covers the handshake as well as the connect.
			conn, err = tls.DialWithDialer(&net.Dialer{Timeout: dialTimeout}, "tcp", vetted, &tls.Config{ServerName: host})
		}
		if err != nil {
			return err
		}
		upstreamConn = conn
		upstreamBuf = bufio.NewReader(upstreamConn)
		return nil
	}
	defer func() {
		if upstreamConn != nil {
			upstreamConn.Close()
		}
	}()

	// Above the TLS layer, so the cap applies to the decrypted header block.
	clientLimit := &headerLimitReader{r: clientTLS}
	clientBuf := bufio.NewReader(clientLimit)
	for {
		clientLimit.arm()
		req, err := http.ReadRequest(clientBuf)
		clientLimit.disarm()
		if err != nil {
			return
		}

		if code, reason := applyFilters(req, host, cfg); code != 0 {
			fmt.Fprintf(os.Stderr, "%s blocked %s https://%s%s (%s)\n",
				time.Now().Format(time.RFC3339), req.Method, host, req.URL.Path, reason)
			writeStatus(clientTLS, code)
			return
		}
		logAllowed(host)

		if err := dialUpstream(); err != nil {
			fmt.Fprintf(os.Stderr, "%s upstream dial error for %s: %v\n", time.Now().Format(time.RFC3339), hostPort, err)
			writeStatus(clientTLS, dialFailureStatus(err))
			return
		}

		// Forwarded directly rather than through http.Transport: the TLS
		// conn is managed here to support keep-alive.
		req.URL.Scheme = ""
		req.URL.Host = ""
		req.RequestURI = req.URL.RequestURI()
		if err := req.Write(upstreamConn); err != nil {
			fmt.Fprintf(os.Stderr, "%s upstream write error for %s: %v\n", time.Now().Format(time.RFC3339), host, err)
			return
		}
		resp, err := http.ReadResponse(upstreamBuf, req)
		if err != nil {
			fmt.Fprintf(os.Stderr, "%s upstream read error for %s: %v\n", time.Now().Format(time.RFC3339), host, err)
			return
		}
		if resp.StatusCode == http.StatusSwitchingProtocols && isWebSocketUpgrade(req) {
			resp.Body.Close()
			if err := writeSwitchingProtocols(clientTLS, resp); err != nil {
				return
			}
			tunnel(clientBuf, clientTLS, upstreamBuf, upstreamConn)
			return
		}
		if err := resp.Write(clientTLS); err != nil {
			resp.Body.Close()
			return
		}
		resp.Body.Close()

		if resp.Close || req.Close {
			return
		}
	}
}
