#!/usr/bin/env python3
"""Prints a candidate's spoken text with each run of words tagged by its scored
category, to check the scorer by eye.

    python3 tools/inspect_alignment.py pymupdf-raw pmc-pmc10756530 [--from 0 --words 400]
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
    args = parser.parse_args()
    truth = score.Truth(json.loads((score.GT_DIR / f"{args.id}.json").read_text())["segments"])
    candidate = json.loads((score.CANDIDATES / args.extractor / f"{args.id}.json").read_text())
    spoken, categories, positions = score.categorize(truth, candidate.get("spoken") or candidate.get("markdown") or "")
    out, current = [], None
    for i in range(args.start, min(len(categories), args.start + args.words)):
        if categories[i] != current:
            current = categories[i]
            out.append(f"\n[{current}{'' if positions[i] is None else '@' + str(positions[i])}] ")
        out.append(spoken.raw[i] + " ")
    print("".join(out))


if __name__ == "__main__":
    main()
