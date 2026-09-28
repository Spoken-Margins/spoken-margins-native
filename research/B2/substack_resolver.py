"""Substack link -> publication feed. A prototype of the I1 resolver M1 should port to Swift.

Input: any link a listener might have for a Substack (post, home page, custom
domain, share links from the Substack app, profile, /feed). Output: zero or one
SourceCandidate. Zero means "not a Substack": generic discovery keeps handling
the link, so this resolver never changes what happens to other sites.

Why it does not need the post to be in the feed: a /p/<slug> page served by
Substack from origin X belongs to the publication whose feed is X/feed. That
is the evidence, so old posts (outside the 20-item feed) and links carrying
?utm_/?r= resolve the same way as a clean, recent link.

Requests:
  * post, home, archive or /feed link on a custom domain or <name>.substack.com,
    and open.substack.com/pub/<name>/... share links: one GET of <origin>/feed,
    which must be served by Substack (response headers or <generator>).
  * substack.com/home/post/p-ID, /@handle/p-ID, /inbox/post/ID, /app-link/post:
    one GET of the link (Substack redirects it to the post on its publication),
    then <origin>/feed.
  * substack.com/@handle profile: the profile page (primary publication), then
    <origin>/feed.
No page body is size-capped here because only /feed and substack.com pages are
read; the Swift port should still bound them (feed: FeedParser's 16 MB).
"""

from __future__ import annotations

import re
import urllib.parse
from dataclasses import dataclass, field
from typing import Optional

from current_app import parse_feed
from fetcher import Fetcher, RedirectRefused

# Hosts on substack.com that are Substack's own app, not a publication.
PLATFORM_HOSTS = {"substack.com", "www.substack.com", "open.substack.com", "api.substack.com",
                  "support.substack.com", "cdn.substack.com", "substackcdn.com"}
TRACKING_KEYS = re.compile(r"^(utm_[a-z_]+|r|ref|s|triedRedirect|showWelcomeOnShare|publication_id|post_id|"
                           r"isFreemail|token|sd|next|action|open|source|img|share)$", re.I)
PRIVATE_FEED = [
    # Paid podcast feed a subscriber copies from their subscription page (official feature).
    re.compile(r"^https://api\.substack\.com/feed/podcast/\d+/private/[^/]+\.rss$", re.I),
    # Path used by third-party guides for a per-subscriber text feed. Not confirmed to exist;
    # treated as private anyway because it would carry a token.
    re.compile(r"^https://[^/]+/feed/private/[^/]+$", re.I),
]
# Public podcast feed of a publication (what <origin>/feed/podcast redirects to).
PUBLIC_PODCAST_FEED = re.compile(r"^https://api\.substack\.com/feed/podcast/\d+\.rss$", re.I)
PAYWALL_MARKER = re.compile(r'data-component-name="Paywall"|data-testid="paywall"', re.I)


@dataclass
class SourceCandidate:
    """I1 source candidate (interfaces.md). `private` feeds must never leave the device (#168)."""
    kind: str
    feed_url: str
    publication_url: str
    title: Optional[str]
    confidence: float
    reason: str
    private: bool = False
    audio_items: int = 0
    evidence: list = field(default_factory=list)


def is_private_feed_url(url: str) -> bool:
    return any(p.match(url.strip()) for p in PRIVATE_FEED)


def redact(url: str) -> str:
    """Show a private feed link without its token (for logs, reasons, diagnostics)."""
    return re.sub(r"/private/[^/]+", "/private/…", url)


def strip_tracking(url: str) -> str:
    parts = urllib.parse.urlsplit(url)
    query = [(k, v) for k, v in urllib.parse.parse_qsl(parts.query, keep_blank_values=True)
             if not TRACKING_KEYS.match(k)]
    return urllib.parse.urlunsplit((parts.scheme, parts.netloc, parts.path, urllib.parse.urlencode(query), ""))


def page_is_paywalled(html: str) -> bool:
    """True when a captured Substack page shows the paywall instead of the rest of the post."""
    return bool(PAYWALL_MARKER.search(html))


def _origin(url: str) -> str:
    parts = urllib.parse.urlsplit(url)
    return f"https://{parts.hostname.lower()}"


def _served_by_substack(response) -> bool:
    if (response.header("x-served-by") or "").lower() == "substack" or response.header("x-sub"):
        return True
    # Headers can be stripped by a proxy in front of a custom domain; fall back to page markers.
    body = response.body
    return "substackcdn.com" in body and bool(re.search(r"<link[^>]*alternate[^>]*href=\"/feed\"", body))


def _feed_from_substack(response) -> bool:
    if (response.header("x-served-by") or "").lower() == "substack" or response.header("x-sub"):
        return True
    return "<generator>Substack</generator>" in response.body[:4096]


class SubstackResolver:
    def __init__(self, fetcher: Fetcher):
        self.fetcher = fetcher

    def resolve(self, link: str) -> Optional[SourceCandidate]:
        raw = link.strip()
        parts = urllib.parse.urlsplit(raw)
        if parts.scheme.lower() not in ("http", "https") or not parts.hostname:
            return None
        if is_private_feed_url(raw):
            return self._feed_link(raw, private=True)
        if PUBLIC_PODCAST_FEED.match(raw):
            return self._feed_link(raw, private=False)
        host = parts.hostname.lower()
        # Substack serves everything over https; an http link is upgraded, never fetched as http.
        https_url = urllib.parse.urlunsplit(("https", parts.netloc.lower(), parts.path, parts.query, ""))
        path = parts.path
        evidence = [f"input {redact(strip_tracking(raw))}"]

        # Shapes that name the publication without a request.
        m = re.match(r"^/pub/([a-z0-9-]+)(?:/|$)", path, re.I)
        if host == "open.substack.com" and m:
            evidence.append(f"open.substack.com share link names publication '{m.group(1)}'")
            return self._confirm(f"https://{m.group(1).lower()}.substack.com", evidence, 0.95)

        m = re.match(r"^/@([A-Za-z0-9_.-]+)/?$", path)
        if host in ("substack.com", "www.substack.com") and m:
            return self._profile(m.group(1), evidence)

        if host not in PLATFORM_HOSTS:
            # <name>.substack.com, a custom domain, or any other site. Ask its /feed directly: no page
            # download (some Substack home pages are over 2 MB), and the feed says whether Substack serves it.
            if host.endswith(".substack.com"):
                evidence.append(f"Substack subdomain '{host.split('.')[0]}'")
            found = self._confirm(_origin(https_url), evidence, 0.95, require_substack=True)
            if found:
                return found
            # The origin has no feed of its own: a redirector (apex -> www), or a subdomain whose
            # publication moved (redirects to a substack.com profile). Follow the link itself once.

        # substack.com post links (home/post/p-ID, @handle/p-ID, inbox/post/ID, app-link) and the
        # fallbacks above: Substack redirects to the post or publication; the final URL names it.
        # The query is kept here because app-link needs publication_id/post_id to redirect.
        try:
            response = self.fetcher.get(https_url, "html")
        except RedirectRefused:
            return None
        if response.status != 200 or not _served_by_substack(response):
            return None
        final = urllib.parse.urlsplit(response.url)
        m = re.match(r"^/@([A-Za-z0-9_.-]+)/?$", final.path)
        if final.hostname in ("substack.com", "www.substack.com") and m:
            evidence.append(f"redirected to profile @{m.group(1)}")
            return self._profile(m.group(1), evidence)
        if final.hostname in PLATFORM_HOSTS or final.hostname == host:
            return None  # a Substack app page that isn't a publication (notes, 404, sign-in), or no progress
        evidence.append(f"redirected to {strip_tracking(response.url)}")
        return self._confirm(_origin(response.url), evidence, 0.95, require_substack=True)

    def _profile(self, handle: str, evidence: list) -> Optional[SourceCandidate]:
        response = self.fetcher.get(f"https://substack.com/@{handle}", "html")
        if response.status != 200:
            return None
        m = re.search(r'primaryPublication\\":\{\\"id\\":\d+,\\"subdomain\\":\\"([a-z0-9-]+)\\"', response.body)
        if not m:
            return None
        subdomain = m.group(1)
        window = response.body[m.end(): m.end() + 400]
        custom_match = re.search(r'\\"custom_domain\\":\\"([^\\"]+)\\"', window)
        custom = custom_match.group(1) if custom_match else None
        origin = f"https://{custom}" if custom else f"https://{subdomain}.substack.com"
        evidence.append(f"profile @{handle}: primary publication '{subdomain}'")
        # A writer can run several publications; the profile only names the primary one.
        return self._confirm(origin, evidence, 0.8)

    def _confirm(self, origin: str, evidence: list, confidence: float,
                 require_substack: bool = False) -> Optional[SourceCandidate]:
        feed = f"{origin}/feed"
        try:
            response = self.fetcher.get(feed, "feed")
        except RedirectRefused:
            return None
        if response.status != 200:
            return None
        if require_substack and not _feed_from_substack(response):
            return None
        try:
            parsed = parse_feed(response.body)
        except ValueError:
            return None
        final_feed = strip_tracking(response.url)
        evidence.append(f"feed {final_feed} parsed ({len(parsed.item_urls)} items)")
        return SourceCandidate(
            kind="substack",
            feed_url=final_feed,
            publication_url=_origin(final_feed),
            title=parsed.title,
            confidence=confidence,
            reason="; ".join(evidence),
            audio_items=parsed.audio_items,
            evidence=evidence,
        )

    def _feed_link(self, url: str, private: bool) -> Optional[SourceCandidate]:
        """A Substack podcast feed link pasted as is: public, or a subscriber's private one."""
        response = self.fetcher.get(url, "feed")
        label = "private feed link" if private else "podcast feed link"
        evidence = [f"{label} {redact(url)}"]
        if response.status != 200:
            return None
        try:
            parsed = parse_feed(response.body)
        except ValueError:
            return None
        evidence.append(f"parsed ({len(parsed.item_urls)} items, {parsed.audio_items} with audio)")
        return SourceCandidate(
            kind="substack_private_feed" if private else "substack_podcast_feed",
            feed_url=url,
            publication_url="",
            title=parsed.title,
            confidence=1.0,
            reason="; ".join(evidence),
            private=private,
            audio_items=parsed.audio_items,
            evidence=evidence,
        )
