"""Score the matcher against the labeled test set.

    python3 score.py              # offline, from recorded responses
    B3_HTTP=record python3 score.py   # fetch anything not yet recorded

Exits non-zero if any confident match is wrong, or a brief threshold is missed.
"""
from __future__ import annotations

import json
import os
import sys
import urllib.parse
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from b3 import http, youtube  # noqa: E402
from b3.match import days_apart, match  # noqa: E402
from b3.text import fold  # noqa: E402

NONE_CATEGORIES = {"clip", "no_feed", "not_in_feed", "non_podcast"}


def _audio_key(url: str | None) -> str | None:
    if not url:
        return None
    path = urllib.parse.urlsplit(url).path
    return path.rsplit("/", 1)[-1] or None


def same_episode(cand, expected: dict) -> bool:
    if cand.guid and expected.get("guid") and cand.guid.strip() == expected["guid"].strip():
        return True
    a, b = _audio_key(cand.audio_url), _audio_key(expected.get("audio_url"))
    if a and b and a == b and len(a) > 8:
        return True
    days = days_apart(cand.published, expected.get("published"))
    return fold(cand.title) == fold(expected.get("title", "")) and days is not None and days <= 1


def main() -> int:
    cases = json.loads((HERE / "testset.json").read_text())["cases"]
    rows, missing = [], []
    for case in cases:
        try:
            ev = youtube.evidence(case["url"])
            result = match(ev) if ev else None
        except http.MissingFixture as e:
            missing.append((case["id"], str(e)))
            continue
        exp = case.get("expected")
        status = result.status if result else "none"
        if status == "confident":
            outcome = "correct" if exp and same_episode(result.match, exp) else "WRONG"
        elif exp:
            in_review = status == "review" and any(same_episode(c, exp) for c in result.candidates)
            outcome = "missed (in candidates)" if in_review else "missed"
        else:
            outcome = "none reported" if status == "none" else "review offered"
        rows.append((case, status, outcome, result))
        print(f"[{len(rows)}/{len(cases)}] {case['id']} {status} {outcome}", file=sys.stderr, flush=True)

    if missing:
        print(f"{len(missing)} cases lack recorded responses; run with B3_HTTP=record:")
        for cid, err in missing[:10]:
            print("  ", cid, err)
        return 2

    width = max(len(c["id"]) for c, *_ in rows)
    for case, status, outcome, result in rows:
        got = result.match.title if result and result.match else (result.reason if result else "no evidence")
        print(f"{case['id']:<{width}}  {case['category']:<12} {status:<9} {outcome:<22} {got[:70]}")

    positives = [r for r in rows if r[0].get("expected")]
    no_feed = [r for r in rows if r[0]["category"] == "no_feed"]
    none_labeled = [r for r in rows if not r[0].get("expected")]
    correct = sum(1 for r in positives if r[2] == "correct")
    wrong = sum(1 for r in rows if r[2] == "WRONG")
    none_ok = sum(1 for r in no_feed if r[1] == "none")
    in_cands = sum(1 for r in positives if r[2] == "missed (in candidates)")

    def pct(n, d):
        return f"{n}/{d} = {100 * n / d:.0f}%" if d else "n/a"

    print()
    print(f"cases: {len(rows)}  (with a feed episode: {len(positives)}, labeled none: {len(none_labeled)})")
    print(f"correct confident matches:     {pct(correct, len(positives))}   (brief: >= 80%)")
    print(f"confident wrong matches:       {wrong}   (brief: 0)")
    print(f"'none' for no-feed shows:      {pct(none_ok, len(no_feed))}   (brief: >= 90%)")
    print(f"not confident, right episode among review candidates: {in_cands}")
    print(f"labeled none but got confident: {sum(1 for r in none_labeled if r[1] == 'confident')}")

    dump = os.environ.get("B3_RESULTS")
    if dump:
        Path(dump).write_text(json.dumps(
            [{"id": c["id"], "category": c["category"], "status": st, "outcome": oc,
              "result": r.to_json() if r else None} for c, st, oc, r in rows], indent=1))

    ok = wrong == 0 and positives and correct / len(positives) >= 0.8 \
        and (not no_feed or none_ok / len(no_feed) >= 0.9)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
