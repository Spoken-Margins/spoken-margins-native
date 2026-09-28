"""A/B: Kitten nano fp32 with espeak's front end vs the C2 front end.

Renders the three M2 passages plus the harder set, saves WAVs under
out/frontend-ab/<frontend>/, and reports Whisper word errors per passage.
usage: .venv/bin/python frontend/ab_eval.py
"""
import json, re, sys
from pathlib import Path
import soundfile as sf
import jiwer
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
import harness
from engines import kitten
from faster_whisper import WhisperModel

def spoken_ref(text):
    """The words I14 says should be heard: citation markers silent, 'et al.' -> 'and colleagues'."""
    t = re.sub(r"\s*\[\d+(?:\s*[,–-]\s*\d+)*\]", "", text)
    t = re.sub(r"\s*\((?:[A-Z][A-Za-z'’-]+(?: et al\.)?(?:,| and [A-Z][A-Za-z'’-]+,)? \d{4}[a-z]?(?:; )?)+\)", "", t)
    return re.sub(r"\bet al\.", "and colleagues", t)


def norm(s):
    s = s.lower().replace("%", " percent").replace("-", " ")
    s = re.sub(r"(\d),(\d)", r"\1\2", s)
    s = re.sub(r"[^a-z0-9. ]", " ", s)
    s = re.sub(r"\.(?!\d)", " ", s)
    return re.sub(r"\s+", " ", s).strip()

passages = json.loads((ROOT / "passages.json").read_text())["passages"] + \
           json.loads((ROOT / "frontend" / "hard_passages.json").read_text())["passages"]
asr = WhisperModel("small.en", device="cpu", compute_type="int8")
res = {}
for fe in ["espeak", "c2"]:
    eng = kitten.Engine(size="nano-fp32", frontend=fe); eng.load()
    out = ROOT / "out" / "frontend-ab" / fe; out.mkdir(parents=True, exist_ok=True)
    for p in passages:
        wav, m = harness.run(eng, p["text"])
        sf.write(out / f"{p['id']}.wav", wav, eng.sample_rate)
        segs, _ = asr.transcribe(str(out / f"{p['id']}.wav"), beam_size=5, language="en")
        heard = " ".join(s.text for s in segs).strip()
        res.setdefault(p["id"], {})[fe] = {"wer": round(jiwer.wer(norm(spoken_ref(p["text"])), norm(heard)), 3), "heard": heard}
        print(fe, p["id"], res[p["id"]][fe]["wer"], flush=True)
(ROOT / "results" / "linux").mkdir(parents=True, exist_ok=True)
(ROOT / "results" / "linux" / "frontend-ab.json").write_text(json.dumps(res, indent=2, ensure_ascii=False) + "\n")
for pid, r in res.items():
    print(f"{pid:22} espeak {r['espeak']['wer']:.2f}  c2 {r['c2']['wer']:.2f}")
