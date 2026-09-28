#!/usr/bin/env python3
"""Merge apps/*.json into comparison.json after validating every record.

Usage: python3 research/G2/comparison/scripts/build.py
Exits non-zero, writing nothing, if any record fails validation.
"""
import json
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).parent))
from validate import validate_app  # noqa: E402

ROOT = pathlib.Path(__file__).resolve().parents[1]


def main() -> int:
    apps, errors = [], []
    for path in sorted((ROOT / "apps").glob("*.json")):
        record = json.loads(path.read_text())
        errors += [f"{path.name}: {e}" for e in validate_app(record, path.stem)]
        apps.append(record)
    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1
    checked = sorted({s["checked"] for a in apps for c in a["claims"].values() for s in c["sources"]})
    out = {
        "about": "Sourced comparison of apps Spoken Margins' early adopters use now. Built from apps/*.json; edit those, not this file.",
        "oldest_check": checked[0],
        "newest_check": checked[-1],
        "apps": apps,
    }
    (ROOT.parent / "comparison.json").write_text(json.dumps(out, indent=2, ensure_ascii=False) + "\n")
    print(f"wrote comparison.json: {len(apps)} apps, checks {checked[0]}..{checked[-1]}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
