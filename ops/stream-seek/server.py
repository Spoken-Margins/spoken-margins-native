import http.server, socketserver, os, sys, time, json, threading

ROOT = os.path.abspath(sys.argv[4]) if len(sys.argv) > 4 else os.getcwd()
RATE = float(sys.argv[2]) if len(sys.argv) > 2 else 2_500_000  # bytes per second per connection
# usage: server.py <port> <bytes/s> <latency s> <directory of mp3 files>
LATENCY = float(sys.argv[3]) if len(sys.argv) > 3 else 0.05
served = {}
lock = threading.Lock()

class H(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *a): pass
    def do_GET(self):
        if self.path.startswith("/stats"):
            with lock: body = json.dumps(served).encode()
            self.send_response(200); self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body); return
        if self.path.startswith("/reset"):
            with lock: served.clear()
            self.send_response(200); self.send_header("Content-Length", "0"); self.end_headers(); return
        name = self.path.split("?")[0].lstrip("/")
        path = os.path.join(ROOT, name)
        size = os.path.getsize(path)
        start, end = 0, size - 1
        rng = self.headers.get("Range")
        time.sleep(LATENCY)
        if rng:
            a, b = rng.replace("bytes=", "").split("-")
            start = int(a) if a else 0
            end = int(b) if b else size - 1
            self.send_response(206)
            self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        else:
            self.send_response(200)
        self.send_header("Content-Type", "audio/mpeg")
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Length", str(end - start + 1))
        self.end_headers()
        try:
            with open(path, "rb") as f:
                f.seek(start); left = end - start + 1
                while left > 0:
                    chunk = f.read(min(65536, left))
                    self.wfile.write(chunk)
                    with lock: served[name] = served.get(name, 0) + len(chunk)
                    left -= len(chunk)
                    time.sleep(len(chunk) / RATE)
        except (BrokenPipeError, ConnectionResetError):
            pass

class S(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True

S(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
