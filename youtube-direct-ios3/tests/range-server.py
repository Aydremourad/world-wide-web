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
        start, end = map(int, parse_qs(address.query)["range"][0].split("-"))
        if self.headers.get("Range") != f"bytes={start}-{end}":
            self.send_error(400)
            return
        if address.path == "/slow":
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


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
with open(sys.argv[1], "w") as output:
    output.write(str(server.server_port))
server.serve_forever()
