"""Python emulation of today's (Build 29 / next) Follow checks for article items.

Ported line by line from, so a failure here names the Swift check that fails:
  FollowedSourceCoordinator.swift  discover(urlString:requiringItemMembership:) :54-95
                                    fetch :233-252, fetchHTML :254-263,
                                    alternateFeedURLs :265-285, itemURLKey :97-103
  Gate1AppModel.swift              canManuallyFollowSelectedSource :15667
                                    offerFollowSuggestionIfEligible :15787
                                    discoverFollowCandidates :15865
                                    followSource (Following tab) :15618

Not emulated: the PublicPodcastLinkResolver fallback in discoverFollowCandidates.
It only returns a feed for podcast pages whose feed item links back to the exact
page URL, so it never rescues a text post (and hits the same exact-URL rule for
audio posts).
"""

from __future__ import annotations

import json
import re
import urllib.parse
import xml.etree.ElementTree as ET
from dataclasses import dataclass
from typing import Optional

from fetcher import Fetcher, RedirectRefused

MAX_FEED_BYTES = 16 * 1024 * 1024   # FeedParserLimits.defaultMaximumBytes
MAX_HTML_BYTES = 1 * 1024 * 1024    # fetchHTML
HEURISTIC_PATHS = ["/feed", "/feed.xml", "/rss", "/atom.xml"]


class FollowError(Exception):
    """Mirrors FollowedSourceError; `check` names the Swift line that threw."""

    def __init__(self, code: str, check: str):
        super().__init__(code)
        self.code = code
        self.check = check


@dataclass
class ParsedFeed:
    title: Optional[str]
    feed_url: Optional[str]
    item_urls: list
    audio_items: int


@dataclass
class Candidate:
    feed_url: str
    title: Optional[str]
    relation: str
    confidence: float


def _local(tag: str) -> str:
    return tag.rsplit("}", 1)[-1].split(":")[-1]


def parse_feed(body: str) -> ParsedFeed:
    """Enough of SessionKitFeeds.FeedParser to tell a feed from a page and list item links."""
    stripped = body.lstrip()
    if stripped.startswith("{"):
        data = json.loads(stripped)
        if "jsonfeed.org" not in str(data.get("version", "")):
            raise ValueError("not a JSON Feed")
        items = [i.get("url") for i in data.get("items", []) if i.get("url")]
        return ParsedFeed(data.get("title"), data.get("feed_url"), items, 0)
    try:
        root = ET.fromstring(body.encode("utf-8"))
    except ET.ParseError as error:
        raise ValueError(f"not XML: {error}") from None
    if _local(root.tag) == "rss":
        channel = next((c for c in root if _local(c.tag) == "channel"), None)
        if channel is None:
            raise ValueError("rss without channel")
        title = next((c.text for c in channel if _local(c.tag) == "title"), None)
        self_link = next((c.get("href") for c in channel
                          if _local(c.tag) == "link" and c.get("rel") == "self"), None)
        urls, audio = [], 0
        for item in (c for c in channel if _local(c.tag) == "item"):
            link = next((c.text for c in item if _local(c.tag) == "link" and c.text), None)
            if link:
                urls.append(link.strip())
            if any(_local(c.tag) == "enclosure" and (c.get("type") or "").startswith("audio") for c in item):
                audio += 1
        return ParsedFeed(title, self_link, urls, audio)
    if _local(root.tag) == "feed":
        title = next((c.text for c in root if _local(c.tag) == "title"), None)
        urls = []
        for entry in (c for c in root if _local(c.tag) == "entry"):
            for link in (c for c in entry if _local(c.tag) == "link"):
                if link.get("rel", "alternate") == "alternate" and link.get("href"):
                    urls.append(link.get("href"))
                    break
        return ParsedFeed(title, None, urls, 0)
    raise ValueError(f"unsupported root <{_local(root.tag)}>")


def item_url_key(raw: Optional[str]) -> Optional[str]:
    """FollowedSourceCoordinator.itemURLKey: drops fragment, lowercases scheme+host, keeps query."""
    if not raw:
        return None
    parts = urllib.parse.urlsplit(raw)
    return urllib.parse.urlunsplit((parts.scheme.lower(), parts.netloc.lower(), parts.path, parts.query, ""))


ALTERNATE_TAG = re.compile(r"<link\b[^>]*\brel\s*=\s*['\"][^'\"]*alternate[^'\"]*['\"][^>]*>", re.I)
ALTERNATE_TYPE = re.compile(r"type\s*=\s*['\"](?:application/(?:rss\+xml|atom\+xml|feed\+json|json)|text/xml)['\"]", re.I)
HREF = re.compile(r"href\s*=\s*['\"]([^'\"]+)['\"]", re.I)


def alternate_feed_urls(html: str, base_url: str) -> list:
    results = []
    for match in list(ALTERNATE_TAG.finditer(html))[:8]:
        tag = match.group(0)
        href = HREF.search(tag)
        if not ALTERNATE_TYPE.search(tag) or not href:
            continue
        url = urllib.parse.urljoin(base_url, href.group(1))
        if url.lower().startswith("https://") and url not in results:
            results.append(url)
    return results


class CurrentApp:
    def __init__(self, fetcher: Fetcher):
        self.fetcher = fetcher

    def fetch_feed(self, url: str) -> ParsedFeed:
        """FollowedSourceCoordinator.fetch :233-252."""
        response = self.fetcher.get(url, "feed")
        if not 200 <= response.status < 300:
            raise FollowError("invalidResponse", "FollowedSourceCoordinator.swift:242 non-2xx feed response")
        if response.original_bytes > MAX_FEED_BYTES:
            raise FollowError("responseTooLarge", "FollowedSourceCoordinator.swift:243 feed over 16 MB")
        try:
            parsed = parse_feed(response.body)
        except ValueError:
            raise FollowError("parse", "FollowedSourceCoordinator.swift:244 FeedParser rejects body") from None
        parsed.feed_url = urllib.parse.urljoin(response.url, parsed.feed_url) if parsed.feed_url else response.url
        return parsed

    def fetch_html(self, url: str) -> str:
        """FollowedSourceCoordinator.fetchHTML :254-263."""
        try:
            response = self.fetcher.get(url, "html")
        except RedirectRefused:
            raise FollowError("urlError", "BoundedRedirectDelegate refuses redirect; fetchHTML throws") from None
        if not 200 <= response.status < 300:
            raise FollowError("invalidResponse", "FollowedSourceCoordinator.swift:258-259 HTML page non-2xx")
        if response.original_bytes > MAX_HTML_BYTES:
            raise FollowError("htmlResponseTooLarge", "FollowedSourceCoordinator.swift:261 HTML over 1 MB; aborts before /feed heuristics")
        return response.body

    def discover(self, url_string: str, requiring_item_membership: bool = False) -> list:
        """FollowedSourceCoordinator.discover :54-95."""
        url = url_string.strip()
        parts = urllib.parse.urlsplit(url)
        if parts.scheme.lower() != "https" or not parts.hostname:
            raise FollowError("insecureURL", "FollowedSourceCoordinator.swift:56 scheme must be https")
        host = parts.hostname.lower()
        try:
            parsed = self.fetch_feed(url)
            return [Candidate(parsed.feed_url, parsed.title, "direct", 1.0)]
        except (FollowError, RedirectRefused):
            pass
        html = self.fetch_html(url)
        evidence = [(u, "html_alternate", 0.95) for u in alternate_feed_urls(html, url)]
        for path in HEURISTIC_PATHS:
            candidate = urllib.parse.urljoin(url, path)
            if urllib.parse.urlsplit(candidate).hostname == host and candidate not in [e[0] for e in evidence]:
                evidence.append((candidate, "same_origin_heuristic", 0.55))
        candidates, seen_contents = [], set()
        membership_rejected = []
        for candidate_url, relation, confidence in evidence[:8]:
            try:
                parsed = self.fetch_feed(candidate_url)
            except (FollowError, RedirectRefused):
                continue
            if requiring_item_membership and item_url_key(url) not in {item_url_key(u) for u in parsed.item_urls}:
                membership_rejected.append(candidate_url)
                continue
            content_key = "\n".join(sorted({item_url_key(u) for u in parsed.item_urls}))
            if parsed.item_urls:
                if content_key in seen_contents:
                    continue
                seen_contents.add(content_key)
            if parsed.feed_url not in [c.feed_url for c in candidates]:
                candidates.append(Candidate(parsed.feed_url, parsed.title, relation, confidence))
        if not candidates:
            if membership_rejected:
                raise FollowError("noFeedCandidates",
                                  "FollowedSourceCoordinator.swift:77-80 item URL not in feed (membership); "
                                  f"feed found at {membership_rejected[0]}")
            raise FollowError("noFeedCandidates",
                              "FollowedSourceCoordinator.swift:93 no alternate link or /feed heuristic on this host parsed")
        return candidates

    # --- Follow entry points for an article ("text") item -------------------

    @staticmethod
    def manual_button(media_type: str = "text") -> tuple[bool, str]:
        ok = media_type.lower() in ("podcast", "transcript_backed_media")
        return ok, "" if ok else "Gate1AppModel.swift:15670 canManuallyFollowSelectedSource requires podcast/transcript media"

    def suggestion(self, external_reference: str) -> dict:
        """offerFollowSuggestionIfEligible for an article item (sourceURL nil), past the 25%/Margin gate."""
        if not external_reference.lower().startswith("https://"):
            return {"ok": False, "check": "Gate1AppModel.swift:15793 reference must be https"}
        try:
            found = self.discover(external_reference, requiring_item_membership=True)
        except FollowError as error:
            return {"ok": False, "check": error.check}
        return {"ok": True, "feeds": [c.feed_url for c in found]}

    def following_tab(self, pasted: str) -> dict:
        """followSource(): the Following tab's 'Paste an RSS feed link' field (membership not required)."""
        try:
            found = self.discover(pasted)
        except FollowError as error:
            return {"ok": False, "check": error.check}
        result = {"ok": True, "feeds": [c.feed_url for c in found]}
        if len(found) > 1:
            result["note"] = "several candidates; user must choose"
        return result
