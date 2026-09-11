#!/usr/bin/env python3
"""Start an in-sandbox loopback HTTP server and fetch it from the same process.

Exit codes:
  0  client reached the server
  10 client could not reach the ready server
  20 server setup failed
"""
import http.server
import socket
import sys
import threading
import time


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = b"inside-ok"
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format, *args):
        return


def main():
    if len(sys.argv) not in (2, 3):
        print("usage: inside-http-loopback.py PORT [CONNECT_HOST]", file=sys.stderr)
        return 20

    port = int(sys.argv[1])
    connect_host = sys.argv[2] if len(sys.argv) == 3 else "127.0.0.1"

    try:
        server = http.server.ThreadingHTTPServer(("127.0.0.1", port), Handler)
    except Exception as exc:
        print(f"server setup failed: {exc}", file=sys.stderr)
        return 20

    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()

    last_error = None
    deadline = time.time() + 3
    try:
        while time.time() < deadline:
            try:
                with socket.create_connection((connect_host, port), timeout=0.5) as sock:
                    sock.sendall(
                        b"GET / HTTP/1.1\r\n"
                        b"Host: localhost\r\n"
                        b"Connection: close\r\n\r\n"
                    )
                    chunks = []
                    while True:
                        chunk = sock.recv(1024)
                        if not chunk:
                            break
                        chunks.append(chunk)
                    response = b"".join(chunks)
                if b"200 OK" in response and b"inside-ok" in response:
                    return 0
                last_error = f"unexpected response: {response!r}"
            except PermissionError as exc:
                last_error = exc
                break
            except OSError as exc:
                last_error = exc
                time.sleep(0.1)

        print(f"client could not reach ready server: {last_error}", file=sys.stderr)
        return 10
    finally:
        server.shutdown()
        server.server_close()


if __name__ == "__main__":
    sys.exit(main())
