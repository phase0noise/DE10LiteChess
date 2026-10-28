#!/usr/bin/env python3
"""Chess HTTP/SPI bridge. Uses only the Python standard library."""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path
from socketserver import ThreadingMixIn
from threading import RLock
from wsgiref.simple_server import WSGIRequestHandler, WSGIServer, make_server

from spi_chess import ChessSPI, SpiCommunicationError, SpiDevice, DEFAULT_SPEED_HZ, engine_status

ASSETS = {
    "/": ("index.html", "text/html; charset=utf-8"),
    "/index.html": ("index.html", "text/html; charset=utf-8"),
    "/chess.js": ("chess.js", "application/javascript; charset=utf-8"),
    "/fpga.js": ("fpga.js", "application/javascript; charset=utf-8"),
    "/app.js": ("app.js", "application/javascript; charset=utf-8"),
    "/style.css": ("style.css", "text/css; charset=utf-8"),
    "/pieces.png": ("pieces.png", "image/png"),
}
REASONS = {200: "OK", 400: "Bad Request", 404: "Not Found", 405: "Method Not Allowed",
           408: "Request Timeout", 413: "Content Too Large", 503: "Service Unavailable"}


class HardwareManager:
    def __init__(self, factory):
        self.factory = factory
        self.link = None
        self.lock = RLock()

    def command(self, payload):
        with self.lock:
            try:
                if self.link is None:
                    self.link = self.factory()
                return self.link.command(payload)
            except (SpiCommunicationError, OSError):
                self.close()
                raise

    def close(self):
        with self.lock:
            if self.link is not None:
                try:
                    self.link.close()
                finally:
                    self.link = None


class ChessApp:
    def __init__(self, factory=None):
        self.folder = Path(__file__).resolve().parent
        self.bus = int(os.environ.get("CHESS_SPI_BUS", "0"))
        self.device = int(os.environ.get("CHESS_SPI_DEVICE", "0"))
        self.speed = int(os.environ.get("CHESS_SPI_SPEED", str(DEFAULT_SPEED_HZ)))
        if factory is None:
            factory = lambda: ChessSPI(SpiDevice(self.bus, self.device, self.speed))
        self.hardware = HardwareManager(factory)

    @staticmethod
    def json_response(http_status, **data):
        return http_status, "application/json", json.dumps(data).encode("utf-8")

    def dispatch(self, environ):
        path = environ.get("PATH_INFO", "/")
        method = environ["REQUEST_METHOD"]
        if path == "/api/command":
            if method != "POST":
                return self.json_response(405, error="Use POST for commands")
            length_text = environ.get("CONTENT_LENGTH", "")
            if not length_text.isascii() or not length_text.isdigit():
                return self.json_response(400, error="Expected a Content-Length header")
            if len(length_text) > 10 or int(length_text) > 162:
                return self.json_response(413, error="Command body exceeds 162 bytes")
            length = int(length_text)
            if not 2 <= length <= 162 or length % 2 or environ.get("HTTP_TRANSFER_ENCODING"):
                return self.json_response(400, error="Expected 1..81 command bytes encoded as hexadecimal")
            try:
                raw = environ["wsgi.input"].read(length)
            except (TimeoutError, OSError):
                return self.json_response(408, error="Command body timed out")
            if len(raw) != length or any(c not in b"0123456789abcdefABCDEF" for c in raw):
                return self.json_response(400, error="Invalid hexadecimal body")
            try:
                status, data = self.hardware.command(bytes.fromhex(raw.decode("ascii")))
                return self.json_response(200, status=status, payload=data.hex())
            except (SpiCommunicationError, OSError) as error:
                return self.json_response(503, error=str(error))
        if method not in {"GET", "HEAD"}:
            return self.json_response(405, error="Use GET for this path")
        if path in ASSETS:
            name, content_type = ASSETS[path]
            try:
                return 200, content_type, (self.folder / name).read_bytes()
            except FileNotFoundError:
                return self.json_response(404, error=f"Missing {name}. Copy the whole Pi folder.")
        if path == "/api/info":
            return self.json_response(200, device="Raspberry Pi", board="DE0-CV",
                                      transport=f"SPI{self.bus}/CE{self.device}", speed_hz=self.speed)
        if path == "/healthz":
            try:
                status, data = self.hardware.command(b"\x00")
                if status:
                    return self.json_response(503, fpga=False,
                                              error=f"FPGA status command failed (status {status})")
                return self.json_response(200, fpga=True, **engine_status(data))
            except (SpiCommunicationError, OSError) as error:
                return self.json_response(503, fpga=False, error=str(error))
        return self.json_response(404, error="Unknown path")

    def __call__(self, environ, start_response):
        status, content_type, body = self.dispatch(environ)
        headers = [("Content-Type", content_type), ("Content-Length", str(len(body))),
                   ("Cache-Control", "no-store"), ("X-Content-Type-Options", "nosniff")]
        if status == 405:
            headers.append(("Allow", "POST" if environ.get("PATH_INFO") == "/api/command" else "GET, HEAD"))
        start_response(f"{status} {REASONS[status]}", headers)
        return [] if environ["REQUEST_METHOD"] == "HEAD" else [body]

    def close(self):
        self.hardware.close()


def create_app(factory=None):
    return ChessApp(factory)


class ChessHTTPServer(ThreadingMixIn, WSGIServer):
    daemon_threads = True
    block_on_close = False

    def get_request(self):
        connection, address = super().get_request()
        connection.settimeout(10)
        return connection, address


class QuietHandler(WSGIRequestHandler):
    def log_message(self, _format, *args):
        pass


def make_http_server(host, port, application):
    if ":" in host:
        import socket
        class IPv6Server(ChessHTTPServer):
            address_family = socket.AF_INET6
        server_class = IPv6Server
    else:
        server_class = ChessHTTPServer
    return make_server(host, port, application, server_class=server_class, handler_class=QuietHandler)


def serve(host="0.0.0.0", port=8080):
    application = create_app()
    try:
        with make_http_server(host, port, application) as server:
            print(f"Chess is running on port {server.server_port}. Ctrl+C stops it.", flush=True)
            print(f"On this Pi: http://127.0.0.1:{server.server_port}", flush=True)
            if sys.platform == "linux":
                try:
                    addresses = subprocess.run(["hostname", "-I"], capture_output=True,
                                               text=True, timeout=2, check=True).stdout.split()
                    for address in addresses:
                        if ":" not in address:
                            print(f"On your network: http://{address}:{server.server_port}", flush=True)
                except (OSError, subprocess.SubprocessError):
                    pass
            try:
                server.serve_forever()
            except KeyboardInterrupt:
                pass
    except OSError as error:
        raise SystemExit(f"Cannot start the HTTP server: {error}\n"
                         "Another app may be using this port. Choose --port 8081 or stop that app.") from error
    finally:
        application.close()


# Retain the WSGI entry point for an existing service during migration.
app = create_app()

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default=os.environ.get("CHESS_HOST", "0.0.0.0"))
    parser.add_argument("--port", type=int, default=os.environ.get("CHESS_PORT", "8080"))
    args = parser.parse_args()
    serve(args.host, args.port)
