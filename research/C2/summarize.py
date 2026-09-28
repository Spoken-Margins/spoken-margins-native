"""Print the comparison table (Markdown) from results/<host>/*.json and candidates.json.

usage: .venv/bin/python summarize.py [host]   (host defaults to this machine's OS: linux or darwin)
"""
import json
import platform
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
host = sys.argv[1] if len(sys.argv) > 1 else platform.system().lower()
R = ROOT / "results" / host
C = json.loads((ROOT / "candidates.json").read_text())
words = {p["id"]: len(p["text"].split()) for p in json.loads((ROOT / "passages.json").read_text())["passages"]}


def load(label, t):
    f = R / f"{label}.t{t}.json"
    return json.loads(f.read_text()) if f.exists() else None


print(f"| Candidate | Speed ×RT, 4 threads | Speed ×RT, 1 thread | First audio, s (4 thr) | Natural pace, wpm | Added app size | License verdict |")
print("| --- | ---: | ---: | ---: | ---: | ---: | --- |")
for c in C:
    r4, r1 = load(c["label"], 4), load(c["label"], 1)
    sp4 = f"{r4['speed_x']:.1f}" if r4 else "—"
    sp1 = f"{r1['speed_x']:.1f}" if r1 else "—"
    if r4:
        tt = r4["ttfa_s_median"]
        st = [v.get("stream_ttfa_s") for v in r4["passages"].values() if v.get("stream_ttfa_s")]
        ttfa = f"{tt:.2f}" + (f" (stream {sorted(st)[len(st)//2]:.2f})" if st else "")
        a = sum(v["audio_s"] - 0.25 * (v["chunks"] - 1) for v in r4["passages"].values())
        wpm = f"{sum(words.values()) / a * 60:.0f}"
    else:
        ttfa = wpm = "—"
    print(f"| {c['name']} | {sp4} | {sp1} | {ttfa} | {wpm} | {c['size']} | {c['verdict']} |")
