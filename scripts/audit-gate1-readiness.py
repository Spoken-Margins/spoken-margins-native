#!/usr/bin/env python3
import argparse
import json
from collections import Counter
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
INVENTORY = ROOT / "validation" / "gate1-behaviors.json"
ALLOWED_STATUSES = {"ready", "partial", "not_ready"}
REQUIRED_FIELDS = {
    "id",
    "title",
    "specSources",
    "userPath",
    "corePath",
    "durableEffect",
    "positiveEvidence",
    "negativeEvidence",
    "falsificationFindings",
    "status",
}


def load_inventory():
    with INVENTORY.open() as f:
        return json.load(f)


def validate_behavior(behavior):
    errors = []
    missing = REQUIRED_FIELDS - behavior.keys()
    if missing:
        errors.append(f"{behavior.get('id', '<unknown>')}: missing fields {sorted(missing)}")
    if behavior.get("status") not in ALLOWED_STATUSES:
        errors.append(f"{behavior.get('id', '<unknown>')}: invalid status {behavior.get('status')}")
    if not behavior.get("specSources"):
        errors.append(f"{behavior.get('id', '<unknown>')}: no spec source")
    if behavior.get("status") == "ready" and behavior.get("negativeEvidence"):
        errors.append(f"{behavior['id']}: ready behavior still has negative evidence")
    if behavior.get("status") == "ready" and not behavior.get("positiveEvidence"):
        errors.append(f"{behavior['id']}: ready behavior has no positive evidence")
    return errors


def main():
    parser = argparse.ArgumentParser(description="Audit Gate 1 readiness inventory.")
    parser.add_argument("--strict", action="store_true", help="Exit non-zero unless every behavior is ready.")
    args = parser.parse_args()

    inventory = load_inventory()
    behaviors = inventory.get("behaviors", [])
    errors = []
    seen = set()
    for behavior in behaviors:
        behavior_id = behavior.get("id")
        if behavior_id in seen:
            errors.append(f"{behavior_id}: duplicate behavior id")
        seen.add(behavior_id)
        errors.extend(validate_behavior(behavior))

    counts = Counter(behavior.get("status") for behavior in behaviors)
    print(f"Gate: {inventory.get('gate')}")
    print(f"Behaviors: {len(behaviors)}")
    for status in ["ready", "partial", "not_ready"]:
        print(f"{status}: {counts.get(status, 0)}")

    if errors:
        print("\nInventory errors:")
        for error in errors:
            print(f"- {error}")
        raise SystemExit(2)

    if args.strict and (counts.get("partial", 0) or counts.get("not_ready", 0)):
        print("\nGate 1 is NOT ready for product-owner validation.")
        raise SystemExit(1)

    print("\nInventory audit passed.")


if __name__ == "__main__":
    main()
