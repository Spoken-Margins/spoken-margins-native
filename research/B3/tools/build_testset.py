"""Build testset.json from the hand-written labels.tsv.

For each labeled episode, the feed item's title, date, length and enclosure
are copied from the podcast's own RSS feed so the scorer can compare them.

    B3_HTTP=record B3_FIXTURES=../../artifacts/b3/label-cache python3 tools/build_testset.py
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from feed import items  # noqa: E402

ROOT = HERE.parent


def main() -> None:
    cases = []
    for line in (ROOT / "labels.tsv").read_text().splitlines():
        if not line.strip() or line.startswith("#"):
            continue
        vid, category, show, feed_url, guid, note = line.split("\t")
        case = {"id": vid, "url": f"https://www.youtube.com/watch?v={vid}",
                "category": category, "show": None if show == "-" else show,
                "feed_url": None if feed_url == "-" else feed_url,
                "expected": None, "note": note}
        if guid != "-":
            match = [it for it in items(feed_url) if it["guid"] == guid]
            if len(match) != 1:
                raise SystemExit(f"{vid}: guid {guid} found {len(match)} times in {feed_url}")
            it = match[0]
            case["expected"] = {k: it[k] for k in ("guid", "title", "published", "duration_s", "audio_url")}
        cases.append(case)
    out = {"about": "YouTube podcast links labeled with the same episode in the show's own feed, or none. "
                    "See README.md for categories and how labels were decided.",
           "labeled_on": "2026-09-28", "cases": cases}
    (ROOT / "testset.json").write_text(json.dumps(out, indent=1, ensure_ascii=False) + "\n")
    by = {}
    for c in cases:
        by[c["category"]] = by.get(c["category"], 0) + 1
    print(len(cases), "cases", by)


if __name__ == "__main__":
    main()
