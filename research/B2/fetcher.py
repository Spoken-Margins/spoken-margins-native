"""HTTP fetching with record/replay, shaped like the app's URLSession use.

Modes:
  replay  (default)  every response comes from fixtures/; a miss is an error.
  record             fetch live, store each hop in fixtures/, return it.

Each request hop (one URL, one Accept kind) is one fixture file. Redirects are
followed by the caller of `get`, hop by hop, the way URLSession's
BoundedRedirectDelegate does: at most 5 redirects, https only.

Bodies are trimmed before they are stored so the fixtures stay small:
  * HTML keeps everything up to </head> (feed <link rel=alternate>, canonical,
    og tags) plus short windows around the markers the resolver reads
    (Substack paywall element, profile primaryPublication JSON).
  * Feeds drop <description> and <content:encoded>, keeping titles, links,
    guids, dates and enclosures.
`original_bytes` keeps the untrimmed size, which is what the app's 1 MB HTML
and 16 MB feed caps compare against.
"""

from __future__ import annotations

import gzip
import hashlib
import json
import os
import re
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional

FIXTURES = Path(__file__).resolve().parent / "fixtures"

# The app's ephemeral URLSession sends CFNetwork's default User-Agent.
USER_AGENT = "SpokenMargins/29 CFNetwork/3826.500.62 Darwin/25.0.0"
ACCEPT = {
    # FollowedSourceCoordinator.fetch
    "feed": "application/rss+xml, application/atom+xml, application/feed+json, application/json, application/xml, text/xml",
    # FollowedSourceCoordinator.fetchHTML
    "html": "text/html, application/xhtml+xml",
}
KEPT_HEADERS = ("content-type", "location", "x-served-by", "x-sub", "content-length")
MAX_REDIRECTS = 5


@dataclass
class Hop:
    url: str
    kind: str
    status: int
    headers: dict
    body: str
    original_bytes: int
    trimmed: bool = False

    def header(self, name: str) -> Optional[str]:
        return self.headers.get(name.lower())


@dataclass
class Response:
    """Final response after redirects, as URLSession would hand it back."""
    requested_url: str
    url: str  # final URL (HTTPURLResponse.url)
    status: int
    headers: dict
    body: str
    original_bytes: int
    hops: list = field(default_factory=list)

    def header(self, name: str) -> Optional[str]:
        return self.headers.get(name.lower())


class FixtureMiss(LookupError):
    pass


class RedirectRefused(Exception):
    """URLSession delegate returned nil: the task fails with no response."""


def fixture_path(url: str, kind: str) -> Path:
    digest = hashlib.sha256(f"{kind} {url}".encode()).hexdigest()[:16]
    return FIXTURES / f"{digest}.json"


def trim_html(text: str) -> tuple[str, bool]:
    end = text.lower().find("</head>")
    if end < 0:
        return text[:65536], len(text) > 65536
    kept = [text[: end + len("</head>")]]
    for marker in ('data-component-name="Paywall"', "primaryPublication\\\":{"):
        at = text.find(marker, end)
        if at >= 0:
            kept.append("<!-- trimmed -->" + text[max(end, at - 200): at + 1500])
    return "\n".join(kept), True


def trim_feed(text: str) -> tuple[str, bool]:
    trimmed = re.sub(r"<content:encoded>.*?</content:encoded>", "", text, flags=re.S)
    trimmed = re.sub(r"(<item>.*?)<description>.*?</description>", r"\1", trimmed, flags=re.S)
    return trimmed, trimmed != text


def trim(body: str, content_type: str) -> tuple[str, bool]:
    ct = (content_type or "").lower()
    if "html" in ct:
        return trim_html(body)
    if "xml" in ct or "rss" in ct or "atom" in ct:
        return trim_feed(body)
    if len(body) > 65536:
        return body[:65536], True
    return body, False


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):  # noqa: D401
        return None


class Fetcher:
    def __init__(self, mode: str | None = None):
        self.mode = mode or os.environ.get("B2_FETCH_MODE", "replay")
        self.requests: list[tuple[str, str]] = []
        self._opener = urllib.request.build_opener(_NoRedirect())

    # One hop, no redirect following.
    def hop(self, url: str, kind: str) -> Hop:
        self.requests.append((kind, url))
        path = fixture_path(url, kind)
        if self.mode == "replay":
            if not path.exists():
                raise FixtureMiss(f"no fixture for {kind} {url} ({path.name})")
            data = json.loads(path.read_text())
            return Hop(**{k: data[k] for k in ("url", "kind", "status", "headers", "body", "original_bytes", "trimmed")})
        if self.mode == "record" and path.exists():
            data = json.loads(path.read_text())
            return Hop(**{k: data[k] for k in ("url", "kind", "status", "headers", "body", "original_bytes", "trimmed")})
        hop = self._live(url, kind)
        if self.mode == "record":
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(json.dumps(hop.__dict__, indent=1, ensure_ascii=False) + "\n")
        return hop

    def _live(self, url: str, kind: str) -> Hop:
        request = urllib.request.Request(url, headers={
            "User-Agent": USER_AGENT,
            "Accept": ACCEPT[kind],
            "Accept-Encoding": "gzip",
        })
        try:
            response = self._opener.open(request, timeout=30)
            status, headers, raw = response.status, response.headers, response.read()
        except urllib.error.HTTPError as error:
            status, headers, raw = error.code, error.headers, error.read()
        if (headers.get("Content-Encoding") or "").lower() == "gzip":
            raw = gzip.decompress(raw)
        kept = {name: headers.get(name) for name in KEPT_HEADERS if headers.get(name) is not None}
        text = raw.decode("utf-8", errors="replace")
        body, trimmed = trim(text, kept.get("content-type", ""))
        return Hop(url=url, kind=kind, status=status, headers=kept, body=body,
                   original_bytes=len(raw), trimmed=trimmed)

    def get(self, url: str, kind: str) -> Response:
        """GET following redirects like the app's URLSession delegate."""
        hops = []
        current = url
        for _ in range(MAX_REDIRECTS + 1):
            hop = self.hop(current, kind)
            hops.append(hop)
            location = hop.header("location")
            if hop.status in (301, 302, 303, 307, 308) and location:
                nxt = urllib.parse.urljoin(current, location)
                if not nxt.lower().startswith("https://"):
                    raise RedirectRefused(f"redirect to non-https {nxt}")
                current = nxt
                continue
            return Response(requested_url=url, url=current, status=hop.status, headers=hop.headers,
                            body=hop.body, original_bytes=hop.original_bytes, hops=hops)
        raise RedirectRefused(f"more than {MAX_REDIRECTS} redirects from {url}")

