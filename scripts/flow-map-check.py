#!/usr/bin/env python3
"""Check Design/flow-map/flow-map.json against the sources it cites, and look up sharing screens.

The flow map lists every way a person moves between screens, in the app and,
for the sharing loop, outside it (Messages, the browser listener, the join
page, TestFlight). Each arrow cites a file, a line and an exact piece of that
line (its anchor). This script fails when an anchor is gone from its file, so
the map can't quietly drift from the code. It also checks the owner's rulings
the map attaches to sharing screens (each quotes docs/decisions.md) and the
captures it names, and lists navigation calls in the app that no arrow covers.

    python3 scripts/flow-map-check.py              # report; exit 1 if an anchor is gone
    python3 scripts/flow-map-check.py --fix-lines  # rewrite moved line numbers in place
    python3 scripts/flow-map-check.py --strict     # also exit 1 on uncovered calls
    python3 scripts/flow-map-check.py --touched App/.../PlaybackScreen.swift Web/src/main.ts
                                                   # the sharing screens these files touch, with neighbours
    python3 scripts/flow-map-check.py --pr         # PR-time: the sharing anchors, then --touched for the diff
"""
import argparse
import json
import os
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MAP = ROOT / "Design/flow-map/flow-map.json"
SOURCES = ROOT / "App/SpokenMarginsApp/Sources/SpokenMarginsApp"
SOURCES_PREFIX = "App/SpokenMarginsApp/Sources/SpokenMarginsApp/"
# A cited file starting with one of these is relative to the repository; any other name is relative to SOURCES.
REPO_RELATIVE = ("App/", "Packages/", "Web/", "Site/", "docs/", "Contracts/", "Design/", "research/")

# Calls that open another screen, sheet, dialog or system surface.
NAV_PATTERN = re.compile(
    r"NavigationLink|\.(?:tracked)?[Ss]heet\(|\.(?:tracked)?[Ff]ullScreenCover\(|\.popover\(|\.confirmationDialog\("
    r"|\.navigationDestination\(|\.tabItem|\.fileImporter\(|\.fileExporter\(|\bShareLink\("
    r"|model\.open[A-Z]\w*\(|navigation\.(?:push|present)\("
)
# A covered line is within this many lines of an arrow's trigger or presenter.
NEAR = 6


def repo_path(name):
    """The repository-relative path of a file the map cites."""
    return name if name.startswith(REPO_RELATIVE) else SOURCES_PREFIX + name


def load_lines(cache, name):
    if name not in cache:
        path = ROOT / repo_path(name)
        cache[name] = path.read_text(encoding="utf-8").splitlines() if path.is_file() else None
    return cache[name]


def find_anchor(cache, item, fix_lines):
    """('ok'|'moved'|'gone', found line or reason) for an item with file, line and anchor."""
    lines = load_lines(cache, item["file"])
    if lines is None:
        return "gone", "file not found"
    anchor, line = item["anchor"], item.get("line") or 0
    if 0 < line <= len(lines) and anchor in lines[line - 1]:
        return "ok", line
    hits = [i + 1 for i, text in enumerate(lines) if anchor in text]
    if not hits:
        return "gone", "anchor not in file"
    found = min(hits, key=lambda h: abs(h - line))
    if fix_lines:
        item["line"] = found
    return "moved", found


def sharing_sets(flow):
    """The sharing screens' ids and the sharing arrows (each marked "sharing": true; Now Playing's mini player is not one)."""
    screens = {s["id"] for s in flow["screens"] if s.get("sharing")}
    edges = [e for e in flow["edges"] if e.get("sharing")]
    return screens, edges


def check(flow, fix_lines=False, only_sharing=False):
    """Check anchors, rulings and captures. Returns (missing, moved, covered, problems)."""
    cache = {}
    missing, moved, problems = [], [], []
    covered = {}
    share_ids, share_edges = sharing_sets(flow)
    edges = share_edges if only_sharing else flow["edges"]
    for edge in edges:
        if not edge.get("file"):
            continue  # a tap on a surface with no code here (Messages, TestFlight): its screens carry the evidence
        status, found = find_anchor(cache, edge, fix_lines)
        if status == "gone":
            missing.append((edge, found))
            continue
        if status == "moved":
            moved.append((edge, found))
        for at in (found, edge.get("present_line")):
            if at:
                covered.setdefault(edge["file"], set()).update(range(at - NEAR, at + NEAR + 1))

    screen_ids = {s["id"] for s in flow["screens"]}
    rulings = {r["id"]: r for r in flow.get("rulings", [])}
    for ruling in rulings.values():
        status, found = find_anchor(cache, ruling, fix_lines)
        if status == "gone":
            problems.append(f"ruling {ruling['id']} ({ruling['date']}): quote gone from {ruling['file']} ({found}: {ruling['anchor']!r})")
        elif status == "moved":
            moved.append((dict(ruling, control=f"ruling {ruling['id']}"), found))
    for item in list(flow["screens"]) + list(flow["edges"]):
        for rid in item.get("rulings", []):
            if rid not in rulings:
                problems.append(f"{item['id']} names unknown ruling {rid}")
    for screen in flow["screens"]:
        if only_sharing and screen["id"] not in share_ids:
            continue
        if screen.get("anchor"):
            status, found = find_anchor(cache, screen, fix_lines)
            if status == "gone":
                missing.append((dict(screen, control=f"screen {screen['id']}"), found))
            elif status == "moved":
                moved.append((dict(screen, control=f"screen {screen['id']}"), found))
        if screen.get("sharing"):
            if not screen.get("surface"):
                problems.append(f"sharing screen {screen['id']} names no surface")
            capture = screen.get("capture")
            if not capture or capture.get("status") not in ("pass", "broken", "pending"):
                problems.append(f"sharing screen {screen['id']} has no capture status (pass, broken or pending)")
            elif capture.get("file") and not (MAP.parent / capture["file"]).is_file():
                problems.append(f"sharing screen {screen['id']} names a missing capture {capture['file']}")
            elif capture["status"] == "pass" and not (capture.get("file") and capture.get("commit")):
                problems.append(f"sharing screen {screen['id']}: a pass capture needs its file and commit")
            elif capture["status"] == "broken" and not capture.get("commit"):
                problems.append(f"sharing screen {screen['id']}: a broken capture needs the commit it failed at")
            elif capture["status"] == "broken" and not capture.get("seen"):
                problems.append(f"sharing screen {screen['id']}: a broken capture says what was seen")
    for edge in flow["edges"]:
        for key in ("from", "to"):
            if edge[key] not in screen_ids:
                problems.append(f"arrow {edge['id']} {key} unknown screen {edge[key]}")
    return missing, moved, covered, problems


def uncovered_calls(covered):
    cache, found = {}, []
    for path in sorted(SOURCES.rglob("*.swift")):
        name = str(path.relative_to(SOURCES))
        near = covered.get(name, set())
        for number, text in enumerate(load_lines(cache, name) or [], 1):
            if text.lstrip().startswith("//") or not NAV_PATTERN.search(text):
                continue
            if number not in near:
                found.append(f"{name}:{number}: {text.strip()[:90]}")
    return found


def touched(flow, paths):
    """Lines describing the sharing screens the changed paths touch, with each one's neighbours and rulings."""
    paths = {p.strip().removeprefix("./") for p in paths if p.strip()}
    share_ids, _ = sharing_sets(flow)
    screens = {s["id"]: s for s in flow["screens"]}
    rulings = {r["id"]: r for r in flow.get("rulings", [])}
    hit_screens, hit_edges = {}, []
    for screen in flow["screens"]:
        if screen["id"] in share_ids and screen.get("file") and repo_path(screen["file"]) in paths:
            hit_screens.setdefault(screen["id"], []).append(f"its view, {repo_path(screen['file'])}")
    for edge in flow["edges"]:
        if edge.get("sharing") and edge.get("file") and repo_path(edge["file"]) in paths:
            hit_edges.append(edge)
            for sid in (edge["from"], edge["to"]):
                if sid in share_ids:
                    hit_screens.setdefault(sid, []).append(f"arrow {edge['id']} {edge['control']!r}")
    if not hit_screens:
        return []

    def ruling_lines(item, indent):
        return [f"{indent}ruling {rid} ({rulings[rid]['date']}, {rulings[rid]['file']}:{rulings[rid]['line']}): {rulings[rid]['summary']}"
                for rid in item.get("rulings", []) if rid in rulings]

    out = [f"Sharing screens touched: {len(hit_screens)}"]
    for sid in sorted(hit_screens):
        screen = screens[sid]
        capture = screen.get("capture") or {}
        out.append(f"- {sid} ({screen['title']}; surface {screen.get('surface', '?')}; capture {capture.get('status', 'none')}"
                   f"{' ' + capture['file'] if capture.get('file') else ''})")
        out.append(f"    via {'; '.join(dict.fromkeys(hit_screens[sid]))}")
        out += ruling_lines(screen, "    ")
        for edge in flow["edges"]:
            if edge["to"] == sid:
                out.append(f"    from {edge['from']}: {edge['control']} [{edge['id']}]")
        for edge in flow["edges"]:
            if edge["from"] == sid:
                out.append(f"    to   {edge['to']}: {edge['control']} [{edge['id']}]")
                out += ruling_lines(edge, "      ")
    jobs = [j for j in flow.get("jobs", []) if set(job_screens(j)) & set(hit_screens)]
    if jobs:
        out.append("Jobs through them: " + "; ".join(f"{j['id']} {j['name']}" for j in jobs))
    return out


def job_screens(job):
    legs = job.get("legs") or [job]
    found = []
    for leg in legs:
        found += [leg.get("start", "")] + list(leg.get("via", [])) + [leg.get("target", "")]
    return [s for s in found if s]


def changed_paths(root=ROOT, environ=None):
    """The PR's changed paths. In CI, the merge commit GitHub checked out against its first parent (a depth-1 checkout
    fetches that parent first); on a developer's machine, this branch against origin/main. None when neither works."""
    environ = os.environ if environ is None else environ

    def git(*args):
        result = subprocess.run(["git", *args], cwd=root, capture_output=True, text=True)
        return result.stdout.split() if result.returncode == 0 else None

    if environ.get("GITHUB_ACTIONS") == "true":
        if git("rev-parse", "--verify", "--quiet", "HEAD^1") is None:
            head = git("rev-parse", "HEAD")
            if head:
                git("fetch", "--no-tags", "--quiet", "--depth=2", "origin", head[0])
        if git("rev-parse", "--verify", "--quiet", "HEAD^1") is None:
            return None
        return git("diff", "--name-only", "HEAD^1", "HEAD")
    base = git("merge-base", "HEAD", "origin/main")
    return git("diff", "--name-only", base[0], "HEAD") if base else None


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--fix-lines", action="store_true")
    parser.add_argument("--strict", action="store_true")
    parser.add_argument("--touched", nargs="+", metavar="PATH", help="changed files (repository-relative)")
    parser.add_argument("--pr", action="store_true", help="check the sharing anchors, then look up the diff's sharing screens")
    parser.add_argument("--map", type=Path, default=MAP, help=argparse.SUPPRESS)
    args = parser.parse_args(argv)

    flow = json.loads(args.map.read_text(encoding="utf-8"))
    if args.touched:
        print("\n".join(touched(flow, args.touched)) or "No sharing screen touched.")
        return 0

    missing, moved, covered, problems = check(flow, fix_lines=args.fix_lines, only_sharing=args.pr)
    if args.fix_lines and moved:
        args.map.write_text(json.dumps(flow, indent=1, ensure_ascii=False) + "\n", encoding="utf-8")

    share_ids, share_edges = sharing_sets(flow)
    if args.pr:
        print(f"sharing loop: {len(share_ids)} screens, {len(share_edges)} arrows; moved: {len(moved)}; gone: {len(missing)}")
    else:
        print(f"{len(flow['edges'])} arrows, {len(flow['screens'])} screens, {len(flow.get('jobs', []))} jobs, "
              f"{len(flow.get('rulings', []))} rulings")
        print(f"moved: {len(moved)}{' (line numbers rewritten)' if args.fix_lines and moved else ''}")
        for edge, found in moved[:20]:
            print(f"  {edge['file']}:{edge['line']} -> {found}  {edge['control']}")
        print(f"gone: {len(missing)}")
    for edge, why in missing:
        print(f"  {edge['file']}:{edge['line']}  {edge['control']}  ({why}: {edge['anchor']!r})")
    print(f"problems: {len(problems)}")
    for problem in problems:
        print(f"  {problem}")
    if args.pr:
        paths = changed_paths()
        if paths is None:
            print("No changed-file list (no merge commit and no origin/main); every sharing anchor was checked above.")
        else:
            print("\n".join(touched(flow, paths)) or f"No sharing screen touched by the {len(paths)} changed files.")
        if missing or problems:
            print("A sharing control moved, was renamed or is gone. Update Design/flow-map/flow-map.json in this PR "
                  "(its README says how), and check the rulings named above before removing or renaming a control.")
        return 1 if missing or problems else 0

    uncovered = uncovered_calls(covered)
    print(f"uncovered navigation calls: {len(uncovered)}")
    for item in uncovered[:40]:
        print(f"  {item}")
    if len(uncovered) > 40:
        print(f"  ... and {len(uncovered) - 40} more")
    return 1 if missing or problems or (args.strict and uncovered) else 0


if __name__ == "__main__":
    sys.exit(main())
