"""A/B: Kitten nano fp32 with espeak's front end vs the C2 front end.

Renders the three M2 passages plus the harder set RUNS times each (Kitten samples
randomly, so one render per passage is noisy), saves the first render's WAVs under
out/frontend-ab/<frontend>/, and reports the mean Whisper word errors per passage.
usage: .venv/bin/python frontend/ab_eval.py [runs, default 3]
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
RUNS = int(sys.argv[1]) if len(sys.argv) > 1 else 3
res = {}
for fe in ["espeak", "c2"]:
    eng = kitten.Engine(size="nano-fp32", frontend=fe); eng.load()
    out = ROOT / "out" / "frontend-ab" / fe; out.mkdir(parents=True, exist_ok=True)
    for p in passages:
        wers, heards = [], []
        for run in range(RUNS):
            wav, m = harness.run(eng, p["text"])
            path = out / (f"{p['id']}.wav" if run == 0 else f"{p['id']}.run{run}.wav")
            sf.write(path, wav, eng.sample_rate)
            segs, _ = asr.transcribe(str(path), beam_size=5, language="en")
            heard = " ".join(s.text for s in segs).strip()
            wers.append(jiwer.wer(norm(spoken_ref(p["text"])), norm(heard))); heards.append(heard)
        res.setdefault(p["id"], {})[fe] = {"wer": round(sum(wers) / RUNS, 3), "wer_runs": [round(w, 3) for w in wers], "heard": heards[0]}
        print(fe, p["id"], res[p["id"]][fe]["wer_runs"], flush=True)
(ROOT / "results" / "linux").mkdir(parents=True, exist_ok=True)
(ROOT / "results" / "linux" / "frontend-ab.json").write_text(json.dumps(res, indent=2, ensure_ascii=False) + "\n")
for pid, r in res.items():
    print(f"{pid:22} espeak {r['espeak']['wer']:.2f} {r['espeak']['wer_runs']}  c2 {r['c2']['wer']:.2f} {r['c2']['wer_runs']}")
tot = {fe: sum(r[fe]["wer"] for r in res.values()) / len(res) for fe in ("espeak", "c2")}
print(f"mean over passages: espeak {tot['espeak']:.3f}  c2 {tot['c2']:.3f}")
