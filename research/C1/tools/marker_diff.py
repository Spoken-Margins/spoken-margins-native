#!/usr/bin/env python3
"""Compares the silenced markers of two extractor runs over the corpus (#4194).

    python3 tools/marker_diff.py <before>/i13 <after>/i13                 # counts per paper
    python3 tools/marker_diff.py <before>/i13 <after>/i13 --sites out.tsv  # and every changed site

Each directory holds the I13 documents one run of `mac/check-stable.sh` wrote to
cache/i13-app-v2/ (copy the directory aside between runs). A marker is a run the listener does
not hear. For each paper it prints, before and after: citation markers, footnote markers, the
footnote markers whose label has a letter (the ones a math index is mistaken for), and the
characters in footnote segments (a footnote body the extractor stopped linking to its marker
shows up as fewer). It also says whether the document's text changed, which it should not: the
classifier changes what is silenced, never the text.

`--sites` writes one line per marker that one run has and the other lacks, with the text around
it, so a sample can be read by hand.
"""

from __future__ import annotations

import argparse
import json
import sys
from collections import Counter
from pathlib import Path

import regex

AROUND = 28


def load(path: Path) -> dict:
    with path.open(encoding="utf-8") as handle:
        return json.load(handle)


def has_letter(label: str | None) -> bool:
    return any(character.isalpha() for character in label or "")


def marker_key(marker: dict) -> tuple[int, int, str]:
    return (marker["range"]["start"], marker["range"]["length"], marker["kind"])


def counts(document: dict) -> dict[str, int]:
    markers = document.get("markers", [])
    return {
        "citation": sum(1 for marker in markers if marker["kind"] == "citation"),
        "footnote": sum(1 for marker in markers if marker["kind"] == "footnote"),
        "letter": sum(1 for marker in markers if marker["kind"] == "footnote" and has_letter(marker.get("label"))),
        "footnote_chars": sum(
            segment["range"]["length"] for segment in document.get("segments", []) if segment["role"] == "footnote"
        ),
    }


def characters(text: str) -> list[str]:
    """The text as Swift Characters (grapheme clusters), which is what a marker's range counts:
    a base with its combining marks ("g⃗") is one, and so is a CR-LF pair. A plain `text[start]`
    drifts after the first of either."""
    return regex.findall(r"\X", text)


def context(text: list[str], start: int, length: int) -> tuple[str, str, str]:
    def flat(value: list[str]) -> str:
        return "".join(value).replace("\n", "⏎").replace("\t", " ")

    return (
        flat(text[max(0, start - AROUND):start]),
        flat(text[start:start + length]),
        flat(text[start + length:start + length + AROUND]),
    )


def segment_role(document: dict, start: int) -> str:
    for segment in document.get("segments", []):
        if segment["range"]["start"] <= start < segment["range"]["start"] + segment["range"]["length"]:
            return segment["role"]
    return "?"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("before", type=Path)
    parser.add_argument("after", type=Path)
    parser.add_argument("--sites", type=Path, help="write every changed marker site to this TSV")
    arguments = parser.parse_args()

    names = sorted({path.name for path in arguments.before.glob("*.json")} & {path.name for path in arguments.after.glob("*.json")})
    if not names:
        print("no papers in common", file=sys.stderr)
        return 1
    only_one = {path.name for path in arguments.before.glob("*.json")} ^ {path.name for path in arguments.after.glob("*.json")}

    totals_before: Counter[str] = Counter()
    totals_after: Counter[str] = Counter()
    text_changed: list[str] = []
    fewer_footnote_chars: list[str] = []
    papers_with_letters_before = 0
    papers_with_letters_after = 0
    removed_labels: Counter[str] = Counter()
    added_labels: Counter[str] = Counter()
    sites: list[str] = []
    misplaced = 0

    print(f"{'paper':<24} {'citation':>13} {'footnote':>13} {'letter':>13} {'fn chars':>15}  text")
    for name in names:
        before = load(arguments.before / name)
        after = load(arguments.after / name)
        paper = name.removesuffix(".json")
        was, now = counts(before), counts(after)
        totals_before.update(was)
        totals_after.update(now)
        papers_with_letters_before += was["letter"] > 0
        papers_with_letters_after += now["letter"] > 0
        same_text = before["text"] == after["text"]
        if not same_text:
            text_changed.append(paper)
        if now["footnote_chars"] < was["footnote_chars"]:
            fewer_footnote_chars.append(paper)
        if was != now or not same_text:
            cells = " ".join(f"{was[key]:>6}→{now[key]:<6}" for key in ("citation", "footnote", "letter", "footnote_chars"))
            print(f"{paper:<24} {cells}  {'same' if same_text else 'CHANGED'}")
        if same_text:
            before_keys = {marker_key(marker): marker for marker in before.get("markers", [])}
            after_keys = {marker_key(marker): marker for marker in after.get("markers", [])}
            text = characters(before["text"])
            for change, source, markers, other, tally in (
                ("spoken-now", before, before_keys, after_keys, removed_labels),
                ("silenced-now", after, after_keys, before_keys, added_labels),
            ):
                for key in sorted(markers.keys() - other.keys()):
                    start, length, kind = key
                    left, run, right = context(text, start, length)
                    label = markers[key].get("label") or run
                    if label not in run:
                        misplaced += 1
                    tally[label] += 1
                    sites.append("\t".join([paper, change, kind, segment_role(source, start), left, label, right]))

    def line(label: str, key: str) -> None:
        print(f"{label:<34} {totals_before[key]:>7} → {totals_after[key]:<7}")

    print()
    print(f"papers compared: {len(names)}" + (f" (in one run only: {', '.join(sorted(only_one))})" if only_one else ""))
    line("citation markers", "citation")
    line("footnote markers", "footnote")
    line("footnote markers with a letter", "letter")
    print(f"{'papers with a letter marker':<34} {papers_with_letters_before:>7} → {papers_with_letters_after:<7}")
    line("characters in footnote segments", "footnote_chars")
    print(f"papers whose text changed: {len(text_changed)}" + (f" ({', '.join(text_changed)})" if text_changed else ""))
    print(f"papers with fewer footnote characters: {len(fewer_footnote_chars)}"
          + (f" ({', '.join(fewer_footnote_chars)})" if fewer_footnote_chars else ""))
    print(f"markers now spoken: {sum(removed_labels.values())}; commonest: "
          + ", ".join(f"{label} ({count})" for label, count in removed_labels.most_common(12)))
    print(f"markers now silenced: {sum(added_labels.values())}; commonest: "
          + ", ".join(f"{label} ({count})" for label, count in added_labels.most_common(12)))

    if arguments.sites:
        arguments.sites.parent.mkdir(parents=True, exist_ok=True)
        header = "\t".join(["paper", "change", "kind", "role", "before", "run", "after"])
        arguments.sites.write_text("\n".join([header] + sites) + "\n", encoding="utf-8")
        print(f"sites: {len(sites)} written to {arguments.sites}"
              + (f" ({misplaced} whose context may be off: the text there does not read as the label)" if misplaced else ""))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
