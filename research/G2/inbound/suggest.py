#!/usr/bin/env python3
"""Snapshot search-autocomplete suggestions for each segment's seed queries.

Usage: python3 research/G2/inbound/suggest.py > research/G2/inbound/suggest-YYYY-MM-DD.json

Autocomplete shows that people search a phrase, not how many do. It's free,
needs no account and can be re-run, so topic choices can be re-checked. Pair it
with Search Console impressions once any page is live (METHOD.md, "Measuring").
"""
import datetime
import json
import sys
import time
import urllib.parse
import urllib.request

SEEDS = {
    "pkm": [
        "podcast notes obsidian", "obsidian podcast", "snipd alternative", "snipd vs",
        "take notes while listening to podcast", "voice notes to obsidian", "readwise reader text to speech",
        "best podcast app for taking notes",
    ],
    "listen_to_read": [
        "speechify alternative", "elevenreader vs", "read pdf aloud iphone", "listen to articles app",
        "text to speech app for adhd", "text to speech for dyslexia", "read it later app with text to speech",
        "pocket alternative text to speech",
    ],
    "students": [
        "text to speech for college students", "listen to readings", "read research papers aloud",
        "read pdf aloud", "perusall alternative", "how to take notes on readings",
    ],
    "creators": [
        "podcast book club", "book club app", "fable app alternative", "listening club", "podcast community app",
        "how to start a book club on substack",
    ],
}
MODIFIERS = ["", " app", " iphone", " free", " reddit", " vs"]


def suggest(query: str) -> list[str]:
    url = "https://suggestqueries.google.com/complete/search?client=firefox&hl=en&gl=us&q=" + urllib.parse.quote(query)
    req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0 (spoken-margins G2 topic research)"})
    with urllib.request.urlopen(req, timeout=15) as resp:
        return json.loads(resp.read().decode("utf-8", "replace"))[1]


def main() -> int:
    out = {"source": "Google autocomplete (client=firefox, hl=en, gl=us)", "date": datetime.date.today().isoformat(), "segments": {}}
    for segment, seeds in SEEDS.items():
        found: dict[str, list[str]] = {}
        for seed in seeds:
            for mod in MODIFIERS:
                q = seed + mod
                try:
                    found[q] = suggest(q)
                except Exception as exc:  # noqa: BLE001 - record and carry on
                    found[q] = [f"ERROR: {exc}"]
                time.sleep(0.3)
        out["segments"][segment] = found
    json.dump(out, sys.stdout, indent=1, ensure_ascii=False)
    print()
    return 0


if __name__ == "__main__":
    sys.exit(main())
