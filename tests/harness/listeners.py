import socket
import threading
from collections.abc import Iterator
from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


class _OkHandler(BaseHTTPRequestHandler):
    def _respond(self) -> None:
        length = int(self.headers.get("Content-Length") or 0)
        if length:
            self.rfile.read(length)
        body = b"ok"
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    do_GET = do_POST = do_PUT = do_DELETE = do_HEAD = _respond

    def log_message(self, format: str, *args: object) -> None:
        pass


class _Server(ThreadingHTTPServer):
    daemon_threads = True


class _Server6(_Server):
    address_family = socket.AF_INET6


@contextmanager
def tcp_listener(port: int, host: str = "127.0.0.1") -> Iterator[None]:
    server_class = _Server6 if ":" in host else _Server
    server = server_class((host, port), _OkHandler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield
    finally:
        server.shutdown()
        server.server_close()


@contextmanager
def udp_listener(port: int, host: str = "127.0.0.1") -> Iterator[list[bytes]]:
    received: list[bytes] = []
    stop = threading.Event()
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind((host, port))
    sock.settimeout(0.1)

    def receive() -> None:
        while not stop.is_set():
            try:
                data, _ = sock.recvfrom(65536)
            except TimeoutError:
                continue
            except OSError:
                return
            received.append(data)

    thread = threading.Thread(target=receive, daemon=True)
    thread.start()
    try:
        yield received
    finally:
        stop.set()
        thread.join()
        sock.close()


@contextmanager
def unix_listener(path: Path) -> Iterator[None]:
    if len(str(path)) > 100:
        raise ValueError(f"socket path exceeds the sun_path budget: {path}")
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(str(path))
    server.listen(16)

    def serve() -> None:
        while True:
            try:
                connection, _ = server.accept()
            except OSError:
                return
            with connection:
                while connection.recv(4096):
                    pass

    threading.Thread(target=serve, daemon=True).start()
    try:
        yield
    finally:
        server.close()
        path.unlink(missing_ok=True)
