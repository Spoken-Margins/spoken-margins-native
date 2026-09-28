#!/usr/bin/env python3
"""Render a comparison table for a page from comparison.json, with a footnote per cell.

Usage:
  python3 research/G2/inbound/render_table.py --apps snipd,readwise-reader,spoken-margins \
      --fields voice_notes_anchored,export_markdown_pkm [--max-age-days 90] [--today YYYY-MM-DD]

Pages never type competitor facts by hand; they paste this output (or a site build
calls it). It refuses to render if a cell's newest check is older than
--max-age-days, so a stale page can't be regenerated without a refresh first
(REFRESH.md). Unknown values render as "Not documented", never as "No".
Footnotes cite the newest source for each cell. Internal notes are not rendered;
a page's prose states caveats itself. Sources inside this private repository are
refused unless --draft is given, because readers can't open them.
"""
import argparse
import datetime
import json
import pathlib
import sys

DATA = pathlib.Path(__file__).resolve().parents[1] / "comparison.json"
WORDS = {"yes": "Yes", "partial": "Partly", "no": "No", "unknown": "Not documented"}
LABELS = {
    "platforms": "Platforms", "price_free_tier": "Free tier", "price_paid": "Cheapest paid plan",
    "plays_podcasts": "Plays podcasts", "reads_web_articles_aloud": "Reads articles aloud",
    "reads_pdfs_aloud": "Reads PDFs aloud", "voice_notes_anchored": "Spoken note at a moment",
    "text_notes_anchored": "Typed note at a moment", "hands_free_capture": "Capture without looking",
    "transcripts": "Transcripts", "ai_summaries": "AI summaries", "export_markdown_pkm": "Export to notes apps",
    "share_note_at_moment": "Share a note at the moment", "group_listening": "Groups or clubs",
    "on_device_privacy": "Stays on device", "account_required": "Account required",
}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--apps", required=True)
    ap.add_argument("--fields", required=True)
    ap.add_argument("--max-age-days", type=int, default=90)
    ap.add_argument("--today", default=datetime.date.today().isoformat())
    ap.add_argument("--draft", action="store_true", help="allow private-repo sources (not for publishing)")
    args = ap.parse_args()
    today = datetime.date.fromisoformat(args.today)
    apps = {a["id"]: a for a in json.loads(DATA.read_text())["apps"]}
    ids, fields = args.apps.split(","), args.fields.split(",")
    missing = [i for i in ids if i not in apps] + [f for f in fields if f not in LABELS]
    if missing:
        print(f"unknown app or field: {', '.join(missing)}", file=sys.stderr)
        return 2

    notes, stale, private = [], [], []
    header = "| | " + " | ".join(apps[i]["name"] for i in ids) + " |"
    rows = [header, "|---" * (len(ids) + 1) + "|"]
    for field in fields:
        cells = []
        for app_id in ids:
            claim = apps[app_id]["claims"][field]
            src = max(claim["sources"], key=lambda s: s["checked"])
            newest = datetime.date.fromisoformat(src["checked"])
            if "github.com/uncomposed/spoken-margins-native" in src["url"]:
                private.append(f"{app_id}.{field}")
            if (today - newest).days > args.max_age_days:
                stale.append(f"{app_id}.{field} (checked {newest})")
            value = claim["value"]
            text = WORDS.get(value, str(value))
            if value in WORDS and value not in ("unknown",) and claim.get("detail"):
                text += f": {claim['detail']}"
            notes.append(f"{src['title']}, <{src['url']}>, checked {src['checked']}.")
            cells.append(f"{text.replace('|', '/')} [^{len(notes)}]")
        rows.append(f"| {LABELS[field]} | " + " | ".join(cells) + " |")
    if stale:
        print("refusing to render stale cells; refresh them first (REFRESH.md):\n  " + "\n  ".join(stale), file=sys.stderr)
        return 1
    if private and not args.draft:
        print("refusing to render sources in the private repository; give these a public source "
              "(App Store listing or release notes) or pass --draft:\n  " + "\n  ".join(private), file=sys.stderr)
        return 1
    print("\n".join(rows))
    print()
    for n, note in enumerate(notes, 1):
        print(f"[^{n}]: {note}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
