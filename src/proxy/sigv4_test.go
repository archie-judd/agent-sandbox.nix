package main

import (
	"bufio"
	"io"
	"net/http"
	"strings"
	"testing"
)

func readRawRequest(t *testing.T, raw string) *http.Request {
	t.Helper()
	req, err := http.ReadRequest(bufio.NewReader(strings.NewReader(raw)))
	if err != nil {
		t.Fatalf("read request: %v", err)
	}
	return req
}

// Vectors from the AWS SigV4 test suite and the S3 signing examples. The
// client's signature is a placeholder; the proxy must produce the real one.
func TestResignSigV4MatchesAWSVectors(t *testing.T) {
	cases := []struct {
		name, secret, raw, want string
	}{
		{
			name:   "get-vanilla",
			secret: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY",
			raw: "GET / HTTP/1.1\r\nHost: example.amazonaws.com\r\nX-Amz-Date: 20150830T123600Z\r\n" +
				"Authorization: AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, SignedHeaders=host;x-amz-date, Signature=00\r\n\r\n",
			want: "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, SignedHeaders=host;x-amz-date, Signature=5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31",
		},
		{
			name:   "s3 get object",
			secret: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
			raw: "GET /test.txt HTTP/1.1\r\nHost: examplebucket.s3.amazonaws.com\r\nRange: bytes=0-9\r\n" +
				"x-amz-content-sha256: e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855\r\nx-amz-date: 20130524T000000Z\r\n" +
				"Authorization: AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request,SignedHeaders=host;range;x-amz-content-sha256;x-amz-date,Signature=00\r\n\r\n",
			want: "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request, SignedHeaders=host;range;x-amz-content-sha256;x-amz-date, Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41",
		},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			req := readRawRequest(t, c.raw)
			if err := resignSigV4(req, c.secret); err != nil {
				t.Fatalf("resignSigV4: %v", err)
			}
			if got := req.Header.Get("Authorization"); got != c.want {
				t.Errorf("Authorization = %q, want %q", got, c.want)
			}
		})
	}
}

func TestResignSigV4KeepsTheBodyItHashes(t *testing.T) {
	req := readRawRequest(t, "POST / HTTP/1.1\r\nHost: sts.amazonaws.com\r\nContent-Length: 4\r\nX-Amz-Date: 20261127T000000Z\r\n"+
		"Authorization: AWS4-HMAC-SHA256 Credential=AKID/20261127/us-east-1/sts/aws4_request, SignedHeaders=content-length;host;x-amz-date, Signature=00\r\n\r\nbody")
	if err := resignSigV4(req, "secret"); err != nil {
		t.Fatalf("resignSigV4: %v", err)
	}
	if body, _ := io.ReadAll(req.Body); string(body) != "body" {
		t.Errorf("body = %q, want it forwarded intact", body)
	}
}

func TestResignSigV4(t *testing.T) {
	const auth = "Authorization: AWS4-HMAC-SHA256 Credential=AKID/20261127/us-east-1/s3/aws4_request, SignedHeaders=host;x-amz-date, Signature=00\r\n"
	cases := []struct {
		name, raw, wantErr string
	}{
		{name: "unsigned passes through", raw: "GET / HTTP/1.1\r\nHost: s3.amazonaws.com\r\n\r\n"},
		{name: "other scheme", raw: "GET / HTTP/1.1\r\nHost: s3.amazonaws.com\r\nAuthorization: Bearer x\r\n\r\n", wantErr: "not an AWS4-HMAC-SHA256"},
		{name: "date outside scope", raw: "GET / HTTP/1.1\r\nHost: s3.amazonaws.com\r\nX-Amz-Date: 20250101T000000Z\r\n" + auth + "\r\n", wantErr: "X-Amz-Date"},
		{name: "signed chunks", raw: "PUT /k HTTP/1.1\r\nHost: s3.amazonaws.com\r\nX-Amz-Date: 20261127T000000Z\r\nX-Amz-Content-Sha256: STREAMING-AWS4-HMAC-SHA256-PAYLOAD\r\n" + auth + "\r\n", wantErr: "signed chunked"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			err := resignSigV4(readRawRequest(t, c.raw), "secret")
			if c.wantErr == "" && err != nil || c.wantErr != "" && (err == nil || !strings.Contains(err.Error(), c.wantErr)) {
				t.Errorf("err = %v, want %q", err, c.wantErr)
			}
		})
	}
}
