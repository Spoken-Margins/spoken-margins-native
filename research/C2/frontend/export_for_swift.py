"""Export what the Swift port needs, and reference vectors to check it against.

Writes (git-ignored, regenerate any time):
  models/frontend/export/lexicon.tsv       word<TAB>espeak-style IPA (misaki gold + CMUdict, already mapped)
  models/frontend/export/g2p_weights.bin   neural fallback weights, float32 little-endian, in manifest order
  models/frontend/export/g2p_weights.json  names, shapes and byte offsets
Writes (committed): frontend/test_vectors.json  text -> normalized text -> phonemes -> Kitten ids
"""
import gzip
import json
import re
import sys
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(ROOT))
from frontend import FUNCTION, FrontEnd, arpabet_to_ipa  # noqa: E402
from lexmap import espeakify, misaki_to_espeak  # noqa: E402
from normalize import normalize  # noqa: E402
from engines.kitten import SYMBOLS  # noqa: E402

OUT = ROOT / "models" / "frontend" / "export"
OUT.mkdir(parents=True, exist_ok=True)
fe = FrontEnd()

lex = {}
for w, v in fe.lex.items():
    if isinstance(v, dict):
        v = v.get("DEFAULT") or next(iter(v.values()))
    if v and w == w.lower():
        lex[w] = misaki_to_espeak(v, w)
for w, phones in fe.cmu.items():
    if w not in lex and re.fullmatch(r"[a-z']+", w):
        lex[w] = espeakify(arpabet_to_ipa(phones), w)
text = "".join(f"{w}\t{p}\n" for w, p in sorted(lex.items()))
(OUT / "lexicon.tsv").write_text(text, encoding="utf-8")
raw = len(text.encode()); gz = len(gzip.compress(text.encode(), 9))

manifest, off, blob = [], 0, bytearray()
for k, a in fe.neural.w.items():
    b = np.ascontiguousarray(a, dtype="<f4").tobytes()
    manifest.append({"name": k, "shape": list(a.shape), "offset": off, "bytes": len(b)})
    blob += b; off += len(b)
(OUT / "g2p_weights.bin").write_bytes(bytes(blob))
(OUT / "g2p_weights.json").write_text(json.dumps(manifest, indent=1))

def kitten_ids(ps):
    p = " ".join(re.findall(r"\w+|[^\w\s]", ps))
    return [0] + [SYMBOLS[c] for c in p if c in SYMBOLS] + [10, 0]

texts = [p["text"] for p in json.loads((ROOT / "passages.json").read_text())["passages"]]
texts += [p["text"] for p in json.loads((HERE / "hard_passages.json").read_text())["passages"]]
texts += ["The cat sat on the mat.", "PBS aired it at 9:05.", "Zorblax hydroxyvitamin quincunx.", "Is it 2.5 mg/kg or 25 mg?"]
vectors = [{"text": t, "normalized": normalize(t), "phonemes": fe.phonemize(t), "kitten_ids": kitten_ids(fe.phonemize(t))} for t in texts]
words = {w: fe.word(w) for w in ["Zorblax", "hydroxyvitamin", "PBS", "km", "the", "Reykjavik", "Ouagadougou"]}
(HERE / "test_vectors.json").write_text(json.dumps({"sentences": vectors, "words": words,
    "function_words": FUNCTION}, ensure_ascii=False, indent=1) + "\n")
print(f"lexicon: {len(lex)} words, {raw/1e6:.1f} MB raw, {gz/1e6:.1f} MB gzip; g2p weights {off/1e6:.1f} MB; {len(vectors)} vectors")
