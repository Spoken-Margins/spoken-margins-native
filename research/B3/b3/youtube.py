"""YouTube evidence: what a pasted link tells us before any podcast lookup.

oEmbed gives the title and channel name with no key. The watch page carries
publish date, description and duration, but from this cloud network both the
watch page and the player endpoint answer "sign in to confirm you're not a
bot". The harness therefore reads the same fields from two unblocked
endpoints the watch page itself uses: `next` (date, description, channel)
and `search` for the video id (duration). The app can read the watch page.
"""
from __future__ import annotations

import json
import re
import urllib.parse
from dataclasses import dataclass, field

from . import http

_ID = re.compile(r"^[A-Za-z0-9_-]{11}$")


def video_id(link: str) -> str | None:
    """Extract the 11-character video id from any common YouTube link form."""
    link = link.strip()
    if _ID.match(link):
        return link
    parts = urllib.parse.urlsplit(link if "://" in link else "https://" + link)
    host = (parts.hostname or "").lower()
    if host.startswith("www.") or host.startswith("m."):
        host = host.split(".", 1)[1]
    path = parts.path
    if host == "youtu.be":
        vid = path.strip("/").split("/")[0]
    elif host in ("youtube.com", "music.youtube.com", "youtube-nocookie.com"):
        q = urllib.parse.parse_qs(parts.query)
        if "v" in q:
            vid = q["v"][0]
        else:
            m = re.match(r"^/(?:shorts|live|embed|v|e)/([^/?#]+)", path)
            vid = m.group(1) if m else ""
    else:
        return None
    return vid if _ID.match(vid or "") else None


@dataclass
class VideoEvidence:
    video_id: str
    title: str
    channel: str
    channel_id: str | None = None
    published: str | None = None      # ISO date, YYYY-MM-DD
    duration_s: int | None = None
    description: str = ""
    links: list[str] = field(default_factory=list)
    is_short: bool = False
    is_live: bool = False


_MONTHS = {m: i for i, m in enumerate(
    ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"], 1)}


def _walk(o):
    if isinstance(o, dict):
        yield o
        for v in o.values():
            yield from _walk(v)
    elif isinstance(o, list):
        for v in o:
            yield from _walk(v)


def _text(v) -> str | None:
    if not isinstance(v, dict):
        return None
    if "simpleText" in v:
        return v["simpleText"]
    if "content" in v:
        return v["content"]
    if "runs" in v:
        return "".join(r.get("text", "") for r in v["runs"])
    return None


def _iso_date(text: str | None) -> str | None:
    """'Aug 12, 2026' or 'Premiered Aug 12, 2026' or 'Streamed live on ...' -> 2026-08-12."""
    if not text:
        return None
    m = re.search(r"([A-Z][a-z]{2})[a-z]*\.? (\d{1,2}), (\d{4})", text)
    if not m or m.group(1).lower() not in _MONTHS:
        return None
    return f"{int(m.group(3)):04d}-{_MONTHS[m.group(1).lower()]:02d}-{int(m.group(2)):02d}"


def _seconds(text: str | None) -> int | None:
    if not text or not re.fullmatch(r"\d+(:\d{1,2}){0,2}", text):
        return None
    total = 0
    for part in text.split(":"):
        total = total * 60 + int(part)
    return total


_CLIENT = {"client": {"clientName": "WEB", "clientVersion": "2.20250101.00.00", "hl": "en", "gl": "US"}}


def _innertube(endpoint: str, payload: dict, trim) -> dict | None:
    body = json.dumps({**payload, "context": _CLIENT}, sort_keys=True).encode()
    try:
        raw = http.fetch(f"https://www.youtube.com/youtubei/v1/{endpoint}?prettyPrint=false",
                         method="POST", body=body,
                         headers={"Content-Type": "application/json"}, trim=trim)
    except http.HTTPFailure:
        return None
    return json.loads(raw)


def _trim_next(text: str) -> str:
    """Keep the watch page's primary and secondary info: date, description, channel."""
    d = json.loads(text)
    out = {}
    for o in _walk(d):
        if "videoPrimaryInfoRenderer" in o and "primary" not in out:
            p = o["videoPrimaryInfoRenderer"]
            out["primary"] = {"title": _text(p.get("title")), "dateText": _text(p.get("dateText"))}
        if "videoSecondaryInfoRenderer" in o and "secondary" not in out:
            s = o["videoSecondaryInfoRenderer"]
            owner = s.get("owner", {}).get("videoOwnerRenderer", {})
            desc = s.get("attributedDescription") or {}
            out["secondary"] = {
                "description": _text(desc) or _text(s.get("description")) or "",
                # Link text in descriptions is shortened ("open.spotify.com/show/01A0..."),
                # so keep the real targets of the description's links.
                "links": _description_links(desc),
                "channel": _text(owner.get("title")),
                "channelId": owner.get("navigationEndpoint", {}).get("browseEndpoint", {}).get("browseId"),
            }
        if "videoDescriptionHeaderRenderer" in o and "publishDate" not in out:
            out["publishDate"] = _text(o["videoDescriptionHeaderRenderer"].get("publishDate"))
    return json.dumps(out, ensure_ascii=False)


def _description_links(desc: dict) -> list[str]:
    links = []
    for run in desc.get("commandRuns", []):
        url = (run.get("onTap", {}).get("innertubeCommand", {})
               .get("urlEndpoint", {}).get("url"))
        if not url:
            continue
        q = urllib.parse.parse_qs(urllib.parse.urlsplit(url).query).get("q")
        links.append(q[0] if q else url)
    return list(dict.fromkeys(links))


def _trim_search(text: str) -> str:
    """Keep only video results (id, title, length, channel)."""
    d = json.loads(text)
    vids = []
    for o in _walk(d):
        if "videoRenderer" in o:
            v = o["videoRenderer"]
            vids.append({"videoId": v.get("videoId"), "title": _text(v.get("title")),
                         "lengthText": _text(v.get("lengthText")),
                         "channel": _text(v.get("ownerText"))})
    return json.dumps({"videos": vids}, ensure_ascii=False)


def oembed(vid: str) -> dict | None:
    url = ("https://www.youtube.com/oembed?format=json&url="
           + urllib.parse.quote(f"https://www.youtube.com/watch?v={vid}", safe=""))
    try:
        return json.loads(http.fetch(url))
    except http.HTTPFailure:
        return None


def watch_info(vid: str) -> dict:
    return _innertube("next", {"videoId": vid}, _trim_next) or {}


def duration_s(vid: str) -> int | None:
    """Length of the video, read from a search for its id (the player endpoint is bot-blocked here)."""
    res = _innertube("search", {"query": vid}, _trim_search) or {}
    for v in res.get("videos", []):
        if v.get("videoId") == vid:
            return _seconds(v.get("lengthText"))
    return None


def evidence(link: str) -> VideoEvidence | None:
    vid = video_id(link)
    if not vid:
        return None
    oe = oembed(vid) or {}
    info = watch_info(vid)
    primary, secondary = info.get("primary", {}), info.get("secondary", {})
    title = oe.get("title") or primary.get("title")
    if not title:
        return None
    date_text = info.get("publishDate") or primary.get("dateText")
    return VideoEvidence(
        video_id=vid,
        title=title,
        channel=oe.get("author_name") or secondary.get("channel") or "",
        channel_id=secondary.get("channelId"),
        published=_iso_date(date_text),
        duration_s=duration_s(vid),
        description=secondary.get("description") or "",
        links=secondary.get("links") or [],
        is_short="/shorts/" in link,
        is_live=bool(date_text and ("Streamed" in date_text or "live" in date_text.lower())),
    )
