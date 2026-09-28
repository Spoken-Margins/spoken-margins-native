"""Kokoro-82M v1.0 (Apache-2.0 weights) on onnxruntime, int8 or fp32.

Front end: misaki English G2P (Apache-2.0), which is a lexicon plus rules.
Words missing from the lexicon go to an espeak-ng fallback here (GPL). The
shipping build would replace that fallback (see README, "License").
"""
from pathlib import Path

import numpy as np
import onnxruntime as ort
from kokoro_onnx import Kokoro
from misaki import en, espeak

M = Path(__file__).resolve().parents[1] / "models"


class Engine:
    sample_rate = 24000

    def __init__(self, voice="af_heart", quant="int8", threads=4, fallback="espeak"):
        self.voice, self.quant, self.threads, self.fallback = voice, quant, threads, fallback
        self.name = f"kokoro-{quant}-{voice}"

    def load(self):
        so = ort.SessionOptions()
        so.intra_op_num_threads = self.threads
        so.inter_op_num_threads = 1
        f = "kokoro-v1.0.int8.onnx" if self.quant == "int8" else "kokoro-v1.0.onnx"
        sess = ort.InferenceSession(str(M / f), so, providers=["CPUExecutionProvider"])
        self.k = Kokoro.from_session(sess, str(M / "voices-v1.0.bin"))
        fb = espeak.EspeakFallback(british=False) if self.fallback == "espeak" else None
        self.g2p = en.G2P(trf=False, british=False, fallback=fb)

    def synth(self, text):
        ps, _ = self.g2p(text)
        wav, sr = self.k.create(ps, voice=self.voice, speed=1.0, is_phonemes=True)
        self.sample_rate = sr
        return wav
