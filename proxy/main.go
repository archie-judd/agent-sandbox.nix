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

// DomainPolicy describes which HTTP methods are allowed for a domain.
type DomainPolicy struct {
	AllowAll bool
	Methods  map[string]bool
}

// Config maps domain names to their policies. The "*" key is the default policy.
type Config map[string]DomainPolicy

// Redirects maps a lowercase hostname to a local "host:port" address.
// When a request arrives for one of these hosts, the proxy dials the local
// address with plain TCP instead of resolving and dialing the original host.
//
// This is an internal escape hatch used by the test harness to point fake
// domains at a local httpbin instance, so tests don't depend on public
// services. Set via the SANDBOX_PROXY_REDIRECT env var. Not part of the
// public API and not documented for end users.
type Redirects map[string]string

// parseRedirectEnv parses SANDBOX_PROXY_REDIRECT.
// Format: "host=addr:port[,host=addr:port]..."
// All upstream dials are plain TCP; the proxy still MITMs client HTTPS
// with its own CA, so HTTPS requests still exercise the MITM path.
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

// directTransport bypasses ProxyFromEnvironment so the proxy itself
// doesn't try to route through another proxy on the host.
var directTransport = &http.Transport{
	Proxy: nil,
}

// knownHTTPMethods is the set of standard HTTP methods (RFC 9110).
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
		// Try string first ("*"), then array of methods
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

// lookupPolicy finds the policy for a host, falling back to the "*" default.
// When multiple suffix entries match, the longest (most specific) wins.
func lookupPolicy(host string, cfg Config) (DomainPolicy, bool) {
	host = strings.ToLower(host)
	if p, ok := cfg[host]; ok {
		return p, true
	}
	// Collect all suffix matches and pick the longest (most specific).
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

// lookupRedirect finds the redirect address for a host. Matches exact first,
// then longest suffix — mirrors lookupPolicy so a subdomain that passes the
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

// --- CA and certificate minting ---

const maxCachedCerts = 1024

// certAuthority holds the ephemeral CA used to mint per-host leaf certificates.
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
	// If hostname looks like an IP, add it as an IP SAN
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
	// Avoid unbounded cache growth: stop caching after maxCachedCerts entries.
	if ca.cacheSize.Load() < maxCachedCerts {
		if _, loaded := ca.cache.LoadOrStore(hostname, tlsCert); !loaded {
			ca.cacheSize.Add(1)
		}
	}
	return tlsCert, nil
}

// --- Filtering helpers ---

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

// applyFilters checks method, URL length, and WebSocket restrictions.
// Returns an HTTP status code and reason if blocked, or 0 if allowed.
// Callers must check isDomainAllowed first; this only applies per-request filters.
func applyFilters(req *http.Request, host string, cfg Config) (int, string) {
	if !isMethodAllowed(host, req.Method, cfg) {
		return http.StatusForbidden, "method not allowed"
	}
	// URL length is only enforced for GET/HEAD where the URL carries the
	// full query; POST/PUT etc. use the request body for payload data.
	if (req.Method == "GET" || req.Method == "HEAD") && requestURLLength(req) > maxURLBytes {
		return http.StatusRequestURITooLong, "URL too long"
	}
	if isWebSocketUpgrade(req) {
		return http.StatusForbidden, "WebSocket not allowed"
	}
	return 0, ""
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
		if !isDomainAllowed(host, cfg) {
			fmt.Fprintf(os.Stderr, "%s blocked domain: %s\n", time.Now().Format(time.RFC3339), req.Host)
			fmt.Fprintf(conn, "HTTP/1.1 403 Forbidden\r\n\r\n")
			return
		}
		// MITM: intercept the TLS connection to inspect HTTP requests
		fmt.Fprintf(conn, "HTTP/1.1 200 Connection Established\r\n\r\n")
		handleMITM(conn, host, req.Host, cfg, ca, redirects)
	} else {
		// Plaintext HTTP — check domain first, then apply full filtering
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
		if req.URL.Host == "" {
			req.URL.Host = req.Host
		}
		if req.URL.Scheme == "" {
			req.URL.Scheme = "http"
		}
		// Apply redirect: dial the local override instead of the original
		// host, preserving the Host header the client sees.
		if addr, ok := lookupRedirect(host, redirects); ok {
			if req.Host == "" {
				req.Host = req.URL.Host
			}
			req.URL.Host = addr
			req.URL.Scheme = "http"
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
	// Mint a certificate for this host
	leafCert, err := ca.mintCert(host)
	if err != nil {
		fmt.Fprintf(os.Stderr, "%s mint cert error for %s: %v\n", time.Now().Format(time.RFC3339), host, err)
		return
	}

	// TLS handshake with the client
	tlsConfig := &tls.Config{
		Certificates: []tls.Certificate{*leafCert},
	}
	clientTLS := tls.Server(clientConn, tlsConfig)
	if err := clientTLS.Handshake(); err != nil {
		fmt.Fprintf(os.Stderr, "%s client TLS handshake error for %s: %v\n", time.Now().Format(time.RFC3339), host, err)
		return
	}
	defer clientTLS.Close()

	// Upstream connection is established lazily on the first allowed request,
	// so blocked requests never trigger a connection to the remote server.
	var upstreamConn net.Conn
	var upstreamBuf *bufio.Reader
	dialUpstream := func() error {
		if upstreamConn != nil {
			return nil
		}
		var conn net.Conn
		var err error
		if addr, ok := lookupRedirect(host, redirects); ok {
			conn, err = net.Dial("tcp", addr)
		} else {
			conn, err = tls.Dial("tcp", hostPort, &tls.Config{ServerName: host})
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

	// Read and forward HTTP requests over the decrypted TLS stream
	clientBuf := bufio.NewReader(clientTLS)
	for {
		req, err := http.ReadRequest(clientBuf)
		if err != nil {
			return // Client closed or protocol error
		}

		// Apply filters to the decrypted request
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

		// Dial upstream on first allowed request
		if err := dialUpstream(); err != nil {
			fmt.Fprintf(os.Stderr, "%s upstream dial error for %s: %v\n", time.Now().Format(time.RFC3339), hostPort, err)
			resp := &http.Response{
				StatusCode: http.StatusBadGateway,
				ProtoMajor: 1,
				ProtoMinor: 1,
				Header:     make(http.Header),
			}
			resp.Write(clientTLS)
			return
		}

		// Forward request directly to upstream (no http.Transport — we
		// manage the TLS conn ourselves to support keep-alive properly).
		req.URL.Scheme = ""
		req.URL.Host = ""
		// RequestURI must be the path for a direct (non-proxy) request
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

		// If either side signals close, stop
		if resp.Close || req.Close {
			return
		}
	}
}
