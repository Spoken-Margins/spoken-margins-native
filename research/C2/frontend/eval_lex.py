"""Phoneme agreement between the dictionary front end and espeak on common words."""
import json, sys, collections, difflib
sys.path.insert(0, "frontend")
from lexmap import misaki_to_espeak

def lev(a, b):
    return 1 - difflib.SequenceMatcher(None, a, b).ratio()

ref = json.load(open("models/frontend/espeak_ref_top20k.json"))
gold = json.load(open(".venv/lib/python3.11/site-packages/misaki/data/us_gold.json"))
def g(w):
    v = gold.get(w)
    return v if isinstance(v, str) else (v or {}).get("DEFAULT") if isinstance(v, dict) else None
pairs = [(w, misaki_to_espeak(g(w), w), r) for w, r in ref.items() if g(w)]
top = pairs[:2000]
for name, ps in [("top 2k", top), ("all", pairs)]:
    print(f"{name}: n={len(ps)} exact={sum(a==b for _,a,b in ps)/len(ps):.3f} mean char distance={sum(lev(a,b) for _,a,b in ps)/len(ps):.3f}")
if "-v" in sys.argv:
    subs = collections.Counter()
    for w, a, b in pairs:
        for op, i1, i2, j1, j2 in difflib.SequenceMatcher(None, a, b).get_opcodes():
            if op != "equal": subs[(a[i1:i2], b[j1:j2])] += 1
    for k, v in subs.most_common(25): print(v, k)
