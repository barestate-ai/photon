#!/usr/bin/env python3
"""Fixture web server for tests and demos: static pages from this directory on 127.0.0.1.

With --tls-cert/--tls-key (a throwaway self-signed pair made by the test) it serves HTTPS, so a
page can show the browser's certificate-error state.

GET /__health  -> 200 "ok <version>", the version being a hash of this file at start, so a harness
                  can tell a server that predates the current endpoints from the current one
GET /__log     -> the request log, one "METHOD /path STATUS" line per request, in order
                  (?since=N skips the first N lines). Pages report events by requesting
                  /__beacon?name=value; those appear in the log like any other request.
GET /slow-xhr?ms=N   -> "ok" after N ms
GET /slow-page?ms=N  -> a small page after N ms
GET /hang            -> no answer for 12 s (a navigation that does not finish)
GET /slow-image?ms=N -> a 1x1 GIF after N ms (default 12000)
GET /long-poll       -> "ok" after 15 s
Every held response (the four above) logs "HELD /path started", then "HELD /path delivered" or
"HELD /path aborted" when the client disconnected before the answer.
"""
import argparse
import hashlib
import base64
import http.server
import os
import select
import socket
import ssl
import threading
import time
from urllib.parse import parse_qs, urlsplit

ROOT = os.path.dirname(os.path.abspath(__file__))
with open(os.path.abspath(__file__), "rb") as source:
    VERSION = hashlib.sha256(source.read()).hexdigest()[:12]
LOG = []
LOCK = threading.Lock()
GIF = base64.b64decode("R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7")
# path -> (default delay in s, content type, body); a ?ms=N query overrides the delay.
HELD = {
    "/slow-xhr": (0, "text/plain", b"ok"),
    "/slow-page": (0, "text/html", b"<!doctype html><title>Slow page</title><h1>Slow page</h1>"),
    "/hang": (12, "text/html", b"<!doctype html><title>Slow page</title><h1>Slow page</h1>"),
    "/slow-image": (12, "image/gif", GIF),
    "/long-poll": (15, "text/plain", b"ok"),
}


class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=ROOT, **kwargs)

    def send_response(self, code, message=None):
        super().send_response(code, message)
        path = urlsplit(self.path).path
        if path not in ("/__health", "/__log"):
            with LOCK:
                LOG.append(f"{self.command} {self.path} {code}")

    def do_GET(self):
        parts = urlsplit(self.path)
        if parts.path == "/__health":
            self.reply(f"ok {VERSION}".encode())
        elif parts.path == "/__log":
            since = int(parse_qs(parts.query).get("since", ["0"])[0])
            with LOCK:
                lines = LOG[since:]
            self.reply(("".join(line + "\n" for line in lines)).encode())
        elif parts.path == "/__beacon":
            self.send_response(204)
            self.end_headers()
        elif parts.path in HELD:
            self.hold(parts)
        else:
            super().do_GET()

    def hold(self, parts):
        delay, kind, body = HELD[parts.path]
        delay = int(parse_qs(parts.query).get("ms", [delay * 1000])[0]) / 1000
        self.note(f"HELD {parts.path} started")
        # A client that went away makes the socket readable with nothing to read.
        deadline = time.monotonic() + delay
        try:
            while (left := deadline - time.monotonic()) > 0:
                if select.select([self.connection], [], [], left)[0] and not self.connection.recv(1, socket.MSG_PEEK):
                    return self.note(f"HELD {parts.path} aborted")
            self.reply(body, kind)
        except OSError:
            return self.note(f"HELD {parts.path} aborted")
        self.note(f"HELD {parts.path} delivered")

    def note(self, line):
        with LOCK:
            LOG.append(line)

    def reply(self, body, kind="text/plain"):
        self.send_response(200)
        self.send_header("Content-Type", kind + ("; charset=utf-8" if kind.startswith("text/") else ""))
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def end_headers(self):
        self.send_header("Cache-Control", "no-store")
        super().end_headers()

    def log_message(self, fmt, *args):
        pass


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=47810)
    parser.add_argument("--tls-cert", help="serve HTTPS with this certificate (and --tls-key)")
    parser.add_argument("--tls-key")
    args = parser.parse_args()
    server = http.server.ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    if args.tls_cert:
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(args.tls_cert, args.tls_key)
        server.socket = context.wrap_socket(server.socket, server_side=True)
    server.daemon_threads = True
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
