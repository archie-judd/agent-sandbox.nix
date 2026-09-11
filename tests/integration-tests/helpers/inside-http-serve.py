#!/usr/bin/env python3
"""Serve HTTP inside the sandbox until killed.

Binds the given address and port, prints READY once listening, and answers
every GET with 'inbound-ok'. The published-ports tests background the sandbox
around this server and drive it from the host side.
"""
import http.server
import sys


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = b"inbound-ok"
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format, *args):
        return


def main():
    if len(sys.argv) != 3:
        print("usage: inside-http-serve.py <bind-addr> <port>", file=sys.stderr)
        return 2
    server = http.server.HTTPServer((sys.argv[1], int(sys.argv[2])), Handler)
    print("READY", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    sys.exit(main())
