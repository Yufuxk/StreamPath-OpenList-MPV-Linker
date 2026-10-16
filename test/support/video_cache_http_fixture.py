"""合成 Range 来源；吞吐测量不限速，界面测量固定速率，只监听本机。"""
import json
import re
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

BLOCK = bytes(range(256)) * 256
RATE = 16 * 1024 * 1024
PERF_RATE = int(sys.argv[2]) * 1024 * 1024 if len(sys.argv) > 2 else 0


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_):
        pass

    def do_GET(self):
        background = self.path.endswith("background.mkv")
        size = 4 * 1024**3 if background else 1024**3
        match = re.fullmatch(r"bytes=(\d+)-(\d+)", self.headers.get("Range", ""))
        start, end = map(int, match.groups()) if match else (0, size - 1)
        self.send_response(206 if match else 200)
        self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        self.send_header("Content-Length", str(end - start + 1))
        self.send_header("ETag", '"video-cache-fixture-v1"')
        self.end_headers()
        sent = 0
        begun = time.monotonic()
        try:
            for position in range(start, end + 1, len(BLOCK)):
                count = min(len(BLOCK), end - position + 1)
                offset = position % 256
                block = BLOCK if offset == 0 else BLOCK[offset:] + BLOCK[:offset]
                self.wfile.write(block[:count])
                sent += count
                limit = RATE if background else PERF_RATE
                if limit:
                    delay = sent / limit - (time.monotonic() - begun)
                    if delay > 0:
                        time.sleep(delay)
        except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError):
            pass


server = ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1]) if len(sys.argv) > 1 else 0), Handler)
print(json.dumps({"port": server.server_port}), flush=True)
server.serve_forever()
