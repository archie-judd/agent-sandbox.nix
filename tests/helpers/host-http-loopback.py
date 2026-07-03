#!/usr/bin/env python3
"""Serve a tiny HTTP response on one or more host loopback TCP ports."""
import signal
import socket
import sys
import threading


RESPONSE = b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok"


def serve(sock):
    while True:
        try:
            conn, _ = sock.accept()
            try:
                conn.recv(1024)
                conn.sendall(RESPONSE)
            finally:
                conn.close()
        except Exception:
            break


def main():
    if len(sys.argv) < 2:
        print("usage: host-http-loopback.py PORT [PORT ...]", file=sys.stderr)
        return 2

    sockets = []
    for port in [int(arg) for arg in sys.argv[1:]]:
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        sock.bind(("127.0.0.1", port))
        sock.listen(8)
        sockets.append(sock)

    for sock in sockets:
        threading.Thread(target=serve, args=(sock,), daemon=True).start()

    sys.stdout.write("READY\n")
    sys.stdout.flush()
    signal.pause()
    return 0


if __name__ == "__main__":
    sys.exit(main())
