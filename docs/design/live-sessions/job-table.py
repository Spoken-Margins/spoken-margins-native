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

A second table, "Beat Kindle" (#2710), sets each job that has a "sitting_setup" entry against the "reference" app's own
note: actions per Margin, and how many Margins a sitting needs before the per-sitting setup is paid back.
"""
import importlib.util
import math
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


def kindle_rows(prop, result):
    """One row per job in prop["sitting_setup"]["applies_to"]: (job id, name, actions per Margin, Kindle's actions,
    actions saved per Margin against Kindle's low count, Margins per sitting to pay back the sitting setup, Margins
    ever to pay back the once-ever setup or None). Kindle's low count is used so the break-even is the cautious one.
    A job that does not beat Kindle's low count has no break-even (None, None)."""
    ref, setup = prop["reference"], prop["sitting_setup"]
    names = {j["id"]: j["name"] for j in prop["jobs"]}
    rows = []
    for jid in setup["applies_to"]:
        taps = result[jid][0]
        saved = ref["taps_low"] - taps
        if saved > 0:
            sitting = math.ceil(setup["per_sitting_taps"] / saved)
            once = math.ceil(setup["once_ever_taps"] / saved) if jid in setup.get("once_ever_applies_to", []) else None
        else:
            sitting = once = None
        rows.append((jid, names[jid], taps, "%d to %d" % (ref["taps_low"], ref["taps_high"]), saved, sitting, once))
    return rows


def main():
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

    ref = prop["reference"]
    print()
    print("| Job | Actions per Margin | %s | Saved per Margin | Margins per sitting to pay back setup | Margins ever to pay back once-ever setup |" % ref["name"])
    print("| --- | --- | --- | --- | --- | --- |")
    for jid, name, taps, kindle, saved, sitting, once in kindle_rows(prop, result):
        print("| %s | %s | %s, plus typing | %s | %s | %s |" % (
            name, taps, kindle, saved if saved > 0 else "none",
            sitting if sitting is not None else "never", once if once is not None else "n/a"))


if __name__ == "__main__":
    main()
