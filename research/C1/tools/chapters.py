#!/usr/bin/env python3
"""Chapters an extractor built from a paper's title page (#272).

    python3 tools/chapters.py app-v2 [--only pmc-pmc13305550 ...]

Reads the I13 documents c1-extract writes (cache/i13-<extractor>/<id>.json)
and ground truth (cache/gt/<id>.json). A heading segment is a title-page
chapter when its words come from the ground truth's title, author or
front-matter text and it isn't one of the paper's real section headings.
Writes results/<extractor>/chapters.json (counts only: no paper text).
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

import regex

ROOT = Path(__file__).resolve().parents[1]
TITLE_PAGE_ROLES = {"title", "authors", "front_matter"}
WORD = re.compile(r"\w+")


def words(text: str) -> list[str]:
    return WORD.findall(text.casefold())


def heading_texts(doc: dict) -> list[str]:
    chars = regex.findall(r"\X", doc["text"])
    return ["".join(chars[s["range"]["start"]:s["range"]["start"] + s["range"]["length"]])
            for s in doc["segments"] if s["role"] == "heading"]


def title_page_chapters(doc: dict, truth: dict) -> list[str]:
    """Headings whose words all come from the ground truth's title page."""
    real = {" ".join(words(s["text"])) for s in truth["segments"] if s["role"] == "heading"}
    title_page = set()
    for s in truth["segments"]:
        if s["role"] in TITLE_PAGE_ROLES:
            title_page.update(words(s["text"]))
    found = []
    for text in heading_texts(doc):
        if " ".join(words(text)) in real:
            continue
        if re.fullmatch(r"v\d+", text.strip(), re.IGNORECASE):  # an F1000 version badge
            found.append(text)
            continue
        # Affiliation marks glued to names ("Anand1") and bare numbers don't count.
        ws = [w for w in (re.sub(r"\d+$", "", w) for w in words(text)) if w]
        if ws and all(w in title_page for w in ws):
            found.append(text)
    return found


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("extractor")
    parser.add_argument("--only", nargs="*")
    args = parser.parse_args()
    source = ROOT / "cache" / f"i13-{args.extractor}"
    if not source.exists():
        sys.exit(f"no I13 documents in {source}: run research/C1/mac/run.sh first")
    papers = {}
    for path in sorted(source.glob("*.json")):
        if args.only and path.stem not in args.only:
            continue
        truth_path = ROOT / "cache" / "gt" / path.name
        if not truth_path.exists():
            continue
        doc = json.loads(path.read_text())
        found = title_page_chapters(doc, json.loads(truth_path.read_text()))
        papers[path.stem] = {"chapters": len(heading_texts(doc)), "title_page_chapters": len(found)}
        if found:
            print(f"{path.stem}: {len(found)} title-page chapters: {[t[:40] for t in found]}")
    affected = sorted(p for p, r in papers.items() if r["title_page_chapters"])
    summary = {"extractor": args.extractor, "papers": len(papers), "papers_with_title_page_chapters": len(affected),
               "title_page_chapters": sum(r["title_page_chapters"] for r in papers.values())}
    print(json.dumps(summary))
    if not args.only:
        out = ROOT / "results" / args.extractor / "chapters.json"
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(json.dumps({"summary": summary, "papers": papers}, indent=1) + "\n")


if __name__ == "__main__":
    main()
