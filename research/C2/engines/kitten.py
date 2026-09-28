"""KittenTTS 0.8 (Apache-2.0 weights) on onnxruntime.

Inference follows KittenML's reference onnx_model.py (read, not vendored):
espeak-ng phonemes (GPL) -> symbol ids -> one ONNX graph at 24 kHz.
"""
import json
import re
from pathlib import Path

import espeakng_loader
import numpy as np
import onnxruntime as ort
from phonemizer.backend import EspeakBackend
from phonemizer.backend.espeak.wrapper import EspeakWrapper

M = Path(__file__).resolve().parents[1] / "models"
_pad = "$"
_punct = ';:,.!?¡¿—…"«»"" '
_letters = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
_ipa = "ɑɐɒæɓʙβɔɕçɗɖðʤəɘɚɛɜɝɞɟʄɡɠɢʛɦɧħɥʜɨɪʝɭɬɫɮʟɱɯɰŋɳɲɴøɵɸθœɶʘɹɺɾɻʀʁɽʂʃʈʧʉʊʋⱱʌɣɤʍχʎʏʑʐʒʔʡʕʢǀǁǂǃˈˌːˑʼʴʰʱʲʷˠˤ˞↓↑→↗↘'̩'ᵻ"
SYMBOLS = {s: i for i, s in enumerate([_pad] + list(_punct) + list(_letters) + list(_ipa))}


class Engine:
    sample_rate = 24000

    def __init__(self, size="nano", voice="Jasper", threads=4, frontend="espeak"):
        self.size, self.voice, self.threads, self.frontend = size, voice, threads, frontend
        self.name = f"kitten-{size}-0.8-{voice}" + ("" if frontend == "espeak" else f"-{frontend}")

    def load(self):
        repo = {"nano": "kitten-tts-nano-0.8-int8", "nano-fp32": "kitten-tts-nano-0.8-fp32", "micro": "kitten-tts-micro-0.8", "mini": "kitten-tts-mini-0.8"}[self.size]
        d = M / repo
        cfg = json.loads((d / "config.json").read_text())
        so = ort.SessionOptions()
        so.intra_op_num_threads = self.threads
        so.inter_op_num_threads = 1
        self.sess = ort.InferenceSession(str(d / cfg["model_file"]), so, providers=["CPUExecutionProvider"])
        self.voices = np.load(d / "voices.npz")
        v = cfg["voice_aliases"].get(self.voice, self.voice)
        self.vkey = v
        self.speed = cfg.get("speed_priors", {}).get(v, 1.0)
        EspeakWrapper.set_library(espeakng_loader.get_library_path())
        # The macOS libespeak-ng wheel has its CI build path compiled in, so the
        # environment variable alone isn't enough there; pass the path explicitly.
        EspeakWrapper.set_data_path(espeakng_loader.get_data_path())
        self.ph = EspeakBackend(language="en-us", preserve_punctuation=True, with_stress=True)
        if self.frontend == "c2":
            import sys
            sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "frontend"))
            from frontend import FrontEnd
            self.fe = FrontEnd()

    def synth(self, text):
        p = self.fe.phonemize(text) if self.frontend == "c2" else self.ph.phonemize([text])[0]
        p = " ".join(re.findall(r"\w+|[^\w\s]", p))
        ids = [0] + [SYMBOLS[c] for c in p if c in SYMBOLS] + [10, 0]
        vs = self.voices[self.vkey]
        ref = vs[min(len(text), vs.shape[0] - 1)][None, :]
        out = self.sess.run(None, {"input_ids": np.array([ids], dtype=np.int64), "style": ref.astype(np.float32),
                                   "speed": np.array([self.speed], dtype=np.float32)})[0]
        return out.reshape(-1)[:-5000]
