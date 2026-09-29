"""Polite, cached HTTP for the C1 corpus tools.

Every response is cached under research/C1/cache/http/ (git-ignored), so a
rerun of any tool makes no network requests for things it already fetched.
Requests to one host are spaced out, and 429/503 responses back off, because
arXiv, bioRxiv and OpenAlex rate-limit aggressively.
"""

from __future__ import annotations

import hashlib
import http.client
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CACHE = ROOT / "cache"
HTTP_CACHE = CACHE / "http"
USER_AGENT = "SpokenMarginsResearch/0.1 (C1 PDF corpus; https://github.com/uncomposed/spoken-margins-native)"

# Minimum seconds between requests to the same host.
HOST_SPACING = {
    "arxiv.org": 3.0,
    "oaipmh.arxiv.org": 3.0,
    "eutils.ncbi.nlm.nih.gov": 0.4,
}
DEFAULT_SPACING = 0.3
RETRY_DELAY = 5.0  # seconds before the first retry; doubles each time
_last_request: dict[str, float] = {}


class FetchError(RuntimeError):
    def __init__(self, url: str, status: int | None, message: str):
        super().__init__(f"{status} {url}: {message}")
        self.url = url
        self.status = status


def _cache_path(url: str) -> Path:
    digest = hashlib.sha256(url.encode()).hexdigest()[:32]
    return HTTP_CACHE / digest[:2] / digest


def _wait_for(host: str) -> None:
    spacing = HOST_SPACING.get(host, DEFAULT_SPACING)
    elapsed = time.monotonic() - _last_request.get(host, 0.0)
    if elapsed < spacing:
        time.sleep(spacing - elapsed)
    _last_request[host] = time.monotonic()


def get(url: str, *, cache: bool = True, attempts: int = 5, timeout: int = 120,
        sha256: str | None = None) -> bytes:
    """Returns the body of a 200 response, raising FetchError otherwise.

    404s are cached as misses too, so probing for optional files (an arXiv
    HTML rendering that doesn't exist) isn't repeated on every run.

    A body shorter than its Content-Length, or one whose SHA-256 doesn't match
    `sha256` when given, is retried and never cached: on the Mac run a
    6 MB arXiv PDF arrived cut off at 5 MB.
    """
    path = _cache_path(url)
    miss = path.with_suffix(".404")
    if cache and path.exists():
        return path.read_bytes()
    if cache and miss.exists():
        raise FetchError(url, 404, "cached miss")
    host = urllib.parse.urlsplit(url).hostname or ""
    delay = RETRY_DELAY
    for attempt in range(attempts):
        _wait_for(host)
        request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT, "Accept": "*/*"})
        try:
            with urllib.request.urlopen(request, timeout=timeout) as response:
                body = response.read()
                expected = response.headers.get("Content-Length")
            problem = None
            if expected and expected.isdigit() and len(body) < int(expected):
                problem = f"truncated: {len(body)} of {expected} bytes"
            elif sha256 and hashlib.sha256(body).hexdigest() != sha256:
                problem = "sha256 differs from the manifest"
            if problem:
                if attempt + 1 < attempts:
                    time.sleep(delay)
                    delay *= 2
                    continue
                raise FetchError(url, None, problem)
        except urllib.error.HTTPError as error:
            # arXiv answers 406 to some clients intermittently; it isn't final.
            if error.code in (406, 429, 500, 502, 503, 504) and attempt + 1 < attempts:
                retry_after = error.headers.get("Retry-After")
                time.sleep(float(retry_after) if retry_after and retry_after.isdigit() else delay)
                delay *= 2
                continue
            if error.code == 404 and cache:
                miss.parent.mkdir(parents=True, exist_ok=True)
                miss.write_text(url)
            raise FetchError(url, error.code, error.reason) from None
        except (urllib.error.URLError, TimeoutError, ConnectionError, http.client.IncompleteRead) as error:
            if attempt + 1 < attempts:
                time.sleep(delay)
                delay *= 2
                continue
            raise FetchError(url, None, str(error)) from None
        if cache:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(body)
        return body
    raise FetchError(url, None, "exhausted retries")
