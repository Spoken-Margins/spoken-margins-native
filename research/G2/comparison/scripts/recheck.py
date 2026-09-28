#!/usr/bin/env python3
"""Fetch every cited page and report sources whose quote no longer appears.

Usage: python3 research/G2/comparison/scripts/recheck.py [app-id ...] > recheck.txt

This only tells a person where to look. A missing quote can mean the product
changed, the page moved, or the page renders with JavaScript. A person reads the
page, then edits apps/<id>.json (value, detail, quote, checked) by hand.
Sources inside this repository are checked offline by validate.py instead.
"""
import html
import json
import pathlib
import re
import sys
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parents[1]
# Script bodies are kept: many sites ship their text only in a JSON payload for JavaScript to render.
TAG = re.compile(r"<[^>]+>")


def normalise(text: str) -> str:
    # Compare letters and digits only: inline links and curly quotes change spacing and punctuation.
    return re.sub(r"[^0-9a-z]+", "", html.unescape(TAG.sub(" ", text)).lower())


def fetch(url: str) -> str:
    req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0 (spoken-margins G2 source recheck)"})
    with urllib.request.urlopen(req, timeout=20) as resp:
        return resp.read().decode("utf-8", "replace")


def main() -> int:
    wanted = set(sys.argv[1:])
    pages: dict[str, str | Exception] = {}
    rows = []
    for path in sorted((ROOT / "apps").glob("*.json")):
        app = json.loads(path.read_text())
        if wanted and app["id"] not in wanted:
            continue
        for field, claim in app["claims"].items():
            for src in claim["sources"]:
                url, quote = src["url"], src.get("quote", "")
                if "github.com/uncomposed/spoken-margins-native" in url or not quote:
                    continue
                if url not in pages:
                    try:
                        pages[url] = normalise(fetch(url))
                    except Exception as exc:  # noqa: BLE001 - report every failure kind
                        pages[url] = exc
                page = pages[url]
                if isinstance(page, Exception):
                    rows.append(("FETCH-FAILED", app["id"], field, src["checked"], url, str(page)[:80]))
                elif normalise(quote) not in page:
                    rows.append(("QUOTE-GONE", app["id"], field, src["checked"], url, quote[:80]))
    for row in rows:
        print(" | ".join(row))
    print(f"{len(pages)} pages, {len(rows)} sources need a person to look", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
