#!/usr/bin/env python3
"""Prints a candidate's spoken text with each run of words tagged by its scored
category, to check the scorer by eye.

    python3 tools/inspect_alignment.py pymupdf-raw pmc-pmc10756530 [--from 0 --words 400]
    python3 tools/inspect_alignment.py app-baseline arxiv-2609.22558v1 --missing

--missing lists instead the ground-truth body passages that were never
spoken, under the section heading they belong to, to find where an
extractor loses text (#219).
"""

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import score  # noqa: E402


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("extractor")
    parser.add_argument("id")
    parser.add_argument("--from", dest="start", type=int, default=0)
    parser.add_argument("--words", type=int, default=400)
    parser.add_argument("--missing", action="store_true", help="list unspoken body passages instead")
    parser.add_argument("--min-words", type=int, default=15, help="with --missing: shortest passage to list")
    args = parser.parse_args()
    truth = score.Truth(json.loads((score.GT_DIR / f"{args.id}.json").read_text())["segments"])
    candidate = json.loads((score.CANDIDATES / args.extractor / f"{args.id}.json").read_text())
    spoken, categories, positions = score.categorize(truth, candidate.get("spoken") or candidate.get("markdown") or "")
    if args.missing:
        print_missing(truth, positions, args.min_words)
        return
    out, current = [], None
    for i in range(args.start, min(len(categories), args.start + args.words)):
        if categories[i] != current:
            current = categories[i]
            out.append(f"\n[{current}{'' if positions[i] is None else '@' + str(positions[i])}] ")
        out.append(spoken.raw[i] + " ")
    print("".join(out))


def print_missing(truth, positions, min_words):
    """Runs of ground-truth body words no spoken word aligned to."""
    covered = {p for p in positions if p is not None}
    heading = "(before the first heading)"
    run: list[int] = []
    total = 0

    def flush():
        nonlocal total
        if len(run) >= min_words:
            words = [truth.tokens[q] for q in run]
            preview = " ".join(words[:12]) + (" …" if len(words) > 12 else "")
            print(f"{len(run):6d} words  in {heading[:60]!r}: {preview}")
            total += len(run)
        run.clear()

    for q, role in enumerate(truth.roles):
        if role == "heading":
            text = truth.segments[truth.segment_of[q]]["text"]
            if text != heading:  # a new section: report its missing passages separately
                flush()
                heading = text
            continue
        if role in score.BODY_ROLES and q not in covered:
            run.append(q)
        elif q in covered:
            flush()
    flush()
    body = sum(1 for r in truth.roles if r in score.BODY_ROLES)
    print(f"listed {total} of {body} body words ({total / max(1, body):.0%}) in passages of {min_words}+ words")


if __name__ == "__main__":
    main()
