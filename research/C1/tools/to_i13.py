#!/usr/bin/env python3
"""Converts ground-truth segments into I13 structured documents and validates them.

    python3 tools/to_i13.py            # every cache/gt/*.json -> cache/i13/, validated

This is a check on the I13 draft, not a product path: if 65 real papers from
two very different sources fit the schema without special cases, the roles
and marker kinds are probably the right ones.
"""

from __future__ import annotations

import hashlib
import json
import sys
from pathlib import Path

import jsonschema
import regex

ROOT = Path(__file__).resolve().parents[1]
SCHEMA = json.loads((ROOT / "I13" / "structured-document.schema.json").read_text())
ENGINE = {"jats": "ground_truth_jats", "latexml": "ground_truth_latexml"}


def chars(text: str) -> list[str]:
    """Extended grapheme clusters: what Swift's String.count counts."""
    return regex.findall(r"\X", text)


def char_len(text: str) -> int:
    return len(chars(text))


def convert(gt: dict, page_count: int) -> dict:
    parts: list[str] = []
    length = 0  # running length of the text so far, in Characters
    segments, markers = [], []
    for index, seg in enumerate(gt["segments"]):
        if parts:
            parts.append("\n\n")
            length += 2
        start = length
        body = seg["text"]
        cursor = 0
        for marker in sorted(seg.get("markers", []), key=lambda m: m["at"]):
            before = body[cursor:marker["at"]]
            parts.append(before)
            length += char_len(before)
            cursor = marker["at"]
            printed = marker["label"] or ("x" if marker["kind"] == "math" else "")
            if marker["kind"] == "citation" and printed and printed[0] not in "([":
                printed = f"[{printed}]"
            markers.append({"kind": marker["kind"], "range": {"start": length, "length": char_len(printed)},
                            "label": marker["label"] or None, "targetSegmentId": None})
            parts.append(printed)
            length += char_len(printed)
        rest = body[cursor:]
        parts.append(rest)
        length += char_len(rest)
        entry = {"id": f"s{index}", "role": seg["role"], "range": {"start": start, "length": length - start}}
        if seg["role"] == "heading":
            entry["level"] = 2
        segments.append(entry)
    text = "".join(parts)
    return {
        "schemaVersion": "structured-document.v1",
        "extraction": {
            "engine": ENGINE[gt["kind"]],
            "version": 1,
            "sourceSHA256": None,
            "pageCount": page_count,
            "textSHA256": hashlib.sha256(text.encode()).hexdigest(),
        },
        "text": text,
        "segments": segments,
        "markers": markers,
        "floats": [],
    }


def check_ranges(doc: dict) -> None:
    """Ranges must index the text, in order, without overlap."""
    units = chars(doc["text"])
    total = len(units)
    previous_end = 0
    for seg in doc["segments"]:
        start, length = seg["range"]["start"], seg["range"]["length"]
        assert previous_end <= start and start + length <= total, seg
        gap = "".join(units[previous_end:start])
        assert not gap.strip(), f"non-whitespace between segments: {gap!r}"
        previous_end = start + length
    spans = [(s["range"]["start"], s["range"]["start"] + s["range"]["length"]) for s in doc["segments"]]
    for marker in doc["markers"]:
        start = marker["range"]["start"]
        end = start + marker["range"]["length"]
        assert any(a <= start and end <= b for a, b in spans), marker


def main() -> None:
    manifest = json.loads((ROOT / "corpus" / "manifest.json").read_text())
    out = ROOT / "cache" / "i13"
    out.mkdir(parents=True, exist_ok=True)
    validator = jsonschema.Draft202012Validator(SCHEMA)
    fixture = json.loads((ROOT / "I13" / "fixture.json").read_text())
    validator.validate(fixture)
    check_ranges(fixture)
    count = 0
    for entry in manifest["entries"]:
        gt_path = ROOT / "cache" / "gt" / f"{entry['id']}.json"
        if not gt_path.exists():
            continue
        doc = convert(json.loads(gt_path.read_text()), entry.get("measured", {}).get("pages", 0))
        validator.validate(doc)
        check_ranges(doc)
        (out / f"{entry['id']}.json").write_text(json.dumps(doc, ensure_ascii=False))
        count += 1
    print(f"fixture and {count} ground-truth documents validate against structured-document.v1")
    sys.exit(0 if count else 1)


if __name__ == "__main__":
    main()
