"""Turn a mapbench results JSON into Markdown tables (#2075).

Usage: python3 -I summarize.py results-*.json
Prints to stdout. Reads only numbers; there is no transcript text in the input.
"""
import json
import statistics as st
import sys


def mean(xs):
    xs = [x for x in xs if x is not None]
    return st.mean(xs) if xs else float("nan")


def incomplete(c):
    """Stage 2 stopped before the whole-map check ran (for example, the budget
    cap was reached), so the scene pass counts are not valid. The breaks are."""
    return c["scenes"] > 0 and c["wholeMapCheck"] == ""


def groups(eps):
    yield "all", eps
    for lang in sorted({e["language"] for e in eps}):
        yield lang, [e for e in eps if e["language"] == lang]


def main(path):
    d = json.load(open(path))
    eps = d["episodes"]
    run = d["run"]
    print(f"Run: {run}\n")
    print(f"Episodes: {len(eps)} ({', '.join(f'{k} {len(v)}' for k, v in groups(eps) if k != 'all')})\n")

    print("## Code only (B) and the uniform floor, mean F1\n")
    print("| method | min/scene | all @30s | all @60s | en @30s | de @30s | scenes vs chapters |")
    print("|---|---|---|---|---|---|---|")
    rows = {}
    for e in eps:
        for b in e["b"] + list(e["uniform"].values()):
            rows.setdefault((b["variant"], b["minutesPerScene"]), []).append((e, b))
    for (v, m), items in sorted(rows.items()):
        def f(lang, key):
            return mean([b[key]["f1"] for e, b in items if lang in ("all", e["language"])])
        ratio = mean([b["k"] / max(1, len(e["chapterStartsMs"])) for e, b in items])
        print(f"| {v} | {m:g} | {f('all','at30s'):.2f} | {f('all','at60s'):.2f} | {f('en','at30s'):.2f} | {f('de','at30s'):.2f} | {ratio:.2f} |")

    with_a = [e for e in eps if e.get("a")]
    if with_a:
        print("\n## A: the server's worker today\n")
        print("| episode | lang | min | chapters | made | attempts | merged | replaced | scenes | F1@30 | F1@60 | cost $ | s | failures |")
        print("|---|---|---|---|---|---|---|---|---|---|---|---|---|---|")
        for e in with_a:
            a = e["a"]
            cost = sum(c["microUSD"] for c in (a.get("calls") or [])) / 1e6
            secs = a["wallMs"] / 1000
            fails = "; ".join(a.get("failures") or []) or a.get("refusedAtUpload", "")
            print(f"| {e['slug']} | {e['language']} | {e['minutes']:.0f} | {len(e['chapterStartsMs'])} | {a['made']} | {a['attempts']} | {a['mergedScenes']} | {a['replacedSummaries']} | {a['scenes']} | {e['aAt30s']['f1']:.2f} | {e['aAt60s']['f1']:.2f} | {cost:.4f} | {secs:.0f} | {fails} |")
        for lang, g in groups(with_a):
            made = [e for e in g if e["a"]["made"]]
            print(f"\n**{lang}:** made {len(made)}/{len(g)}, first try {sum(e['a']['firstTry'] for e in g)}/{len(g)}, "
                  f"repaired {sum(1 for e in g if e['a']['mergedScenes'] or e['a']['replacedSummaries'])}, "
                  f"mean F1@30 {mean([e['aAt30s']['f1'] for e in g]):.2f} (failed maps count as 0), "
                  f"mean cost ${mean([sum(c['microUSD'] for c in (e["a"].get("calls") or []))/1e6 for e in g]):.4f}")

    efforts = sorted({k for e in eps for k in (e.get("c") or {})})
    for eff in efforts:
        g_all = [e for e in eps if eff in (e.get("c") or {})]
        print(f"\n## C at {eff} effort: Haiku picks breaks, then writes each scene\n")
        print("| episode | lang | min | chapters | K | picked | F1@30 | F1@60 | scenes passing | map check | calls | cost $ | s |")
        print("|---|---|---|---|---|---|---|---|---|---|---|---|---|")
        for e in g_all:
            c = e["c"][eff]
            cost = sum(x["microUSD"] for x in c["calls"]) / 1e6
            passing, check = f"{c['scenesPassingChecks']}/{c['scenes']}", c["wholeMapCheck"]
            if incomplete(c):
                passing, check = "n/a", "stage 2 incomplete"
            print(f"| {e['slug']} | {e['language']} | {e['minutes']:.0f} | {len(e['chapterStartsMs'])} | {c['k']} | {c['picked']} | {c['at30s']['f1']:.2f} | {c['at60s']['f1']:.2f} | {passing} | {check} | {len(c['calls'])} | {cost:.4f} | {c['wallMs']/1000:.0f} |")
        for lang, g in groups(g_all):
            cs = [e["c"][eff] for e in g if not incomplete(e["c"][eff])]
            left_out = [e["slug"] for e in g if incomplete(e["c"][eff])]
            sc = sum(c["scenes"] for c in cs)
            fails = {}
            for c in cs:
                for f in c.get("sceneFailures") or []:
                    fails[f] = fails.get(f, 0) + 1
            print(f"\n**{lang}:** mean F1@30 {mean([e['c'][eff]['at30s']['f1'] for e in g]):.2f}, @60 {mean([e['c'][eff]['at60s']['f1'] for e in g]):.2f}; "
                  f"scenes passing {sum(c['scenesPassingChecks'] for c in cs)}/{sc}; failures {fails or 'none'}; "
                  f"whole map pass {sum(c['wholeMapCheck']=='pass' for c in cs)}, repaired {sum(c['wholeMapCheck'].startswith('repaired') for c in cs)}, refused {sum(not (c['wholeMapCheck']=='pass' or c['wholeMapCheck'].startswith('repaired')) for c in cs)}; "
                  f"mean cost ${mean([sum(x['microUSD'] for x in c['calls'])/1e6 for c in cs]):.4f}"
                  + (f" (F1 counts all {len(g)}; pass counts and cost leave out {', '.join(left_out)}, stage 2 incomplete)" if left_out else ""))

    total = sum(x["microUSD"] for e in eps for x in ((e.get("a") or {}).get("calls") or []))
    total += sum(x["microUSD"] for e in eps for c in (e.get("c") or {}).values() for x in c["calls"])
    print(f"\nModel spend in this file's call records at the server's prices: ${total/1e6:.4f}")


if __name__ == "__main__":
    for p in sys.argv[1:]:
        main(p)
