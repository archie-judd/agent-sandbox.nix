package main

import (
	"bufio"
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
	"math/big"
	"net"
	"net/http"
	"os"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

type DomainPolicy struct {
	AllowAll bool
	Methods  map[string]bool
}

// The "*" key is the default policy.
type Config map[string]DomainPolicy

// Redirects maps a lowercase hostname to a local "host:port" address the
// proxy dials instead of resolving the original host. A test-harness escape
// hatch, set via SANDBOX_PROXY_REDIRECT as "host=addr:port[,...]".
type Redirects map[string]string

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
		host := strings.ToLower(strings.TrimSpace(entry[:eq]))
		addr := strings.TrimSpace(entry[eq+1:])
		if host == "" || addr == "" {
			return nil, fmt.Errorf("invalid redirect entry %q: empty host or address", entry)
		}
		out[host] = addr
	}
	return out, nil
}

const maxURLBytes = 8192

// Proxy nil rather than ProxyFromEnvironment, so the proxy itself does not
// route through another proxy on the host.
var directTransport = &http.Transport{
	Proxy: nil,
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
		domain = strings.ToLower(domain)
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
	return cfg, nil
}

// When multiple suffix entries match, the longest (most specific) wins.
func lookupPolicy(host string, cfg Config) (DomainPolicy, bool) {
	host = strings.ToLower(host)
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
	host = strings.ToLower(host)
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

func hostOnly(addr string) string {
	h, _, err := net.SplitHostPort(addr)
	if err != nil {
		return addr
	}
	return h
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
		return http.StatusForbidden, "WebSocket not allowed"
	}
	return 0, ""
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
// reach exactly the host services allowedLocalPorts exists to gate, since
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

	for {
		conn, err := ln.Accept()
		if err != nil {
			continue
		}
		go handle(conn, cfg, ca, redirects)
	}
}

func handle(conn net.Conn, cfg Config, ca *certAuthority, redirects Redirects) {
	defer conn.Close()
	br := bufio.NewReader(conn)
	req, err := http.ReadRequest(br)
	if err != nil {
		return
	}

	host := hostOnly(req.Host)

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
		if req.URL.Scheme == "" {
			req.URL.Scheme = "http"
		}
		if addr, ok := lookupRedirect(host, redirects); ok {
			if req.Host == "" {
				req.Host = req.URL.Host
			}
			req.URL.Host = addr
			req.URL.Scheme = "http"
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
	if err := clientTLS.Handshake(); err != nil {
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
			conn, err = net.Dial("tcp", addr)
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
			// certificate is validated against it, not the literal.
			conn, err = tls.Dial("tcp", vetted, &tls.Config{ServerName: host})
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

	clientBuf := bufio.NewReader(clientTLS)
	for {
		req, err := http.ReadRequest(clientBuf)
		if err != nil {
			return
		}

		if code, reason := applyFilters(req, host, cfg); code != 0 {
			fmt.Fprintf(os.Stderr, "%s blocked %s https://%s%s (%s)\n",
				time.Now().Format(time.RFC3339), req.Method, host, req.URL.Path, reason)
			resp := &http.Response{
				StatusCode: code,
				Status:     fmt.Sprintf("%d %s", code, http.StatusText(code)),
				ProtoMajor: 1,
				ProtoMinor: 1,
				Header:     make(http.Header),
			}
			resp.Header.Set("Connection", "close")
			resp.Write(clientTLS)
			return
		}
		logAllowed(host)

		if err := dialUpstream(); err != nil {
			fmt.Fprintf(os.Stderr, "%s upstream dial error for %s: %v\n", time.Now().Format(time.RFC3339), hostPort, err)
			code := dialFailureStatus(err)
			resp := &http.Response{
				StatusCode: code,
				Status:     fmt.Sprintf("%d %s", code, http.StatusText(code)),
				ProtoMajor: 1,
				ProtoMinor: 1,
				Header:     make(http.Header),
			}
			resp.Write(clientTLS)
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
