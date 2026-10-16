#!/usr/bin/env python3
"""Compute tap counts for the jobs in a flow map or a proposal file.

Usage:
  compute-taps.py <flow-map.json | proposal.json> [--markdown] [--write] [--check]

Cost rules (from the map's assumptions): each tap costs 1; an arrow whose
control_kind is "menu item", "context menu", "swipe action" or "system"
(VoiceOver action) costs 2. Edges whose condition mentions DEBUG are left out.
A job's taps = shortest path start -> via_edges... -> via... -> target, plus
final_cost. Optional "via_edges" is a list of edge ids (base or proposal) the
route must take: for each one in order, shortest path to that edge's "from",
then the edge itself (its own cost), then continue from its "to". via_edges
are applied first, then the via screens, then the target (no interleaving).
"""
import heapq
import json
import os
import sys
from collections import OrderedDict

DOUBLE_KINDS = {"menu item", "context menu", "swipe action", "system"}


def load(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f, object_pairs_hook=OrderedDict)


def edge_cost(e):
    return 2 if e.get("control_kind") in DOUBLE_KINDS else 1


def is_debug(e):
    return "debug" in (e.get("condition") or "").lower()


def apply_proposal(base, prop):
    """Return (screens, edges, jobs, start) after applying the proposal."""
    screens = OrderedDict((s["id"], dict(s)) for s in base["screens"])
    edges = [dict(e) for e in base["edges"]]
    dropped = set()
    for s in prop.get("screens", []):
        ch, sid = s.get("change"), s.get("id")
        if ch == "add":
            entry = {k: v for k, v in s.items() if k != "change"}
            screens[sid] = entry
        elif ch in ("remove", "merge"):
            screens.pop(sid, None)
            dropped.add(sid)
        elif ch in ("rename", "move"):
            if sid in screens:
                for k in ("title", "group"):
                    if k in s:
                        screens[sid][k] = s[k]
    edges = [e for e in edges if e["from"] not in dropped and e["to"] not in dropped]
    removed = set(prop.get("removed_edges", []))
    edges = [e for e in edges if e["id"] not in removed]
    edges += [dict(e) for e in prop.get("edges", [])]
    base_jobs = {j["id"]: j for j in base["jobs"]}
    jobs = []
    for j in prop.get("jobs", base["jobs"]):
        merged = dict(base_jobs.get(j["id"], {}))
        merged.update(j)
        jobs.append(merged)
    start = prop.get("start", base["start"])
    return screens, edges, jobs, start


def shortest(edges, src, dst):
    """Cheapest path; on equal cost, prefer the one using more proposed edges."""
    if src == dst:
        return 0, []
    adj = {}
    for e in edges:
        if is_debug(e):
            continue
        adj.setdefault(e["from"], []).append(e)
    best = {src: (0, 0)}
    prev = {}
    heap = [(0, 0, 0, src)]
    n = 0
    while heap:
        cost, old, _, u = heapq.heappop(heap)
        if (cost, old) > best.get(u, (10**9, 0)):
            continue
        if u == dst:
            break
        for e in adj.get(u, []):
            key = (cost + edge_cost(e), old + (0 if e.get("proposed") else 1))
            if key < best.get(e["to"], (10**9, 0)):
                best[e["to"]] = key
                prev[e["to"]] = e
                n += 1
                heapq.heappush(heap, (key[0], key[1], n, e["to"]))
    if dst not in best:
        return None, None
    path = []
    node = dst
    while node != src:
        e = prev[node]
        path.append(e)
        node = e["from"]
    path.reverse()
    return best[dst][0], path


def compute_job(job, edges, default_start):
    start = job.get("start", default_start)
    by_id = {e["id"]: e for e in edges}
    total, route, pos = 0, [], start
    for eid in job.get("via_edges", []):
        e = by_id.get(eid)
        if e is None:
            return None
        c, p = shortest(edges, pos, e["from"])
        if c is None:
            return None
        total += c + edge_cost(e)
        route += [x["control"] for x in p] + [e["control"]]
        pos = e["to"]
    for b in list(job.get("via", [])) + [job["target"]]:
        c, p = shortest(edges, pos, b)
        if c is None:
            return None
        total += c
        route += [e["control"] for e in p]
        pos = b
    return total + job.get("final_cost", 0), route


def compute_all(edges, jobs, start):
    out = OrderedDict()
    for j in jobs:
        r = compute_job(j, edges, start)
        out[j["id"]] = r
    return out


def check(base, prop, screens, edges, jobs, start):
    problems = []
    ids = set(screens)
    seen = set()
    for e in edges:
        if e["id"] in seen:
            problems.append("duplicate edge id %s" % e["id"])
        seen.add(e["id"])
        for k in ("from", "to"):
            if e[k] not in ids:
                problems.append("edge %s %s unknown screen %s" % (e["id"], k, e[k]))
    sids = [s["id"] for s in base["screens"]]
    if prop:
        sids += [s["id"] for s in prop.get("screens", []) if s.get("change") == "add"]
    for sid in {x for x in sids if sids.count(x) > 1}:
        problems.append("duplicate screen id %s" % sid)
    if prop:
        base_edge_ids = {e["id"] for e in base["edges"]}
        for e in prop.get("edges", []):
            if e.get("proposed") is not True:
                problems.append('proposal edge %s lacks "proposed": true' % e.get("id"))
            if e["id"] in base_edge_ids:
                problems.append("proposal edge id %s collides with a base edge" % e["id"])
        for rid in prop.get("removed_edges", []):
            if rid not in base_edge_ids:
                problems.append("removed_edges id %s not in base" % rid)
    eids = {e["id"] for e in edges}
    for j in jobs:
        for x in j.get("via_edges", []):
            if x not in eids:
                problems.append("job %s via_edges unknown edge %s" % (j["id"], x))
        for s in [j.get("start", start)] + list(j.get("via", [])) + [j["target"]]:
            if s not in ids:
                problems.append("job %s refers to unknown screen %s" % (j["id"], s))
    for jid, r in compute_all(edges, jobs, start).items():
        if r is None:
            problems.append("UNREACHABLE job %s" % jid)
    return problems


def table(rows, headers):
    widths = [max(len(str(r[i])) for r in [headers] + rows) for i in range(len(headers))]
    lines = ["  ".join(str(c).ljust(w) for c, w in zip(r, widths)).rstrip() for r in [headers] + rows]
    return "\n".join(lines[:1] + ["  ".join("-" * w for w in widths)] + lines[1:])


def main(argv):
    flags = {a for a in argv if a.startswith("--")}
    args = [a for a in argv if not a.startswith("--")]
    if len(args) != 1 or flags - {"--markdown", "--write", "--check"}:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    path = args[0]
    doc = load(path)
    is_prop = "base" in doc
    if is_prop:
        base_path = os.path.join(os.path.dirname(os.path.abspath(path)), doc["base"])
        base = load(base_path)
        screens, edges, jobs, start = apply_proposal(base, doc)
    else:
        base, doc_prop = doc, None
        screens = OrderedDict((s["id"], s) for s in base["screens"])
        edges, jobs, start = base["edges"], base["jobs"], base["start"]

    if "--check" in flags:
        problems = check(base, doc if is_prop else None, screens, edges, jobs, start)
        for p in problems:
            print(p)
        if problems:
            return 1
        print("OK: %d screens, %d edges, %d jobs" % (len(screens), len(edges), len(jobs)))
        return 0

    result = compute_all(edges, jobs, start)
    bad = [jid for jid, r in result.items() if r is None]
    for jid in bad:
        print("UNREACHABLE %s" % jid, file=sys.stderr)

    if is_prop:
        bscreens = {s["id"]: s for s in base["screens"]}
        asbuilt = compute_all(base["edges"], base["jobs"], base["start"])
        rows = []
        md = []
        for j in jobs:
            r = result[j["id"]]
            ab = asbuilt.get(j["id"])
            abn = ab[0] if ab else None
            pn = r[0] if r else "UNREACHABLE"
            route = " > ".join(r[1]) if r else ""
            rows.append([j["id"], j["name"], pn, abn if abn is not None else "-", route, j.get("final_cost", 0)])
            md.append("| %s | %s | %s | %s |" % (j["name"], abn if abn is not None else "-", pn, route.replace("|", "\\|")))
        if "--markdown" in flags:
            print("| Job | As built | Proposed | Route |\n| --- | --- | --- | --- |")
            print("\n".join(md))
        else:
            print(table(rows, ["job", "name", "taps", "as built", "route", "final_cost"]))
        if "--write" in flags:
            if bad:
                print("not writing: unreachable jobs", file=sys.stderr)
                return 1
            for pj in doc.get("jobs", []):
                r = result[pj["id"]]
                ab = asbuilt.get(pj["id"])
                pj["taps"] = OrderedDict([("as_built", ab[0] if ab else None), ("proposed", r[0]), ("route", r[1])])
            with open(path, "w", encoding="utf-8") as f:
                json.dump(doc, f, indent=1, ensure_ascii=False)
                f.write("\n")
            print("wrote taps into %s" % path, file=sys.stderr)
    else:
        if "--write" in flags:
            print("--write applies to proposal files only", file=sys.stderr)
            return 2
        rows, md = [], []
        for j in jobs:
            r = result[j["id"]]
            pn = r[0] if r else "UNREACHABLE"
            route = " > ".join(r[1]) if r else ""
            rows.append([j["id"], j["name"], pn, route, j.get("final_cost", 0)])
            md.append("| %s | %s | %s | %s |" % (j["name"], pn, pn, route.replace("|", "\\|")))
        if "--markdown" in flags:
            print("| Job | As built | Proposed | Route |\n| --- | --- | --- | --- |")
            print("\n".join(md))
        else:
            print(table(rows, ["job", "name", "taps", "route", "final_cost"]))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
