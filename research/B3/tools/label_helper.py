"""Show the feed items a human labeler should consider for each test video.

Labels are decided by reading the podcast's own RSS feed, not Apple's search
results, so the labels don't inherit the matcher's candidate source.

    B3_HTTP=record B3_FIXTURES=../../artifacts/b3/label-cache \
        python3 tools/label_helper.py VIDEO_ID FEED_URL [VIDEO_ID FEED_URL ...]

Prints the video's evidence and the feed items published within ten days of
it, plus the best title overlaps from the whole feed.
"""
from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
sys.path.insert(0, str(Path(__file__).resolve().parent))

from feed import items  # noqa: E402
from b3 import youtube  # noqa: E402
from b3.match import days_apart  # noqa: E402
from b3.text import title_similarity  # noqa: E402


def evidence(vid: str):
    """Video evidence always comes from the matcher's own recordings."""
    from b3 import http
    label_cache = http.FIXTURES
    http.FIXTURES = Path(__file__).resolve().parent.parent / "fixtures" / "http"
    try:
        return youtube.evidence(vid)
    finally:
        http.FIXTURES = label_cache


def show(vid: str, feed_url: str) -> None:
    ev = evidence(vid)
    print(f"\n### {vid}  {ev.published}  {ev.duration_s}s  [{ev.channel}]  {ev.title}")
    feed = items(feed_url)
    near = [it for it in feed if (days_apart(it["published"], ev.published) or 99) <= 10]
    best = sorted(feed, key=lambda it: -title_similarity(ev.title, it["title"]))[:4]
    seen = set()
    for it in near + best:
        key = it["guid"] or it["title"]
        if key in seen:
            continue
        seen.add(key)
        d = days_apart(it["published"], ev.published)
        print(f"   {it['published']} ({d}d) {it['duration_s']}s  sim={title_similarity(ev.title, it['title']):.2f}"
              f"  {it['title'][:90]}\n      guid={it['guid']}")


if __name__ == "__main__":
    args = sys.argv[1:]
    for vid, url in zip(args[::2], args[1::2]):
        try:
            show(vid, url)
        except Exception as e:  # keep going through a batch
            print(f"\n### {vid} ERROR {e}")
