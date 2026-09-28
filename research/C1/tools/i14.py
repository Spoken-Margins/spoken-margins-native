#!/usr/bin/env python3
"""Reference I14 projection: what is said for an I13 structured document.

    python3 tools/i14.py            # ground-truth I13 docs -> cache/candidates/gt-i14/, a scorer check

Applies I14's role and marker rules (docs/workstreams/interfaces.md, "How
each kind of text is spoken"), the part that decides *what* is said:

- roles are read, announced or skipped;
- citation and footnote markers are silent.

Not applied: I14's word-level normalization (numbers, units, statistics,
Greek letters, "et al." -> "and colleagues"). That changes how words sound,
not which words, and doing it here would stop spoken words matching ground
truth in the scorer. SessionKit applies both.

Announcements go on their own line, so the scorer can tell them apart from
clutter (score.py's `announcement` category).
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

import regex

ROOT = Path(__file__).resolve().parents[1]

# Every announcement the projection can make. score.py imports this.
REFERENCES_SKIPPED = "References skipped."
TABLE_NOT_READ = "Table not read."
BACK_MATTER_SKIPPED = "Back matter skipped."
EQUATION = "Equation."
EQUATION_NOT_READ = "Equation not read."  # C2 #221
ANNOUNCEMENTS = {REFERENCES_SKIPPED, TABLE_NOT_READ, BACK_MATTER_SKIPPED, EQUATION, EQUATION_NOT_READ}

# I14's published table, plus C1's proposed defaults for roles it doesn't
# list yet (asked on #191). "read" | "announce" | "skip" | "silent".
ROLE_RULES = {
    "title": "read",           # proposed
    "abstract": "read",        # proposed
    "body": "read",
    "heading": "read",
    "caption": "announce",
    "table": "announce",
    "footnote": "skip",
    "reference": "announce",   # once per run: "References skipped."
    "page_header": "silent",
    "page_footer": "silent",
    "authors": "read",         # owner, #191: author names are read
    "front_matter": "silent",  # owner: the rest of the title page is skipped; silently is C1's proposal to C2
    "back_matter": "announce", # proposed: "Back matter skipped." once per run
    "equation": "announce",    # proposed: "Equation."
    "unknown": "read",         # proposed
}
SILENT_MARKERS = {"citation", "footnote"}


def _text_without_silent_markers(doc: dict, chars: list[str], segment: dict) -> str:
    """The segment's text with its silent markers cut out. `chars` is the
    document text split into Characters (grapheme clusters), which is what
    I13 ranges count."""
    start, length = segment["range"]["start"], segment["range"]["length"]
    end = start + length
    cuts = sorted(
        (m["range"]["start"], m["range"]["start"] + m["range"]["length"])
        for m in doc["markers"]
        if m["kind"] in SILENT_MARKERS and start <= m["range"]["start"] < end
    )
    pieces, cursor = [], start
    for a, b in cuts:
        pieces.append("".join(chars[cursor:a]))
        cursor = max(cursor, b)
    pieces.append("".join(chars[cursor:end]))
    # "reading [3], but" -> "reading, but", as SpeechTextNormalizer tidies it.
    return re.sub(r"\s+([,.;:!?)\]])", r"\1", " ".join("".join(pieces).split()))


def project(doc: dict) -> str:
    """Spoken text for an I13 document, one segment or announcement per line."""
    chars = regex.findall(r"\X", doc["text"])
    lines: list[str] = []
    previous_role = None
    for segment in doc["segments"]:
        role = segment["role"]
        rule = ROLE_RULES.get(role, "read")
        if rule == "read":
            lines.append(_text_without_silent_markers(doc, chars, segment))
        elif role == "caption":
            # "Figure 2." then the caption. Captions usually begin with their
            # label already; don't say it twice.
            text = _text_without_silent_markers(doc, chars, segment)
            label = segment.get("label")
            if label and not text.lower().startswith(label.lower()):
                lines.append(label + ".")
            lines.append(text)
        elif role == "table":
            lines.append(TABLE_NOT_READ)
        elif role == "reference" and previous_role != "reference":
            lines.append(REFERENCES_SKIPPED)
        elif role == "back_matter" and previous_role != "back_matter":
            lines.append(BACK_MATTER_SKIPPED)
        elif role == "equation":
            lines.append(EQUATION)
        previous_role = role
    return "\n".join(line for line in lines if line)


def main() -> None:
    """Projects every ground-truth I13 document (from to_i13.py) as a
    candidate. Scoring those checks the pipeline end to end: clutter should
    be front matter only, and nothing should be missing."""
    source = ROOT / "cache" / "i13"
    out = ROOT / "cache" / "candidates" / "gt-i14"
    out.mkdir(parents=True, exist_ok=True)
    count = 0
    for path in sorted(source.glob("*.json")):
        doc = json.loads(path.read_text())
        record = {"id": path.stem, "extractor": "gt-i14", "spoken": project(doc)}
        (out / path.name).write_text(json.dumps(record, ensure_ascii=False))
        count += 1
    print(f"projected {count} ground-truth documents into {out}", file=sys.stderr)


if __name__ == "__main__":
    main()
