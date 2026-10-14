"""Regenerate Packages/SessionKit/Tests/SessionKitTests/Fixtures/pocket-tokenizer-golden.json (#459).

The Swift tokenizer and text splitter must give the ids and chunks the Python originals give.
This writes those from Python `sentencepiece` and from the export's own `pocket_tts_onnx.py`.

usage: python make_golden.py <folder holding pocket_tts_onnx.py> [weights folder]
  pocket_tts_onnx.py: https://huggingface.co/KevinAHM/pocket-tts-onnx at revision 58a6d00
  weights folder: where fetch_weights.sh put tokenizer.model (default ../models/pocket)
needs: pip install sentencepiece numpy onnxruntime huggingface_hub safetensors
"""
import base64
import json
import sys
from pathlib import Path

import sentencepiece as spm
from sentencepiece import sentencepiece_model_pb2 as pb

here = Path(__file__).resolve().parent
sys.path.insert(0, sys.argv[1])
import pocket_tts_onnx as P  # noqa: E402

weights = Path(sys.argv[2]) if len(sys.argv) > 2 else here.parent / "models" / "pocket"
fixture = here.parents[2] / "Packages/SessionKit/Tests/SessionKitTests/Fixtures/pocket-tokenizer-golden.json"

# The export's splitting methods only need a tokenizer and three settings, not the five networks.
engine = P.PocketTTSOnnx.__new__(P.PocketTTSOnnx)
engine.tokenizer = spm.SentencePieceProcessor()
engine.tokenizer.Load(str(weights / "tokenizer.model"))
engine.remove_semicolons = False
engine.pad_with_spaces_for_short_inputs = False
engine.max_token_per_chunk = 50

token_texts = [
    "Hello, world.",
    "\"Honestly?\" she said.",
    "naïve café — “quoted” … ½ ① 日本語",
    "a  b\tc\nd",
    "x y   z",
    "hello",
    "Dr. Smith's 3.5% rise, i.e. e.g. U.S.A. isn't fine!",
    "ｆｕｌｌｗｉｄｔｈ 😀 emoji",
    "",
    " ",
    "In a randomized, double-blind trial of 1,284 adults (mean age 61.3 years), daily supplementation with 2,000 IU "
    "of vitamin D3 did not reduce the incidence of type 2 diabetes compared with placebo (hazard ratio, 0.88; 95% CI, "
    "0.75 to 1.04; p = 0.12).",
]
chunk_texts = [
    "short one",
    "this has no capital and no stop",
    "Line one.\nLine two!  Third? Fourth...",
    "A long sentence with, many, commas, that keeps going, and going, and going, and going, and going, and going, "
    "on and on, until the model's limit of fifty tokens is passed for sure, no doubt.",
    "One. Two. Three.",
    "Quote: \"Wait!\" he cried; \"stop.\"",
]
chunk_texts += [p["text"] for p in json.loads((here.parent / "passages.json").read_text())["passages"]]

chunks = []
for text in chunk_texts:
    items = []
    for chunk in engine._split_into_best_sentences(text):
        prepared, guess = engine._prepare_text_prompt(chunk)
        items.append({"text": prepared, "guess": guess, "ids": engine.tokenizer.Encode(prepared)})
    chunks.append({"input": text, "chunks": items})


def tiny_model():
    """A 270-piece model with ties, a byte fallback and unknown characters, for the Viterbi rules."""
    m = pb.ModelProto()
    m.trainer_spec.model_type = 1
    m.trainer_spec.byte_fallback = True
    m.trainer_spec.unk_id, m.trainer_spec.bos_id, m.trainer_spec.eos_id, m.trainer_spec.pad_id = 0, 1, 2, -1
    m.normalizer_spec.name = "identity"
    m.normalizer_spec.add_dummy_prefix = True
    m.normalizer_spec.remove_extra_whitespaces = False
    m.normalizer_spec.escape_whitespaces = True
    pieces = [("<unk>", 0, 2), ("<s>", 0, 3), ("</s>", 0, 3)]
    pieces += [("<0x%02X>" % i, 0, 6) for i in range(256)]
    mark = "▁"
    for text, score in [
        (mark, -1.0), (mark + "a", -2.0), ("a", -5.0), ("b", -2.0), ("ab", -3.0), (mark + "b", -2.5),
        ("c", -4.0), ("abc", -9.0), (mark + "ab", -8.0), ("d", -2.0), ("e", -2.0), (mark + "d", -2.0),
        ("ed", -4.0), ("e" + mark, -3.5),
    ]:
        pieces.append((text, score, 1))
    m.trainer_spec.vocab_size = len(pieces)
    for text, score, kind in pieces:
        piece = m.pieces.add()
        piece.piece, piece.score, piece.type = text, score, kind
    return m.SerializeToString()


tiny = tiny_model()
tiny_sp = spm.SentencePieceProcessor(model_proto=tiny)
tiny_texts = ["ab", "ab ab", "abc", "aab", "b a", "c", "ed", "e d", "ded", "é", "a é b", "x", "日", "a\n", "  b", ""]

fixture.write_text(json.dumps({
    "note": "Made by research/C2/pocket/make_golden.py from Python sentencepiece and pocket_tts_onnx.py "
            "(KevinAHM/pocket-tts-onnx at 58a6d00) with tokenizer.model sha256 d461765a. "
            "One text has a non-breaking space.",
    "tokens": [{"text": t, "ids": engine.tokenizer.Encode(t)} for t in token_texts],
    "chunks": chunks,
    "tiny": {
        "model_base64": base64.b64encode(tiny).decode(),
        "encodings": [{"text": t, "ids": tiny_sp.Encode(t), "decoded": tiny_sp.Decode(tiny_sp.Encode(t))} for t in tiny_texts],
    },
}, ensure_ascii=False, indent=1) + "\n")
print("wrote", fixture)
