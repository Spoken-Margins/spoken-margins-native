#!/usr/bin/env python3
"""Merge apps/*.json into comparison.json after validating every record.

Usage: python3 research/G2/comparison/scripts/build.py
Exits non-zero, writing nothing, if any record fails validation.
"""
import json
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).parent))
from validate import validate_app  # noqa: E402

ROOT = pathlib.Path(__file__).resolve().parents[1]


SYMBOL = {"yes": "●", "partial": "◐", "no": "○", "unknown": "?"}
COLUMNS = [
    ("plays_podcasts", "Podcasts"), ("reads_web_articles_aloud", "Articles aloud"), ("reads_pdfs_aloud", "PDFs aloud"),
    ("voice_notes_anchored", "Spoken note at moment"), ("text_notes_anchored", "Typed note at moment"),
    ("hands_free_capture", "Hands-free capture"), ("transcripts", "Transcripts"), ("ai_summaries", "AI summaries"),
    ("export_markdown_pkm", "Export to notes"), ("share_note_at_moment", "Share note at moment"),
    ("group_listening", "Groups"), ("on_device_privacy", "Content stays on device"), ("account_required", "Account needed"),
]


def render_table(apps: list[dict], checked: list[str]) -> str:
    """A phone-readable view of comparison.json. Every cell's source is in the JSON."""
    lines = [
        "# App comparison (generated)",
        "",
        "Compiled by the maker of Spoken Margins, one of the apps listed. It is not a neutral review: it compares documented capabilities, "
        "each with a source a reader can check, and doesn't rate quality.",
        "",
        f"Generated from `comparison.json` by `comparison/scripts/build.py`; don't edit by hand. Sources checked {checked[0]} to {checked[-1]}. "
        "Every cell has a source, date and quote in `comparison/apps/<id>.json`, and the notes there carry caveats this table drops.",
        "",
        "● yes · ◐ partial · ○ no · ? unknown (not documented either way). \"Account needed\" ● means an account is required.",
        "",
        "| App | " + " | ".join(label for _, label in COLUMNS) + " | Price (cheapest paid) |",
        "|---" * (len(COLUMNS) + 2) + "|",
    ]
    for app in sorted(apps, key=lambda a: (a["id"] != "spoken-margins", a["name"].lower())):
        cells = [SYMBOL.get(app["claims"][f]["value"], "?") for f, _ in COLUMNS]
        price = str(app["claims"]["price_paid"]["value"]).replace("|", "/")
        lines.append(f"| {app['name']} | " + " | ".join(cells) + f" | {price} |")
    lines += ["", "## Platforms", ""]
    for app in sorted(apps, key=lambda a: a["name"].lower()):
        lines.append(f"- **{app['name']}**: {app['claims']['platforms']['value']}")
    return "\n".join(lines) + "\n"


def main() -> int:
    apps, errors = [], []
    for path in sorted((ROOT / "apps").glob("*.json")):
        record = json.loads(path.read_text())
        errors += [f"{path.name}: {e}" for e in validate_app(record, path.stem)]
        apps.append(record)
    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1
    checked = sorted({s["checked"] for a in apps for c in a["claims"].values() for s in c["sources"]})
    out = {
        "about": "Sourced comparison of apps Spoken Margins' early adopters use now. Built from apps/*.json; edit those, not this file.",
        "oldest_check": checked[0],
        "newest_check": checked[-1],
        "apps": apps,
    }
    (ROOT.parent / "comparison.json").write_text(json.dumps(out, indent=2, ensure_ascii=False) + "\n")
    (ROOT.parent / "comparison.md").write_text(render_table(apps, checked))
    print(f"wrote comparison.json: {len(apps)} apps, checks {checked[0]}..{checked[-1]}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
