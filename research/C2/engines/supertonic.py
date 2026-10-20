"""Supertonic 3 INT8, the voice the app bundles today.

A Python port of the app's Swift runtime
(Packages/SessionKit/Sources/SessionKitSupertonic/SupertonicRuntime.swift):
same ONNX files (sha256-identical to asset-manifest.json), same text
preprocessing, 8 denoising steps, speed 1.0, voice M2 (the app default).
"""
import json
import re
import unicodedata
from pathlib import Path

import numpy as np
import onnxruntime as ort

ROOT = Path(__file__).resolve().parents[1]
REPO = ROOT.parents[1]
ONNX = ROOT / "models" / "sherpa-onnx-supertonic-3-tts-int8-2026-05-11"
# The app no longer bundles Supertonic (#1820): `scripts/voice-catalog fetch supertonic-3-int8` puts the same files here.
RES = REPO / "artifacts" / "voice-catalog" / "files" / "supertonic-3-int8"

_REPLACE = {"–": "-", "‑": "-", "—": "-", "_": " ", "“": '"', "”": '"',
            "‘": "'", "’": "'", "´": "'", "`": "'", "[": " ", "]": " ", "|": " ",
            "/": " ", "#": " ", "→": " ", "←": " "}
_EXPR = {"@": " at ", "e.g.,": "for example, ", "i.e.,": "that is, "}


def preprocess(text, lang="en"):
    text = unicodedata.normalize("NFKD", text)
    for a, b in _REPLACE.items():
        text = text.replace(a, b)
    for s in ["♥", "☆", "♡", "©", "\\"]:
        text = text.replace(s, "")
    for a, b in _EXPR.items():
        text = text.replace(a, b)
    for p in [",", ".", "!", "?", ";", ":", "'"]:
        text = text.replace(" " + p, p)
    while '""' in text:
        text = text.replace('""', '"')
    while "''" in text:
        text = text.replace("''", "'")
    text = re.sub(r"\s+", " ", text).strip()
    if text and not re.search(r"[.!?;:,'\"“”‘’)\]}…]$", text):
        text += "."
    return f"<{lang}>{text}</{lang}>"


class Engine:
    sample_rate = 44100

    def __init__(self, voice="M2", steps=8, speed=1.0, threads=4):
        self.voice, self.steps, self.speed, self.threads = voice, int(steps), float(speed), int(threads)
        self.name = f"supertonic3-int8-{voice}-{self.steps}step"

    def load(self):
        so = ort.SessionOptions()
        so.intra_op_num_threads = self.threads
        so.inter_op_num_threads = 1
        mk = lambda n: ort.InferenceSession(str(ONNX / f"{n}.int8.onnx"), so, providers=["CPUExecutionProvider"])
        self.dp, self.te, self.ve, self.voc = (mk(n) for n in
                                               ["duration_predictor", "text_encoder", "vector_estimator", "vocoder"])
        cfg = json.loads((RES / "onnx" / "tts.json").read_text())
        self.sample_rate = cfg["ae"]["sample_rate"]
        self.base_chunk = cfg["ae"]["base_chunk_size"]
        self.compress = cfg["ttl"]["chunk_compress_factor"]
        self.latent_dim = cfg["ttl"]["latent_dim"]
        self.indexer = np.array(json.loads((RES / "onnx" / "unicode_indexer.json").read_text()), dtype=np.int64)
        st = json.loads((RES / "voice_styles" / f"{self.voice}.json").read_text())
        self.style_ttl = np.array(st["style_ttl"]["data"], dtype=np.float32).reshape(st["style_ttl"]["dims"])
        self.style_dp = np.array(st["style_dp"]["data"], dtype=np.float32).reshape(st["style_dp"]["dims"])
        self.rng = np.random.default_rng(0)

    def synth(self, text):
        t = preprocess(text)
        ids = np.array([[self.indexer[ord(c)] if ord(c) < len(self.indexer) else -1 for c in t]], dtype=np.int64)
        mask = np.ones((1, 1, ids.shape[1]), dtype=np.float32)
        dur = self.dp.run(["duration"], {"text_ids": ids, "style_dp": self.style_dp, "text_mask": mask})[0]
        dur = dur / self.speed
        emb = self.te.run(["text_emb"], {"text_ids": ids, "style_ttl": self.style_ttl, "text_mask": mask})[0]
        wav_len = int(float(dur[0]) * self.sample_rate)
        chunk = self.base_chunk * self.compress
        lat_len = (wav_len + chunk - 1) // chunk
        xt = self.rng.standard_normal((1, self.latent_dim * self.compress, lat_len)).astype(np.float32)
        lmask = np.ones((1, 1, lat_len), dtype=np.float32)
        total = np.array([self.steps], dtype=np.float32)
        for s in range(self.steps):
            xt = self.ve.run(["denoised_latent"], {
                "noisy_latent": xt, "text_emb": emb, "style_ttl": self.style_ttl, "latent_mask": lmask,
                "text_mask": mask, "current_step": np.array([s], dtype=np.float32), "total_step": total})[0]
        wav = self.voc.run(["wav_tts"], {"latent": xt})[0].reshape(-1)
        return wav[:wav_len].astype(np.float32)
