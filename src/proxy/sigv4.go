package main

import (
	"bytes"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"regexp"
	"sort"
	"strconv"
	"strings"
)

// The client signs with a placeholder secret; resignSigV4 keeps everything it
// chose (access key ID, scope, date, signed headers) and replaces only the
// signature, computed with the real secret.
var sigV4Authorization = regexp.MustCompile(`^AWS4-HMAC-SHA256 Credential=([^/,\s]+)/(\d{8})/([^/,\s]+)/([^/,\s]+)/aws4_request,\s*SignedHeaders=([a-z0-9;-]+),\s*Signature=[0-9a-f]+$`)

// Bounds the body held in memory to hash it, for services that do not send
// x-amz-content-sha256.
const maxSigV4Body = 64 << 20

func resignSigV4(req *http.Request, secret string) error {
	authorization := req.Header.Get("Authorization")
	if authorization == "" {
		// Unsigned, or presigned in the query string: nothing to replace.
		return nil
	}
	m := sigV4Authorization.FindStringSubmatch(authorization)
	if m == nil {
		return errors.New("Authorization is not an AWS4-HMAC-SHA256 signature")
	}
	accessKeyID, date, region, service, signedHeaders := m[1], m[2], m[3], m[4], m[5]
	amzDate := req.Header.Get("X-Amz-Date")
	if !strings.HasPrefix(amzDate, date+"T") {
		return errors.New("X-Amz-Date is missing or outside the credential scope")
	}

	payloadHash := req.Header.Get("X-Amz-Content-Sha256")
	if strings.HasPrefix(payloadHash, "STREAMING-AWS4-") {
		return errors.New("signed chunked uploads cannot be re-signed; use unsigned payload chunks")
	}
	if payloadHash == "" {
		body, err := io.ReadAll(io.LimitReader(req.Body, maxSigV4Body+1))
		if err != nil {
			return fmt.Errorf("read body: %w", err)
		}
		if len(body) > maxSigV4Body {
			return errors.New("body too large to hash for signing")
		}
		sum := sha256.Sum256(body)
		payloadHash = hex.EncodeToString(sum[:])
		req.Body = io.NopCloser(bytes.NewReader(body))
	}

	path := req.URL.EscapedPath()
	if path == "" {
		path = "/"
	}
	// S3 signs the path as sent; every other service signs it escaped again.
	// shortcut: non-S3 paths are not dot-segment normalised, add it if a service sends such paths.
	if !strings.HasPrefix(service, "s3") {
		path = sigV4Escape(path, true)
	}

	query, err := url.ParseQuery(req.URL.RawQuery)
	if err != nil {
		return fmt.Errorf("parse query: %w", err)
	}
	keys := make([]string, 0, len(query))
	for k := range query {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	var pairs []string
	for _, k := range keys {
		values := append([]string(nil), query[k]...)
		sort.Strings(values)
		for _, v := range values {
			pairs = append(pairs, sigV4Escape(k, false)+"="+sigV4Escape(v, false))
		}
	}

	// http.ReadRequest moves Host and Content-Length out of the header map.
	var headers strings.Builder
	for _, name := range strings.Split(signedHeaders, ";") {
		var values []string
		switch name {
		case "host":
			values = []string{req.Host}
		case "content-length":
			values = []string{strconv.FormatInt(req.ContentLength, 10)}
		default:
			values = req.Header.Values(name)
		}
		for i, v := range values {
			values[i] = strings.Join(strings.Fields(v), " ")
		}
		headers.WriteString(name + ":" + strings.Join(values, ",") + "\n")
	}

	canonical := strings.Join([]string{req.Method, path, strings.Join(pairs, "&"), headers.String(), signedHeaders, payloadHash}, "\n")
	scope := date + "/" + region + "/" + service + "/aws4_request"
	canonicalHash := sha256.Sum256([]byte(canonical))
	stringToSign := "AWS4-HMAC-SHA256\n" + amzDate + "\n" + scope + "\n" + hex.EncodeToString(canonicalHash[:])

	key := []byte("AWS4" + secret)
	for _, part := range []string{date, region, service, "aws4_request"} {
		key = hmacSHA256(key, part)
	}
	signature := hex.EncodeToString(hmacSHA256(key, stringToSign))
	req.Header.Set("Authorization", "AWS4-HMAC-SHA256 Credential="+accessKeyID+"/"+scope+", SignedHeaders="+signedHeaders+", Signature="+signature)
	return nil
}

func hmacSHA256(key []byte, data string) []byte {
	mac := hmac.New(sha256.New, key)
	mac.Write([]byte(data))
	return mac.Sum(nil)
}

// sigV4Escape percent-encodes everything but RFC 3986 unreserved characters.
func sigV4Escape(s string, keepSlash bool) string {
	var b strings.Builder
	for i := 0; i < len(s); i++ {
		c := s[i]
		if 'A' <= c && c <= 'Z' || 'a' <= c && c <= 'z' || '0' <= c && c <= '9' ||
			c == '-' || c == '_' || c == '.' || c == '~' || keepSlash && c == '/' {
			b.WriteByte(c)
		} else {
			fmt.Fprintf(&b, "%%%02X", c)
		}
	}
	return b.String()
}
