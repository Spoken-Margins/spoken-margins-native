#!/usr/bin/env python3
"""Print the live-sessions job table: compute-taps.py's counts plus the extra columns it can't express.

Usage: python3 docs/design/live-sessions/job-table.py

Taps come from Design/proposals/compute-taps.py, unchanged. The extra columns are read from each job's
"extra" and "today" fields, which compute-taps.py ignores:
- Today: counted by hand from the code on main (the base flow map predates live sessions).
- Leaves the other app: whether the other app (the call, the book, the video) leaves the screen.
- Watch: wrist raises and Watch taps or gestures, counted apart from phone taps.
- Voice: spoken commands to Siri.
- Rests on: the device checks in SITUATIONS.md that must pass for the count to hold.
"""
import importlib.util
import os

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, "..", "..", ".."))
spec = importlib.util.spec_from_file_location("compute_taps", os.path.join(ROOT, "Design", "proposals", "compute-taps.py"))
ct = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ct)

prop_path = os.path.join(HERE, "live-sessions.json")
prop = ct.load(prop_path)
base = ct.load(os.path.join(HERE, prop["base"]))
screens, edges, jobs, start = ct.apply_proposal(base, prop)
result = ct.compute_all(edges, jobs, start)

print("| Job | Today | Proposed | Leaves the other app | Watch | Voice | Rests on |")
print("| --- | --- | --- | --- | --- | --- | --- |")
for j in jobs:
    r = result[j["id"]]
    today = j.get("today", {})
    t = today.get("taps")
    extra = j.get("extra", {})
    print("| %s | %s | %s | %s | %s | %s | %s |" % (
        j["name"],
        t if t is not None else "not possible",
        r[0] if r else "UNREACHABLE",
        extra.get("leaves_other_app", ""),
        extra.get("watch", "") or "none",
        extra.get("voice", 0),
        extra.get("checks", "") or "nothing new",
    ))
