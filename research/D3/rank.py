#!/usr/bin/env python3
"""Transparent source-affinity ranking for the D3 offline experiment."""
import json
import math
from datetime import datetime, timezone
from pathlib import Path


def parse_time(value):
    if not isinstance(value, str):
        raise ValueError("timestamp must be a string")
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as exc:
        raise ValueError("invalid timestamp: %r" % value) from exc
    if parsed.tzinfo is None:
        raise ValueError("timestamp needs a timezone: %r" % value)
    return parsed.astimezone(timezone.utc)


def load_policy(path=None):
    path = Path(path) if path else Path(__file__).with_name("policy.json")
    with path.open(encoding="utf-8") as handle:
        policy = json.load(handle)
    expected = {"listened_share", "finish_rate", "margin_count", "share_count", "dismiss_rate"}
    if not isinstance(policy.get("weights"), dict) or set(policy["weights"]) != expected:
        raise ValueError("policy weights must be exactly: " + ", ".join(sorted(expected)))
    if float(policy.get("recency_half_life_days", 0)) <= 0:
        raise ValueError("recency_half_life_days must be positive")
    for name, value in policy["weights"].items():
        if not isinstance(value, (int, float)):
            raise ValueError("weight %s must be numeric" % name)
    return policy


def source_features(events):
    """Aggregate only the events supplied by the caller (the leakage boundary)."""
    by_source = {}
    items = {}
    for event in events:
        source_id = event["source"]["id"]
        state = by_source.setdefault(source_id, {"listened": 0.0, "duration": 0.0,
            "finished": set(), "margins": 0, "shares": 0, "dismissed": set(), "seen": set()})
        item = event.get("item")
        if item:
            item_id = item["id"]
            state["seen"].add(item_id)
            # item_published rows may lack a duration the playing item knows; keep the largest.
            items[item_id] = max(items.get(item_id, 0), item.get("duration_seconds") or 0)
            if event["event"] == "listened":
                state["listened"] += event["seconds"]
            elif event["event"] == "finish":
                state["finished"].add(item_id)
            elif event["event"] == "margin":
                state["margins"] += 1
            elif event["event"] == "share":
                state["shares"] += 1
            elif event["event"] == "dismiss":
                state["dismissed"].add(item_id)
    result = {}
    for source_id, state in by_source.items():
        durations = sum(items[item] for item in state["seen"] if items[item] > 0)
        denominator = max(1, len(state["seen"]))
        result[source_id] = {
            "listened_share": min(1.0, state["listened"] / durations) if durations else 0.0,
            "finish_rate": len(state["finished"]) / denominator,
            "margin_count": state["margins"],
            "share_count": state["shares"],
            "dismiss_rate": len(state["dismissed"]) / denominator,
        }
    return result


def score_item(item_event, as_of, features, policy):
    """Return (score, one plain-language reason)."""
    item = item_event["item"]
    age = max(0.0, (as_of - parse_time(item["published_at"])).total_seconds() / 86400)
    recency = math.exp(-math.log(2) * age / float(policy["recency_half_life_days"]))
    source = item_event["source"]
    values = features.get(source["id"], {})
    contributions = {name: policy["weights"][name] * values.get(name, 0) for name in policy["weights"]}
    score = recency + sum(contributions.values())
    if not any(values.values()):
        return score, "high because it was published recently"
    top = max(contributions, key=lambda name: abs(contributions[name]))
    title = source["title"]
    templates = {
        "listened_share": "high because you listen to much of %s" % title,
        "finish_rate": "high because you often finish %s" % title,
        "margin_count": "high because you've made %d Margins on %s" % (values[top], title),
        "share_count": "high because you've shared %d items from %s" % (values[top], title),
        "dismiss_rate": "low because you often dismiss %s" % title,
    }
    return score, templates[top]


def rank_items(items, as_of, history, policy):
    features = source_features(history)
    scored = []
    for event in items:
        score, reason = score_item(event, as_of, features, policy)
        scored.append({"item": event, "score": score, "reason": reason})
    return sorted(scored, key=lambda row: (row["score"], parse_time(row["item"]["item"]["published_at"]),
                                           row["item"]["item"]["id"]), reverse=True)
