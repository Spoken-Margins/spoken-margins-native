#!/usr/bin/env python3
"""Lists the citation sites an extractor read aloud as a bare number (#1189).

    python3 tools/number_read_sites.py app-v2                 # every paper
    python3 tools/number_read_sites.py app-v2 pmc-pmc7619013  # one paper
    python3 tools/number_read_sites.py app-v2 --markdown      # a table for a PR

For each site the ground truth marks as a citation and the candidate spoke as a number, it prints
the words before the site, the label the paper printed, and what was spoken in its place, so each
one can be sorted into a real citation style the app misses or something that only looks like
one. Reads cache/candidates/<extractor>/<id>.json and cache/gt/<id>.json, like score.py.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import score  # noqa: E402

WORDS_AROUND = 7


def number_read_sites(truth: score.Truth, text: str) -> list[dict]:
    """The sites `score.py` counts as `number_read`, with the words around them."""
    spoken = score.Spoken(text, truth.vocab)
    pos = score.align(truth, spoken)
    first_at: dict[int, int] = {}
    for i, p in enumerate(pos):
        if p is not None and p not in first_at:
            first_at[p] = i
    claimed: dict[int, str] = {}
    found = []
    seen: set[int] = set()
    for marker, outcome in score.marker_sites(truth, spoken, pos, first_at, claimed):
        taken = sorted(set(claimed) - seen)
        seen.update(taken)
        if marker["kind"] != "citation" or outcome != "number_read":
            continue
        k = marker["before"]
        found.append({
            "label": marker["label"],
            "before": " ".join(truth.tokens[max(0, k - WORDS_AROUND):k]),
            "after": " ".join(truth.tokens[k:k + 3]),
            "spoken": " ".join(spoken.raw[g] for g in taken),
            "line": spoken.lines[spoken.line_of[taken[0]]] if taken else "",
        })
    return found


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("extractor")
    parser.add_argument("papers", nargs="*")
    parser.add_argument("--markdown", action="store_true", help="print one table row per site")
    args = parser.parse_args()
    manifest = json.loads(score.MANIFEST.read_text())
    total = 0
    if args.markdown:
        print("| Paper | Words before | Printed label | Spoken | Style |\n| --- | --- | --- | --- | --- |")
    for entry in manifest["entries"]:
        if args.papers and entry["id"] not in args.papers:
            continue
        cand_path = score.CANDIDATES / args.extractor / f"{entry['id']}.json"
        gt_path = score.GT_DIR / f"{entry['id']}.json"
        if not cand_path.exists() or not gt_path.exists():
            continue
        candidate = json.loads(cand_path.read_text())
        text = candidate.get("spoken") or candidate.get("markdown") or ""
        truth = score.Truth(json.loads(gt_path.read_text())["segments"])
        sites = number_read_sites(truth, text) if text.strip() else []
        total += len(sites)
        if not sites:
            continue
        if not args.markdown:
            print(f"== {entry['id']}: {len(sites)} sites")
        for site in sites:
            if args.markdown:
                print(f"| {entry['id']} | …{site['before']} | {site['label']} | {site['spoken']} | |")
            else:
                print(f"   [{site['label']}] …{site['before']} ⟦{site['spoken']}⟧ {site['after']}…")
    print(f"{total} number-read citation sites", file=sys.stderr)


if __name__ == "__main__":
    main()
