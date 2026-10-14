"""Whisper word error for rendered Pocket TTS clips (#459), as research/C2/intelligibility.py scores them.

usage: python wer.py <passages.json> <clips.json>
  clips.json: {"p1-narrative": "/path/to/clip.wav", ...}
prints {"p1-narrative": {"wer": 0.016, "heard": "..."}, ...}
needs: pip install faster-whisper jiwer
"""
import json
import re
import sys

import jiwer
from faster_whisper import WhisperModel


def norm(s):
    s = s.lower().replace("%", " percent").replace("-", " ")
    s = re.sub(r"(\d),(\d)", r"\1\2", s)
    s = re.sub(r"[^a-z0-9. ]", " ", s)
    s = re.sub(r"\.(?!\d)", " ", s)
    return re.sub(r"\s+", " ", s).strip()


passages = {p["id"]: p["text"] for p in json.load(open(sys.argv[1]))["passages"]}
clips = json.load(open(sys.argv[2]))
model = WhisperModel("small.en", device="cpu", compute_type="int8")
result = {}
for pid, path in clips.items():
    segments, _ = model.transcribe(path, beam_size=5, language="en")
    heard = " ".join(s.text for s in segments)
    result[pid] = {"wer": round(jiwer.wer(norm(passages[pid]), norm(heard)), 3), "heard": heard.strip()}
print(json.dumps(result))
