#!/usr/bin/env python3
"""Put captures of the real screens on the flow map (#5280).

A capture run saves screenshots named `flowmap-<screen id>` or `flowmap-<screen id>--<variant>`: the J12 scripted
journey on a test simulator (`flowMapCapture` in J12SharingLoopJourneyUITests, attachments under a cut's
`journeys/xcode-tests-probation-attachments/`) and the headless browser run of the web listener and the join page
(`npm run capture:flow-map` in Web/). This script copies each into Design/flow-map/captures/ as a small JPEG and
records on the screen the file, the commit the run was taken at and which run it was. A step that failed is marked
broken with what was seen, so the map does not wait for a full pass.

    python3 scripts/flow-map-captures.py --from DIR --commit SHA --run "J12 scripted journey, test simulator"
    python3 scripts/flow-map-captures.py --from DIR --commit SHA --run "..." --broken 'WebArrivalPreview=Spinner never ended'

Only test simulators and fixtures make captures; never a real Library.
"""
import argparse
import datetime
import json
import re
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MAP = ROOT / "Design/flow-map/flow-map.json"
CAPTURES = MAP.parent / "captures"
# XCTest exports an attachment as <name>_<n>_<UUID>.<ext>; Playwright writes <name>.png.
NAME = re.compile(r"flowmap-([A-Za-z][A-Za-z0-9_.]*?)(?:--([a-z0-9-]+))?(?:_\d+_[0-9A-Fa-f-]{36})?\.(?:png|jpe?g)$")
WIDTH = 390


def find(source):
    """{(screen id, variant or None): newest path} for every capture under source."""
    found = {}
    for path in sorted(source.rglob("flowmap-*")):
        match = NAME.search(path.name)
        if match:
            key = (match.group(1), match.group(2))
            if key not in found or path.stat().st_mtime > found[key].stat().st_mtime:
                found[key] = path
    return found


def shrink(src, dst):
    """A JPEG at most WIDTH wide; sips on a Mac, else Pillow, else the file as it is (then it keeps its own type)."""
    dst.parent.mkdir(parents=True, exist_ok=True)
    if shutil.which("sips"):
        result = subprocess.run(["sips", "-s", "format", "jpeg", "-s", "formatOptions", "70", "--resampleWidth", str(WIDTH),
                                 str(src), "--out", str(dst)], capture_output=True, text=True)
        if result.returncode == 0:
            return dst
    try:
        from PIL import Image
    except ImportError:
        kept = dst.with_suffix(src.suffix.lower())
        dst.unlink(missing_ok=True)  # an older JPEG of this screen would otherwise sit beside the new picture
        shutil.copyfile(src, kept)
        return kept
    with Image.open(src) as image:
        image = image.convert("RGB")
        if image.width > WIDTH:
            image = image.resize((WIDTH, round(image.height * WIDTH / image.width)))
        image.save(dst, "JPEG", quality=70)
    return dst


def apply(flow, found, commit, run, broken, today, write_file):
    """Record the captures on the map's screens. Returns (recorded, unknown ids)."""
    screens = {s["id"]: s for s in flow["screens"]}
    recorded, unknown = [], sorted({sid for sid, _ in found if sid not in screens} | (set(broken) - set(screens)))
    for (sid, variant), path in sorted(found.items(), key=lambda kv: (kv[0][0], kv[0][1] or "")):
        if sid not in screens:
            continue
        stem = sid + (f"--{variant}" if variant else "")
        name = write_file(path, CAPTURES / f"{stem}.jpg").name
        capture = screens[sid].setdefault("capture", {})
        entry = {"file": f"captures/{name}", "commit": commit, "run": run, "taken": today}
        if variant:
            capture.setdefault("status", "pending")
            capture["variants"] = [v for v in capture.get("variants", []) if v.get("name") != variant]
            capture["variants"].append(dict(entry, name=variant))
        else:
            capture.update(entry)
            capture["status"] = "pass"
            capture.pop("seen", None)
            capture.pop("why", None)
        recorded.append(stem)
    for sid, seen in broken.items():
        if sid in screens:
            capture = screens[sid].setdefault("capture", {})
            if not any(key == (sid, None) for key in found):
                capture.pop("file", None)  # an older picture was not taken at this commit
            capture.update({"status": "broken", "seen": seen, "commit": commit, "run": run, "taken": today})
            capture.pop("why", None)
            recorded.append(f"{sid} (broken)")
    return recorded, unknown


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--from", dest="source", type=Path, required=True)
    parser.add_argument("--commit", required=True, help="the commit the run was taken at")
    parser.add_argument("--run", required=True, help='which run, e.g. "J12 scripted journey, test simulator"')
    parser.add_argument("--broken", action="append", default=[], metavar="SCREEN=SEEN")
    parser.add_argument("--map", type=Path, default=MAP, help=argparse.SUPPRESS)
    args = parser.parse_args(argv)

    if bad := [item for item in args.broken if "=" not in item]:
        parser.error(f"--broken takes SCREEN=WHAT WAS SEEN, not {bad[0]!r}")
    broken = dict(item.split("=", 1) for item in args.broken)
    flow = json.loads(args.map.read_text(encoding="utf-8"))
    found = find(args.source)
    today = datetime.date.today().isoformat()
    recorded, unknown = apply(flow, found, args.commit, args.run, broken, today, shrink)
    args.map.write_text(json.dumps(flow, indent=1, ensure_ascii=False) + "\n", encoding="utf-8")
    print(f"recorded {len(recorded)}: {', '.join(recorded) or 'none'}")
    if unknown:
        print(f"not on the map (add the screen or fix the name): {', '.join(unknown)}")
    return 1 if unknown or not recorded else 0


if __name__ == "__main__":
    sys.exit(main())
