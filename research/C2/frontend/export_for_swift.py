"""Export what the Swift port needs, and reference vectors to check it against.

Writes into App/SpokenMarginsApp/Resources/Kitten/ (committed; regenerate any time, or point C2_KITTEN_EXPORT elsewhere):
  lexicon.tsv         word<TAB>espeak-style IPA (misaki gold + CMUdict, already mapped), sorted by UTF-8 bytes
  g2p_weights.bin     neural fallback weights, float32 little-endian, in manifest order
  g2p_weights.json    names, shapes and byte offsets
  voice.f32           the bundled voice's 400 style rows, 256 float32 little-endian each (Kitten "Jasper")
Writes (committed): frontend/test_vectors.json  text -> normalized text -> phonemes -> Kitten ids
                    frontend/test_extra_vectors.json  a seeded spread of words (dictionary, compound, neural, spelled)
                                                      and normalizer inputs, for the Swift port's differential test
Needs the reference data (see frontend.py) and Kitten's voices.npz (C2_KITTEN_VOICES).
"""
import gzip
import json
import os
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
from kitten_symbols import SYMBOLS  # noqa: E402

OUT = Path(os.environ.get("C2_KITTEN_EXPORT", ROOT.parents[1] / "App" / "SpokenMarginsApp" / "Resources" / "Kitten"))
OUT.mkdir(parents=True, exist_ok=True)
fe = FrontEnd()

lex = {}
for w, v in fe.lex.items():
    if isinstance(v, dict):
        v = v.get("DEFAULT") or next(iter(v.values()))
    if v:
        lex[w] = misaki_to_espeak(v, w.lower())   # keys keep their case: Swift looks up exact, then lowercase
for w, phones in fe.cmu.items():
    if w not in lex and re.fullmatch(r"[a-z']+", w):
        lex[w] = espeakify(arpabet_to_ipa(phones), w)
# Sorted by UTF-8 bytes, so the Swift lookup can binary-search the file in place.
text = "".join(f"{w}\t{p}\n" for w, p in sorted(lex.items(), key=lambda kv: kv[0].encode("utf-8")))
(OUT / "lexicon.tsv").write_text(text, encoding="utf-8")
raw = len(text.encode()); gz = len(gzip.compress(text.encode(), 9))
voices = np.load(os.environ["C2_KITTEN_VOICES"])["expr-voice-2-m"].astype("<f4")
assert voices.shape == (400, 256)
(OUT / "voice.f32").write_bytes(voices.tobytes())

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
texts += ["The cat sat on the mat.", "PBS aired it at 9:05.", "Zorblax hydroxyvitamin quincunx.", "Is it 2.5 mg/kg or 25 mg?",
          "In the 1990s, 1284 participants paid $12.50 each; the U.S. budget was $1.2 billion.",
          "Temperatures fell to -5 °C on pages 10-20 of version 4.2.1, filmed in 4K (May, 2020).",
          "The Polish team met in August in St. Louis at 9 a.m. to discuss IT and AI."]
vectors = [{"text": t, "normalized": normalize(t), "phonemes": fe.phonemize(t), "kitten_ids": kitten_ids(fe.phonemize(t))} for t in texts]
words = {w: fe.word(w) for w in ["Zorblax", "hydroxyvitamin", "PBS", "km", "the", "Reykjavik", "Ouagadougou"]}
(HERE / "test_vectors.json").write_text(json.dumps({"sentences": vectors, "words": words,
    "function_words": FUNCTION}, ensure_ascii=False, indent=1) + "\n")
print(f"lexicon: {len(lex)} words, {raw/1e6:.1f} MB raw, {gz/1e6:.1f} MB gzip; g2p weights {off/1e6:.1f} MB; {len(vectors)} vectors")

# A seeded spread beyond the hand-picked vectors: words by the path that pronounces them, and generated
# normalizer inputs. The port was also checked on 8,000 words and 1,100 inputs; this is the part that stays.
import random  # noqa: E402

random.seed(849)
alpha = [k for k in fe.lex if k.isalpha() and k.isascii()]
cmu_words = [k for k in fe.cmu if k.isalpha()]
picked = ["".join(random.choice("abcdefghijklmnopqrstuvwxyz") for _ in range(random.randint(3, 12))) for _ in range(120)]
picked += random.sample(alpha, 80) + random.sample(cmu_words, 80)
picked += [random.choice(cmu_words) + random.choice(cmu_words) for _ in range(60)]
picked += [w.upper() for w in random.sample(cmu_words, 20)] + [w.capitalize() for w in random.sample(cmu_words, 20)]
picked += ["".join(random.choice("BCDFGHKLMNPRSTVWXZ") for _ in range(random.randint(2, 5))) + random.choice(["", "s"]) for _ in range(30)]
picked += [w + "'s" for w in random.sample(cmu_words, 20)] + ["O'Brien", "don't", "I", "A", "a", "X", "Q"]
numbers = ["0", "7", "12", "100", "1,284", "2,500,000", "61.3", "0.001", "1990", "2024", "1066", "4.2.1", "10", "9:05",
           "11:45", "9:00", "123456789012345678901", "007", "3.14159"]
fragments = ["in {n}", "{n} mg/kg", "${n}", "${n} billion", "£{n}", "{n}%", "p < {n}", "p = {n}", "{n}s", "'{n}s", "the {n}th",
             "{n}-{n}", "{n}–{n}", "-{n}", "{n} °C", "{n} h", "{n}K", "{n} km", "{n}µg", "[{n}]", "(Smith {n})",
             "(Smith and Jones, {n}; Lee {n})", "HbA1c {n}", "CO2", "U.S. policy", "Ph.D. student", "St. Louis", "9 a.m.",
             "e.g., this", "Dr. Who", "Fig. {n}", "No. {n}", "95% CI {n}", "{n} vs. {n}", "March 3, {n}", "since {n}",
             "{n} to {n}", "({n})", "α-{n}", "Reykjavík café naïve", "x = y", "a  b   c", "end,", "٣ Arabic digits ٤", "1990s and '90s"]
inputs = [", ".join(random.choice(fragments).replace("{n}", random.choice(numbers)) for _ in range(random.randint(1, 3))) for _ in range(250)]
def safe_word(w):
    try:
        return fe.word(w)
    except KeyError:               # the reference crashes on an apostrophe in a vowel-less word ("hm's"); the port spells around it
        return None


spoken = {w: safe_word(w) for w in picked}
(HERE / "test_extra_vectors.json").write_text(json.dumps({
    "words": {w: p for w, p in spoken.items() if p is not None},
    "normalized": {t: normalize(t) for t in inputs},
}, ensure_ascii=False, indent=0) + "\n")
print(f"extra vectors: {len(picked)} words, {len(inputs)} normalizer inputs")
