"""Read a podcast RSS feed into plain dicts (labeling only; not the matcher)."""
from __future__ import annotations

import email.utils
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from b3 import http  # noqa: E402

ITUNES = "{http://www.itunes.com/dtds/podcast-1.0.dtd}"


def _dur(text: str | None) -> int | None:
    if not text:
        return None
    text = text.strip()
    try:
        parts = [int(float(p)) for p in text.split(":")]
    except ValueError:
        return None
    total = 0
    for p in parts:
        total = total * 60 + p
    return total


def items(feed_url: str) -> list[dict]:
    root = ET.fromstring(http.fetch(feed_url))
    out = []
    for it in root.iter("item"):
        pub = it.findtext("pubDate")
        try:
            date = email.utils.parsedate_to_datetime(pub).date().isoformat() if pub else None
        except (TypeError, ValueError):
            date = None
        enc = it.find("enclosure")
        out.append({
            "guid": (it.findtext("guid") or "").strip() or None,
            "title": (it.findtext("title") or "").strip(),
            "published": date,
            "duration_s": _dur(it.findtext(f"{ITUNES}duration")),
            "audio_url": enc.get("url") if enc is not None else None,
            "link": (it.findtext("link") or "").strip() or None,
            "description": (it.findtext("description") or "").strip(),
        })
    return out
