#!/usr/bin/env python3
"""Replay an I4 JSONL export without sending it anywhere."""
import argparse
import json
import math
import random
import sys
from collections import defaultdict
from datetime import timedelta
from pathlib import Path

from rank import load_policy, parse_time, rank_items

# i4-engagement.1 is what the app records and exports (Contracts/schemas/i4-engagement.schema.json);
# draft-1 is the synthetic rehearsal's format. Both have the same fields.
SCHEMA_VERSIONS = {"i4-engagement.1", "i4-engagement.draft-1"}
KNOWN_EVENTS = {"item_published", "listened", "margin", "share", "export", "packet_import", "dismiss", "finish"}
ITEM_EVENTS = KNOWN_EVENTS - {"packet_import"}


def load_log(path):
    events = []
    with Path(path).open(encoding="utf-8") as handle:
        for number, line in enumerate(handle, 1):
            try:
                row = json.loads(line)
                if not isinstance(row, dict):
                    raise ValueError("row is not an object")
                if row.get("schema_version") not in SCHEMA_VERSIONS:
                    raise ValueError("unsupported schema_version")
                if row.get("event") not in KNOWN_EVENTS:
                    raise ValueError("unknown event")
                parse_time(row.get("at"))
                source = row.get("source")
                if not isinstance(source, dict) or not all(source.get(k) for k in ("id", "title", "subscription_kind", "content_kind")):
                    raise ValueError("invalid source")
                item = row.get("item")
                if row["event"] in ITEM_EVENTS and (not isinstance(item, dict) or not all(item.get(k) for k in ("id", "title", "published_at"))):
                    raise ValueError("invalid item")
                if item:
                    parse_time(item["published_at"])
                if row["event"] == "listened" and (not isinstance(row.get("seconds"), (int, float)) or row["seconds"] <= 0):
                    raise ValueError("listened.seconds must be positive")
                if row["event"] == "margin" and (row.get("margin_kind") not in {"spoken", "written"} or not isinstance(row.get("length"), int) or row["length"] < 0):
                    raise ValueError("invalid margin")
                events.append(row)
            except (json.JSONDecodeError, ValueError, TypeError) as exc:
                raise ValueError("%s:%d: %s" % (path, number, exc)) from exc
    if not events:
        raise ValueError("%s: log is empty" % path)
    return sorted(events, key=lambda row: parse_time(row["at"]))


def metrics(order, positives):
    flags = [1 if row["item"]["id"] in positives else 0 for row in order]
    dcg = sum(flag / math.log2(index + 2) for index, flag in enumerate(flags[:10]))
    ideal = sum(1 / math.log2(index + 2) for index in range(min(10, sum(flags))))
    ranks = [index + 1 for index, flag in enumerate(flags) if flag]
    return {"ndcg@10": dcg / ideal if ideal else 0.0,
            "precision@5": sum(flags[:5]) / 5.0,
            "mean_positive_rank": sum(ranks) / len(ranks) if ranks else None}


def replay(events, policy):
    publications = [row for row in events if row["event"] == "item_published"]
    start = min(parse_time(row["at"]) for row in publications).replace(hour=0, minute=0, second=0, microsecond=0)
    end = max(parse_time(row["at"]) for row in events).replace(hour=0, minute=0, second=0, microsecond=0)
    samples = []
    day = start
    while day <= end:
        history = [row for row in events if parse_time(row["at"]) < day]
        acted = {row["item"]["id"] for row in history if row.get("item") and row["event"] in {"listened", "margin", "dismiss", "finish"}}
        inbox = [row for row in publications if parse_time(row["item"]["published_at"]) < day and row["item"]["id"] not in acted]
        future = [row for row in events if parse_time(row["at"]) >= day and row.get("item")]
        positives = {row["item"]["id"] for row in future if row["event"] in {"finish", "margin"}}
        positives &= {row["item"]["id"] for row in inbox}
        if inbox and positives:
            newest = sorted(inbox, key=lambda row: (parse_time(row["item"]["published_at"]), row["item"]["id"]), reverse=True)
            scored = [row["item"] for row in rank_items(inbox, day, history, policy)]
            samples.append({"day": day.date().isoformat(), "newest": metrics(newest, positives),
                            "score": metrics(scored, positives)})
        day += timedelta(days=1)
    return samples


def summarize(samples, bootstrap=2000, seed=176):
    names = ("ndcg@10", "precision@5", "mean_positive_rank")
    result = {}
    rng = random.Random(seed)
    for name in names:
        valid = [sample for sample in samples if sample["newest"][name] is not None and sample["score"][name] is not None]
        baseline = sum(s["newest"][name] for s in valid) / len(valid)
        score = sum(s["score"][name] for s in valid) / len(valid)
        deltas = []
        for _ in range(bootstrap):
            draw = [rng.choice(valid) for _ in valid]
            deltas.append(sum(s["score"][name] - s["newest"][name] for s in draw) / len(draw))
        deltas.sort()
        result[name] = (baseline, score, score - baseline,
                        deltas[int(.025 * bootstrap)], deltas[min(bootstrap - 1, int(.975 * bootstrap))])
    return result


def report(samples, summary):
    print("D3 offline ranking replay (%d eligible day(s))" % len(samples))
    print("metric              newest     score     delta       95% bootstrap CI")
    for name, values in summary.items():
        print("%-18s %8.3f  %8.3f  %+8.3f   [%+.3f, %+.3f]" % ((name,) + values))
    print("Higher is better for NDCG/precision; lower is better for mean_positive_rank.")


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("log", help="local I4 JSONL export")
    parser.add_argument("--policy", default=str(Path(__file__).with_name("policy.json")))
    args = parser.parse_args(argv)
    try:
        samples = replay(load_log(args.log), load_policy(args.policy))
        if not samples:
            raise ValueError("no days contain both unplayed items and later positives")
        report(samples, summarize(samples))
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        print("error: %s" % exc, file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
