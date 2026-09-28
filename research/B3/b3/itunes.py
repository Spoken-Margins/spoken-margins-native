"""Apple's public iTunes Search and Lookup APIs: the candidate source.

Same endpoints the app's Spotify resolver uses (PublicPodcastLinkResolver).
"""
from __future__ import annotations

import json
import urllib.parse

from . import http

BASE = "https://itunes.apple.com"


def _get(path: str, params: dict) -> list[dict]:
    url = f"{BASE}/{path}?" + urllib.parse.urlencode(params)
    try:
        return json.loads(http.fetch(url)).get("results", [])
    except (http.HTTPFailure, ValueError):
        return []


def search_shows(term: str, limit: int = 10) -> list[dict]:
    return _get("search", {"term": term, "country": "US", "media": "podcast",
                           "entity": "podcast", "limit": limit})


def search_episodes(term: str, limit: int = 25) -> list[dict]:
    return _get("search", {"term": term, "country": "US", "media": "podcast",
                           "entity": "podcastEpisode", "limit": limit})


def lookup_show(collection_id: int) -> dict | None:
    for r in _get("lookup", {"id": collection_id, "country": "US"}):
        if r.get("wrapperType") == "track" and r.get("kind") == "podcast":
            return r
    return None


def show_episodes(collection_id: int, limit: int = 200) -> list[dict]:
    """The show's most recent episodes (Apple caps this at 200)."""
    return [r for r in _get("lookup", {"id": collection_id, "country": "US",
                                       "entity": "podcastEpisode", "limit": limit})
            if r.get("wrapperType") == "podcastEpisode"]
