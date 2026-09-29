#!/usr/bin/env python3
"""Tests for net.get's handling of bad downloads.  python3 -m unittest tools/test_net.py"""

import hashlib
import sys
import threading
import unittest
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import net  # noqa: E402

BODY = b"%PDF-1.7 " + b"x" * 5000


class FlakyHandler(BaseHTTPRequestHandler):
    """First response is cut off (the Mac run's failure), later ones are whole."""
    calls = 0

    def do_GET(self):
        type(self).calls += 1
        self.send_response(200)
        self.send_header("Content-Length", str(len(BODY)))
        self.end_headers()
        self.wfile.write(BODY[:1000] if type(self).calls == 1 else BODY)

    def log_message(self, *args):
        pass


class NetTests(unittest.TestCase):
    def setUp(self):
        FlakyHandler.calls = 0
        self.server = HTTPServer(("127.0.0.1", 0), FlakyHandler)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.url = f"http://127.0.0.1:{self.server.server_port}/paper.pdf"
        self.addCleanup(self.server.shutdown)
        self.addCleanup(self.server.server_close)
        net.DEFAULT_SPACING = 0
        net.RETRY_DELAY = 0

    def test_cut_off_download_is_retried_not_returned(self):
        body = net.get(self.url, cache=False, attempts=3, sha256=hashlib.sha256(BODY).hexdigest())
        self.assertEqual(body, BODY)
        self.assertEqual(FlakyHandler.calls, 2)

    def test_wrong_checksum_fails_after_retries(self):
        with self.assertRaises(net.FetchError):
            net.get(self.url, cache=False, attempts=2, sha256="0" * 64)


if __name__ == "__main__":
    unittest.main()
