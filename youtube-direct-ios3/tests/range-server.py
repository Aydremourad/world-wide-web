"""Local fixtures for the range reader; no YouTube or external server needed."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit
import sys
import time

LENGTH = 262217


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        address = urlsplit(self.path)
        query = parse_qs(address.query).get("range", [None])[0]
        header = self.headers.get("Range")
        value = header.removeprefix("bytes=") if header else query
        if not value:
            self.send_error(400)
            return
        start, end = map(int, value.split("-"))
        rejected = (address.path == "/query" and header is not None) or (
            address.path == "/header" and query is not None)
        if address.path == "/switch":
            rejected = (start == 0 and header is not None) or (start > 0 and query is not None)
        # Emulate a server applying a URL slice first, then the HTTP range to
        # that smaller slice. The old dual-selector reader fails beyond chunk 0.
        if address.path == "/double" and query and header and start > 0:
            rejected = True
        if start >= LENGTH or (address.path == "/strict" and end >= LENGTH):
            rejected = True
        if rejected:
            self.send_response(416)
            self.send_header("Content-Range", f"bytes */{LENGTH}")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        end = min(end, LENGTH - 1)
        if address.path == "/slow" or (address.path == "/contended" and start == 65536):
            time.sleep(3)
        if address.path == "/ignore":
            start, end = 0, LENGTH - 1
        data = bytes(index % 251 for index in range(start, end + 1))
        if address.path == "/short":
            data = data[:-1]
        self.send_response(200 if address.path == "/ignore" else 206)
        self.send_header("Content-Type", "video/mp4")
        self.send_header("Content-Length", str(len(data)))
        range_start = start + 1 if address.path == "/wrong" else start
        self.send_header("Content-Range", f"bytes {range_start}-{end}/{LENGTH}")
        self.end_headers()
        try:
            self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError):
            pass


class FixtureServer(ThreadingHTTPServer):
    def server_bind(self):
        # Avoid macOS runner reverse-DNS delays for localhost during startup.
        self.socket.bind(self.server_address)
        self.server_address = self.socket.getsockname()
        self.server_name = "localhost"
        self.server_port = self.server_address[1]


server = FixtureServer(("127.0.0.1", 0), Handler)
with open(sys.argv[1], "w") as output:
    output.write(str(server.server_port))
server.serve_forever()
