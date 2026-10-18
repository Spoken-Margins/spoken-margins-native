#!/usr/bin/env python3
"""Check Design/flow-map/flow-map.json against the app's Swift sources.

The flow map lists every way a listener moves between screens. Each arrow
cites a file, a line and an exact piece of that line (its anchor). This
script fails when an anchor is gone from its file, so the map can't quietly
drift from the code. It also lists navigation calls in the code that no
arrow covers, so new screens and sheets get mapped.

    python3 scripts/flow-map-check.py            # report; exit 1 if an anchor is gone
    python3 scripts/flow-map-check.py --fix-lines  # rewrite moved line numbers in place
    python3 scripts/flow-map-check.py --strict     # also exit 1 on uncovered calls
"""
import argparse
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MAP = ROOT / "Design/flow-map/flow-map.json"
SOURCES = ROOT / "App/SpokenMarginsApp/Sources/SpokenMarginsApp"

# Calls that open another screen, sheet, dialog or system surface.
NAV_PATTERN = re.compile(
    r"NavigationLink|\.sheet\(|\.fullScreenCover\(|\.popover\(|\.confirmationDialog\("
    r"|\.navigationDestination\(|\.tabItem|\.fileImporter\(|\.fileExporter\(|ShareLink\("
    r"|model\.open[A-Z]\w*\(|navigation\.(?:push|present)\("
)
# A covered line is within this many lines of an arrow's trigger or presenter.
NEAR = 6


def load_lines(cache, name):
    if name not in cache:
        path = SOURCES / name
        cache[name] = path.read_text().splitlines() if path.exists() else None
    return cache[name]


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--fix-lines", action="store_true")
    parser.add_argument("--strict", action="store_true")
    args = parser.parse_args()

    flow = json.loads(MAP.read_text())
    cache = {}
    missing, moved = [], []
    covered = {}
    for edge in flow["edges"]:
        lines = load_lines(cache, edge["file"])
        anchor = edge["anchor"]
        if lines is None:
            missing.append((edge, "file not found"))
            continue
        line = edge["line"]
        if 0 < line <= len(lines) and anchor in lines[line - 1]:
            found = line
        else:
            hits = [i + 1 for i, text in enumerate(lines) if anchor in text]
            if not hits:
                missing.append((edge, "anchor not in file"))
                continue
            found = min(hits, key=lambda h: abs(h - line))
            moved.append((edge, found))
            if args.fix_lines:
                edge["line"] = found
        for at in (found, edge.get("present_line")):
            if at:
                covered.setdefault(edge["file"], set()).update(range(at - NEAR, at + NEAR + 1))

    uncovered = []
    for path in sorted(SOURCES.rglob("*.swift")):
        name = str(path.relative_to(SOURCES))
        near = covered.get(name, set())
        for number, text in enumerate(load_lines(cache, name) or [], 1):
            if text.lstrip().startswith("//") or not NAV_PATTERN.search(text):
                continue
            if number not in near:
                uncovered.append(f"{name}:{number}: {text.strip()[:90]}")

    if args.fix_lines and moved:
        MAP.write_text(json.dumps(flow, indent=1, ensure_ascii=False) + "\n")

    print(f"{len(flow['edges'])} arrows, {len(flow['screens'])} screens, {len(flow.get('jobs', []))} jobs")
    print(f"moved: {len(moved)}{' (line numbers rewritten)' if args.fix_lines and moved else ''}")
    for edge, found in moved[:20]:
        print(f"  {edge['file']}:{edge['line']} -> {found}  {edge['control']}")
    print(f"gone: {len(missing)}")
    for edge, why in missing:
        print(f"  {edge['file']}:{edge['line']}  {edge['control']}  ({why}: {edge['anchor']!r})")
    print(f"uncovered navigation calls: {len(uncovered)}")
    for item in uncovered[:40]:
        print(f"  {item}")
    if len(uncovered) > 40:
        print(f"  ... and {len(uncovered) - 40} more")
    return 1 if missing or (args.strict and uncovered) else 0


if __name__ == "__main__":
    sys.exit(main())
