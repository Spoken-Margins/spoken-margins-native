"""Spotify show links in a YouTube description name the podcast outright.

Spotify's oEmbed for a show returns its latest episode's title, not the
show's name, so the name is read from the embed page's entity `subtitle`
(the same field the app's Spotify resolver uses for the show title).
"""
from __future__ import annotations

import json
import re

from . import http

SHOW_LINK = re.compile(r"open\.spotify\.com/(?:intl-[a-z]+/)?show/([A-Za-z0-9]{22})")
_NEXT_DATA = re.compile(r'<script id="__NEXT_DATA__" type="application/json">(.*?)</script>', re.S)


def _entity(html: str) -> dict:
    m = _NEXT_DATA.search(html)
    if not m:
        return {}
    try:
        return (json.loads(m.group(1))["props"]["pageProps"]["state"]["data"]["entity"]) or {}
    except (ValueError, KeyError, TypeError):
        return {}


def _trim(html: str) -> str:
    e = _entity(html)
    return json.dumps({k: e.get(k) for k in ("type", "name", "title", "subtitle")}, ensure_ascii=False)


def show_name(show_id: str) -> str | None:
    try:
        raw = http.fetch(f"https://open.spotify.com/embed/show/{show_id}", trim=_trim)
        entity = json.loads(raw)
    except (http.HTTPFailure, ValueError):
        return None
    # The embed shows the latest episode; its subtitle is the show.
    if entity.get("type") == "episode":
        return entity.get("subtitle") or None
    return entity.get("name") or entity.get("title") or None
