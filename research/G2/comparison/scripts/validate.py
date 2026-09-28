#!/usr/bin/env python3
"""Reject any comparison claim that lacks a source, a check date or a known field.

Usage: python3 research/G2/comparison/scripts/validate.py [--max-age-days N]
With --max-age-days, also fails claims whose newest check is older than N days
(the refresh trigger in ../../REFRESH.md).
"""
import datetime
import json
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
REPO_BLOB = re.compile(r"^https://github\.com/uncomposed/spoken-margins-native/blob/([0-9a-f]{7,40})/(.+)$")


def repo_quote_missing(url: str, quote: str) -> bool:
    """For sources pointing into this repo at a pinned commit, the quote must be in that file."""
    m = REPO_BLOB.match(url)
    if not m or not quote:
        return False
    shown = subprocess.run(["git", "show", f"{m[1]}:{m[2]}"], cwd=ROOT, capture_output=True, text=True)
    return shown.returncode != 0 or quote not in shown.stdout
DATE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
CATEGORIES = {"podcast", "read-aloud", "read-it-later", "notes", "ai-research", "social-listening"}
TEXT_FIELDS = {"platforms", "price_free_tier", "price_paid"}
CAPABILITY_FIELDS = {
    "plays_podcasts", "reads_web_articles_aloud", "reads_pdfs_aloud", "voice_notes_anchored",
    "text_notes_anchored", "hands_free_capture", "transcripts", "ai_summaries", "export_markdown_pkm",
    "share_note_at_moment", "group_listening", "on_device_privacy", "account_required",
}
CAPABILITY_VALUES = {"yes", "partial", "no", "unknown"}


def validate_app(app: dict, stem: str, today: datetime.date | None = None, max_age: int | None = None) -> list[str]:
    errs = []
    for key in ("id", "name", "category", "website", "why_listed", "claims"):
        if not app.get(key):
            errs.append(f"missing {key}")
    if app.get("id") and app["id"] != stem:
        errs.append(f"id {app['id']!r} does not match file name")
    if app.get("category") not in CATEGORIES:
        errs.append(f"unknown category {app.get('category')!r}")
    claims = app.get("claims") or {}
    for field in sorted((TEXT_FIELDS | CAPABILITY_FIELDS) - claims.keys()):
        errs.append(f"missing claim {field}")
    for field, claim in claims.items():
        where = f"{field}"
        if field not in TEXT_FIELDS | CAPABILITY_FIELDS:
            errs.append(f"{where}: unknown field")
            continue
        value = claim.get("value")
        if field in CAPABILITY_FIELDS and value not in CAPABILITY_VALUES:
            errs.append(f"{where}: value {value!r} not in {sorted(CAPABILITY_VALUES)}")
        if field in TEXT_FIELDS and not isinstance(value, str | int | float):
            errs.append(f"{where}: text field needs a string value")
        sources = claim.get("sources") or []
        if not sources:
            errs.append(f"{where}: no source")
        newest = None
        for i, src in enumerate(sources):
            if not str(src.get("url", "")).startswith("https://") and not str(src.get("url", "")).startswith("http://"):
                errs.append(f"{where}: source {i} has no URL")
            checked = str(src.get("checked", ""))
            if not DATE.match(checked):
                errs.append(f"{where}: source {i} has no checked date")
            else:
                d = datetime.date.fromisoformat(checked)
                newest = max(newest or d, d)
            if src.get("published") and not DATE.match(str(src["published"])[:10]):
                errs.append(f"{where}: source {i} published {src['published']!r} is not a date")
            if value not in ("unknown",) and not str(src.get("quote", "")).strip() and i == 0:
                errs.append(f"{where}: first source needs a supporting quote")
            if repo_quote_missing(str(src.get("url", "")), str(src.get("quote", ""))):
                errs.append(f"{where}: source {i} quote not found in the repo file at that commit")
            if len(str(src.get("quote", "")).split()) > 40:
                errs.append(f"{where}: source {i} quote over 40 words")
        if value == "unknown" and not claim.get("note"):
            errs.append(f"{where}: unknown needs a note saying what was checked")
        if value == "no" and field != "account_required" and not claim.get("note"):
            errs.append(f"{where}: no needs a note naming the vendor statement or the complete feature list it rests on")
        if max_age is not None and newest is not None and (today - newest).days > max_age:
            errs.append(f"{where}: stale, last checked {newest}")
    return errs


def main() -> int:
    max_age = None
    if "--max-age-days" in sys.argv:
        max_age = int(sys.argv[sys.argv.index("--max-age-days") + 1])
    today = datetime.date.today()
    failures = 0
    paths = sorted((ROOT / "apps").glob("*.json"))
    for path in paths:
        errs = validate_app(json.loads(path.read_text()), path.stem, today, max_age)
        for e in errs:
            print(f"{path.name}: {e}")
        failures += len(errs)
    print(f"{len(paths)} apps, {failures} problems")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
