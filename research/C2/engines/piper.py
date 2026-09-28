"""Piper (VITS) voices from rhasspy/piper-voices on onnxruntime.

Uses the piper-tts package (GPL-3.0; it links espeak-ng for phonemes).
Voice licenses differ per dataset: ljspeech is public domain; lessac is
under the Blizzard 2013 research-only licence.
"""
from pathlib import Path

import numpy as np
import onnxruntime as ort
from piper import PiperVoice
from piper.config import PiperConfig

M = Path(__file__).resolve().parents[1] / "models" / "piper"


class Engine:
    def __init__(self, voice="en_US-ljspeech-high", threads=4):
        self.voice, self.threads = voice, threads
        self.name = f"piper-{voice}"

    def load(self):
        v = PiperVoice.load(M / f"{self.voice}.onnx")
        so = ort.SessionOptions()
        so.intra_op_num_threads = self.threads
        so.inter_op_num_threads = 1
        v.session = ort.InferenceSession(str(M / f"{self.voice}.onnx"), so, providers=["CPUExecutionProvider"])
        self.v = v
        self.sample_rate = v.config.sample_rate

    def synth(self, text):
        return np.concatenate([c.audio_float_array for c in self.v.synthesize(text)])
