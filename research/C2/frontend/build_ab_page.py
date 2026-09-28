"""Build the blind A/B page: Kitten with espeak's front end vs the C2 front end.

Reads out/frontend-ab/<espeak|c2>/<passage>.wav (from ab_eval.py), writes
frontend/listening-ab/index.html, audio/*.mp3 (git-ignored) and answer-key.md.
Which side is X is decided per passage by a seeded coin, so a pattern can't give it away.
"""
import json, random, re, sys
from pathlib import Path
HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
sys.path.insert(0, str(ROOT))
from build_page import loudness_match, to_mp3, PAGE_SR  # same loudness and encoding as the M2 page
import numpy as np, soundfile as sf
from scipy.signal import resample_poly

OUT = HERE / "listening-ab"; AUD = OUT / "audio"; AUD.mkdir(parents=True, exist_ok=True)
passages = json.loads((ROOT / "passages.json").read_text())["passages"] + \
           json.loads((HERE / "hard_passages.json").read_text())["passages"]
rng = random.Random(183)
items, key = [], ["# Front-end A/B answer key", "", "Don't open until you've saved your choices.", "",
                  "| Passage | X | Y |", "| --- | --- | --- |"]
for p in passages:
    sides = ["espeak", "c2"]; rng.shuffle(sides)
    clips = {}
    for label, fe in zip("XY", sides):
        wav, sr = sf.read(ROOT / "out" / "frontend-ab" / fe / f"{p['id']}.wav", dtype="float64")
        if sr != PAGE_SR:
            g = np.gcd(sr, PAGE_SR); wav = resample_poly(wav, PAGE_SR // g, sr // g)
        dst = AUD / f"{p['id']}-{label}.mp3"
        to_mp3(loudness_match(wav), PAGE_SR, dst)
        clips[label] = f"audio/{dst.name}"
    items.append({"id": p["id"], "title": p["title"], "text": p["text"], "clips": clips})
    key.append(f"| {p['title']} | {'espeak front end' if sides[0]=='espeak' else 'new front end'} | {'espeak front end' if sides[1]=='espeak' else 'new front end'} |")
(OUT / "answer-key.md").write_text("\n".join(key) + "\n")
tpl = (HERE / "ab_template.html").read_text()
(OUT / "index.html").write_text(tpl.replace("/*DATA*/null", json.dumps({"items": items})))
print(len(items), "pairs")
