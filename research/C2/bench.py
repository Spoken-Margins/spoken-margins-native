"""Benchmark one engine on the three passages; write WAVs and a JSON result.

usage: .venv/bin/python bench.py <engine[:k=v,...]> [--threads N] [--label NAME] [--no-audio]
"""
import argparse
import json
import platform
import time
from pathlib import Path

import numpy as np
import soundfile as sf

import harness

p = argparse.ArgumentParser()
p.add_argument("engine")
p.add_argument("--threads", type=int, default=4)
p.add_argument("--label")
p.add_argument("--no-audio", action="store_true")
p.add_argument("--repeats", type=int, default=2)
a = p.parse_args()

eng = harness.load_engine(a.engine, a.threads)
t = time.perf_counter()
eng.load()
load_s = time.perf_counter() - t
label = a.label or eng.name
passages = json.loads((harness.ROOT / "passages.json").read_text())["passages"]
eng.synth("Warm up.")  # first-call graph setup is not what the listener waits for mid-session
out = harness.ROOT / "out" / label
out.mkdir(parents=True, exist_ok=True)
res = {"engine": label, "threads": a.threads, "cpu": platform.processor() or platform.machine(),
       "load_s": round(load_s, 2), "passages": {}}
for ps in passages:
    best = None
    for _ in range(a.repeats):
        wav, m = harness.run(eng, ps["text"])
        if best is None or m["render_s"] < best[1]["render_s"]:
            best = (wav, m)
    if hasattr(eng, "stream_ttfa"):
        first = harness.chunk_text(ps["text"])[0]
        best[1]["stream_ttfa_s"] = round(min(eng.stream_ttfa(first) for _ in range(2)), 3)
    res["passages"][ps["id"]] = best[1]
    if not a.no_audio:
        peak = float(np.max(np.abs(best[0]))) or 1.0
        sf.write(out / f"{ps['id']}.wav", best[0] / max(peak, 1.0), eng.sample_rate)
tot_r = sum(v["render_s"] for v in res["passages"].values())
tot_a = sum(v["audio_s"] for v in res["passages"].values())
res["rtf"] = round(tot_r / tot_a, 3)
res["speed_x"] = round(tot_a / tot_r, 2)
res["ttfa_s_median"] = sorted(v["ttfa_s"] for v in res["passages"].values())[1]
(harness.ROOT / "results").mkdir(exist_ok=True)
(harness.ROOT / "results" / f"{label}.t{a.threads}.json").write_text(json.dumps(res, indent=2) + "\n")
print(json.dumps(res, indent=2))
