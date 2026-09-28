"""Recording HTTP client.

Every response the matcher reads is stored under fixtures/http/ keyed by
method, URL and body, so a scoring run can be replayed with no network.

Modes (env B3_HTTP, default "replay"):
  replay  - read fixtures only; a missing fixture raises MissingFixture.
  record  - use a fixture when present, otherwise fetch and store it.
  refresh - always fetch and overwrite.
"""
from __future__ import annotations

import gzip
import hashlib
import json
import os
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

FIXTURES = Path(__file__).resolve().parent.parent / "fixtures" / "http"
USER_AGENT = (
    "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) "
    "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
)


class MissingFixture(RuntimeError):
    pass


class HTTPFailure(RuntimeError):
    def __init__(self, status: int, url: str):
        super().__init__(f"HTTP {status} for {url}")
        self.status = status


def mode() -> str:
    return os.environ.get("B3_HTTP", "replay")


def _key(method: str, url: str, body: bytes | None) -> str:
    h = hashlib.sha256()
    h.update(method.encode())
    h.update(b"\n")
    h.update(url.encode())
    h.update(b"\n")
    h.update(body or b"")
    return h.hexdigest()[:24]


# Per-host minimum spacing between live requests. Apple's search API answers
# 403 with an empty body when called more than ~20 times a minute.
_SPACING = {"itunes.apple.com": 3.2}
_last: dict[str, float] = {}


def _throttle(url: str) -> None:
    host = urllib.parse.urlsplit(url).hostname or ""
    gap = _SPACING.get(host, 0.3)
    wait = _last.get(host, 0) + gap - time.monotonic()
    if wait > 0:
        time.sleep(wait)
    _last[host] = time.monotonic()


def fetch(url: str, *, method: str = "GET", body: bytes | None = None,
          headers: dict[str, str] | None = None,
          trim=None) -> bytes:
    """Return the response body for url.

    trim, when given, maps the raw body to the bytes that are stored. It is
    used only to drop parts of very large responses the matcher never reads.
    """
    key = _key(method, url, body)
    path = FIXTURES / f"{key}.json.gz"
    m = mode()
    if m != "refresh" and path.exists():
        with gzip.open(path, "rt", encoding="utf-8") as f:
            record = json.load(f)
        if record["status"] != 200:
            raise HTTPFailure(record["status"], url)
        return record["body"].encode("utf-8")
    if m == "replay":
        raise MissingFixture(f"no recorded response for {method} {url}")

    data, status = _live(url, method, body, headers)
    text = data.decode("utf-8", errors="replace")
    if status == 200 and trim is not None:
        text = trim(text)
    FIXTURES.mkdir(parents=True, exist_ok=True)
    record = {"method": method, "url": url,
              "body_sent": body.decode() if body else None,
              "status": status, "recorded_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
              "body": text}
    with gzip.open(path, "wt", encoding="utf-8") as f:
        json.dump(record, f, ensure_ascii=False)
    if status != 200:
        raise HTTPFailure(status, url)
    return text.encode("utf-8")


def _live(url, method, body, headers):
    attempts = 0
    while True:
        attempts += 1
        _throttle(url)
        req = urllib.request.Request(url, data=body, method=method)
        req.add_header("User-Agent", USER_AGENT)
        req.add_header("Accept-Language", "en-US,en;q=0.9")
        for k, v in (headers or {}).items():
            req.add_header(k, v)
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                return resp.read(), resp.status
        except urllib.error.HTTPError as e:
            # Apple's throttle: back off and retry rather than record a 403.
            if e.code in (403, 429) and "itunes.apple.com" in url and attempts < 6:
                time.sleep(15 * attempts)
                continue
            if e.code in (404, 400, 410):
                return e.read() or b"", e.code
            raise
        except urllib.error.URLError:
            if attempts < 4:
                time.sleep(2 ** attempts)
                continue
            raise

