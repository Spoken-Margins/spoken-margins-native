"""Spotify show links in a YouTube description name the podcast outright."""
from __future__ import annotations

import json
import re
import urllib.parse

from . import http

SHOW_LINK = re.compile(r"open\.spotify\.com/(?:intl-[a-z]+/)?show/([A-Za-z0-9]{22})")


def show_name(show_id: str) -> str | None:
    url = "https://open.spotify.com/oembed?url=" + urllib.parse.quote(
        f"https://open.spotify.com/show/{show_id}", safe="")
    try:
        return json.loads(http.fetch(url)).get("title") or None
    except (http.HTTPFailure, ValueError):
        return None
