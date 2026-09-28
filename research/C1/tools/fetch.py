#!/usr/bin/env python3
"""Downloads the corpus into research/C1/cache/ and records what each PDF is.

    python3 tools/fetch.py            # fetch everything, convert ground truth
    python3 tools/fetch.py --update-manifest   # also write sha256, pages and
                                               # measured layout into the manifest

Layout: cache/pdf/<id>.pdf, cache/gt/<id>.json (role-labelled segments).
The `-imageonly` entry is derived here by rasterizing its base PDF.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path

import pymupdf

sys.path.insert(0, str(Path(__file__).resolve().parent))
import groundtruth  # noqa: E402
import net  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "corpus" / "manifest.json"
PDF_DIR = net.CACHE / "pdf"
GT_DIR = net.CACHE / "gt"


def load_manifest() -> dict:
    return json.loads(MANIFEST.read_text())


def rasterize(source: Path, target: Path, dpi: int = 200) -> None:
    """A page-image-only PDF: what a phone scan or an old library scan gives."""
    src = pymupdf.open(source)
    out = pymupdf.open()
    for page in src:
        pix = page.get_pixmap(dpi=dpi, colorspace=pymupdf.csGRAY)
        new = out.new_page(width=page.rect.width, height=page.rect.height)
        new.insert_image(new.rect, stream=pix.tobytes("jpeg", jpg_quality=80))
    out.save(target, garbage=4, deflate=True)


def layout_facts(path: Path) -> dict:
    """Measured, not declared: pages, text layer, and column count."""
    doc = pymupdf.open(path)
    words = 0
    two_col_pages = 0
    counted = 0
    for index, page in enumerate(doc):
        text = page.get_text("words")
        words += len(text)
        if index == 0 or len(text) < 150:
            continue
        counted += 1
        width = page.rect.width
        blocks = [b for b in page.get_text("blocks") if b[6] == 0 and len(b[4].split()) >= 25]
        left = sum(1 for b in blocks if b[2] <= width * 0.56 and (b[2] - b[0]) < width * 0.48)
        right = sum(1 for b in blocks if b[0] >= width * 0.44 and (b[2] - b[0]) < width * 0.48)
        if left and right:
            two_col_pages += 1
    return {
        "pages": doc.page_count,
        "text_layer_words": words,
        "columns": 2 if counted and two_col_pages / counted >= 0.4 else 1,
    }


def truth_facts(segments: list[dict]) -> dict:
    """Counts from ground truth: how much math, and how many figures and tables."""
    body_words = sum(len(s["text"].split()) for s in segments if s["role"] in ("body", "abstract"))
    math = sum(1 for s in segments for m in s.get("markers", []) if m["kind"] == "math")
    math += sum(1 for s in segments if s["role"] == "equation")
    return {
        "body_words": body_words,
        "math_per_1000_words": round(1000 * math / max(1, body_words), 1),
        "captions": sum(1 for s in segments if s["role"] == "caption"),
        "tables": sum(1 for s in segments if s["role"] == "table"),
        "citation_markers": sum(1 for s in segments for m in s.get("markers", []) if m["kind"] == "citation"),
        "footnote_markers": sum(1 for s in segments for m in s.get("markers", []) if m["kind"] == "footnote"),
    }


# Tags that are measured rather than declared. Math-heavy: at least 20 formulas
# (inline or display) per 1000 body words in the ground truth.
MEASURED_TAGS = {"single-column", "two-column", "math-heavy"}


def measured_tags(entry: dict, facts: dict) -> list[str]:
    tags = [t for t in entry["tags"] if t not in MEASURED_TAGS]
    if facts["text_layer_words"] or "image-only" not in tags:
        tags.append("two-column" if facts["columns"] == 2 else "single-column")
    if facts["math_per_1000_words"] >= 20:
        tags.append("math-heavy")
    return tags


def fetch_entry(entry: dict, entries_by_id: dict) -> dict:
    PDF_DIR.mkdir(parents=True, exist_ok=True)
    GT_DIR.mkdir(parents=True, exist_ok=True)
    pdf_path = PDF_DIR / f"{entry['id']}.pdf"
    base = entries_by_id.get(entry.get("derived_from", ""))
    if not pdf_path.exists():
        if base:
            base_path = PDF_DIR / f"{base['id']}.pdf"
            if not base_path.exists():
                base_path.write_bytes(net.get(base["pdf_url"]))
            rasterize(base_path, pdf_path)
        else:
            pdf_path.write_bytes(net.get(entry["pdf_url"]))
    gt_path = GT_DIR / f"{entry['id']}.json"
    raw = net.get(entry["ground_truth"]["url"])
    kind = entry["ground_truth"]["kind"]
    segments = groundtruth.jats_segments(raw) if kind == "jats" else groundtruth.latexml_segments(raw)
    gt_path.write_text(json.dumps({"id": entry["id"], "kind": kind, "segments": segments}, ensure_ascii=False))
    facts = layout_facts(pdf_path)
    facts.update(truth_facts(segments))
    facts["sha256"] = hashlib.sha256(pdf_path.read_bytes()).hexdigest() if not base else None
    return facts


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--update-manifest", action="store_true")
    parser.add_argument("--only", nargs="*")
    args = parser.parse_args()
    manifest = load_manifest()
    by_id = {e["id"]: e for e in manifest["entries"]}
    failures = 0
    for entry in manifest["entries"]:
        if args.only and entry["id"] not in args.only:
            continue
        try:
            facts = fetch_entry(entry, by_id)
        except Exception as error:  # report and keep going; one bad URL shouldn't stop the corpus
            failures += 1
            print(f"FAIL {entry['id']}: {error}", file=sys.stderr)
            continue
        print(f"ok   {entry['id']}: {facts['pages']} pages, {facts['columns']} col, {facts['text_layer_words']} words")
        if args.update_manifest:
            measured = {k: v for k, v in facts.items() if v is not None}
            entry["measured"] = measured
            entry["tags"] = measured_tags(entry, facts)
    if args.update_manifest:
        MANIFEST.write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
