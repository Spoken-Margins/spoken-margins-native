#!/usr/bin/env python3
"""Generate a deterministic, intentionally opinionated synthetic I4 log."""
import argparse
import json
import random
from datetime import datetime, timedelta, timezone

SCHEMA = "i4-engagement.draft-1"
KINDS = [("podcast_feed", "podcast"), ("article_feed", "article"),
         ("article_feed", "newsletter"), ("website", "paper"), ("website", "news")]
CATEGORIES = ["technology", "science", "culture", "business", "history", "design"]


def stamp(value):
    return value.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")


def generate(seed=176, source_count=60, weeks=7):
    rng = random.Random(seed)
    start = datetime(2026, 7, 6, 8, tzinfo=timezone.utc)
    rows = []
    items = []
    for index in range(source_count):
        subscription, content = KINDS[index % len(KINDS)]
        source = {"id": "src-%02d" % index, "title": "Synthetic %s %02d" % (content.title(), index),
                  "subscription_kind": subscription, "content_kind": content,
                  "categories": [CATEGORIES[index % len(CATEGORIES)]]}
        tier = "love" if index < 10 else "dismiss" if index >= 50 else "ignore"
        cadence = 2 if content in {"news", "podcast"} else 4
        for day_offset in range(index % cadence, weeks * 7, cadence):
            published = start + timedelta(days=day_offset, hours=rng.randrange(0, 8))
            duration = rng.randrange(600, 3601)
            item = {"id": "%s-item-%03d" % (source["id"], day_offset),
                    "title": "Episode %03d from %s" % (day_offset, source["title"]),
                    "published_at": stamp(published), "duration_seconds": duration}
            base = {"schema_version": SCHEMA, "source": source, "item": item}
            rows.append(dict(base, event="item_published", at=stamp(published)))
            items.append((tier, published, duration, base))
    for tier, published, duration, base in items:
        chance = {"love": .72, "ignore": .055, "dismiss": .38}[tier]
        if rng.random() >= chance:
            continue
        delay = rng.choice([0, 1, 1, 2, 4, 8]) if tier == "love" else rng.randrange(0, 5)
        acted = published + timedelta(days=delay, hours=rng.randrange(1, 12))
        if tier == "dismiss":
            rows.append(dict(base, event="dismiss", at=stamp(acted)))
            continue
        # Same-day clusters create realistic binge sessions; delayed choices exercise late positives.
        listened = duration * (rng.uniform(.75, 1.0) if tier == "love" else rng.uniform(.1, .55))
        rows.append(dict(base, event="listened", at=stamp(acted), seconds=round(listened, 1)))
        if tier == "love" and rng.random() < .78:
            rows.append(dict(base, event="finish", at=stamp(acted + timedelta(minutes=35))))
        if tier == "love" and rng.random() < .38:
            margin_kind = "spoken" if rng.random() < .45 else "written"
            rows.append(dict(base, event="margin", at=stamp(acted + timedelta(minutes=18)),
                             margin_kind=margin_kind, length=rng.randrange(15, 240),
                             length_unit="seconds" if margin_kind == "spoken" else "characters"))
        if tier == "love" and rng.random() < .12:
            rows.append(dict(base, event="share", at=stamp(acted + timedelta(minutes=40))))
        if tier == "love" and rng.random() < .07:
            rows.append(dict(base, event="export", at=stamp(acted + timedelta(minutes=45)), margin_count=rng.randrange(1, 4)))
    # Imports are source-linked when matched, but may have no item.
    source = rows[0]["source"]
    rows.append({"schema_version": SCHEMA, "event": "packet_import", "at": stamp(start + timedelta(days=30)),
                 "source": source, "item": None, "packet_id": "packet-synthetic-1", "from_other": True, "margin_count": 3})
    return sorted(rows, key=lambda row: (row["at"], row["event"]))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("output", nargs="?", default="synthetic.jsonl")
    parser.add_argument("--seed", type=int, default=176)
    parser.add_argument("--sources", type=int, default=60)
    parser.add_argument("--weeks", type=int, default=7)
    args = parser.parse_args()
    with open(args.output, "w", encoding="utf-8") as handle:
        for row in generate(args.seed, args.sources, args.weeks):
            handle.write(json.dumps(row, separators=(",", ":")) + "\n")
    print("wrote %s" % args.output)


if __name__ == "__main__":
    main()
