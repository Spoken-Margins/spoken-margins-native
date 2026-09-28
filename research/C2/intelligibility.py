"""Transcribe every rendered clip with Whisper small.en and report word error rate.

An agent can't listen, so this is the check that each candidate actually
says the passage (and that the Python ports aren't producing garbage). It is
not a naturalness score: the blind listen is. Scientific-passage WER mostly
measures how each front end reads numbers, units and symbols.

usage: .venv/bin/python intelligibility.py   -> results/<host>/intelligibility.json
"""
import json
import platform
import re
from pathlib import Path

import jiwer
from faster_whisper import WhisperModel

ROOT = Path(__file__).resolve().parent
ONES = "zero one two three four five six seven eight nine".split()


def norm(s):
    s = s.lower().replace("%", " percent").replace("-", " ")
    s = re.sub(r"(\d),(\d)", r"\1\2", s)
    s = re.sub(r"[^a-z0-9. ]", " ", s)
    s = re.sub(r"\.(?!\d)", " ", s)
    return re.sub(r"\s+", " ", s).strip()


m = WhisperModel("small.en", device="cpu", compute_type="int8")
passages = {p["id"]: p["text"] for p in json.loads((ROOT / "passages.json").read_text())["passages"]}
res = {}
for d in sorted((ROOT / "out").iterdir()):
    for pid, text in passages.items():
        f = d / f"{pid}.wav"
        if not f.exists():
            continue
        segs, _ = m.transcribe(str(f), beam_size=5, language="en")
        hyp = " ".join(s.text for s in segs)
        res.setdefault(d.name, {})[pid] = {"wer": round(jiwer.wer(norm(text), norm(hyp)), 3), "heard": hyp.strip()}
        print(d.name, pid, res[d.name][pid]["wer"])
out = ROOT / "results" / platform.system().lower() / "intelligibility.json"
out.parent.mkdir(parents=True, exist_ok=True)
out.write_text(json.dumps(res, indent=2) + "\n")
