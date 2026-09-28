"""Kyutai Pocket TTS (CC-BY-4.0 weights, MIT code), PyTorch on CPU.

No phonemizer: text goes through a SentencePiece tokenizer, so there is no
espeak-ng anywhere in the stack. Autoregressive and streaming, so it can
start playing after the first frames rather than after a whole chunk.
Uses the ungated "without voice cloning" weights and a built-in voice.
"""
import time

import numpy as np
import torch


class Engine:
    def __init__(self, voice="alba", threads=4, language="english"):
        self.voice, self.threads, self.language = voice, int(threads), language
        self.name = f"pocket-{voice}"

    def load(self):
        from pocket_tts import TTSModel
        torch.set_num_threads(self.threads)  # pocket_tts sets 1 at import
        self.m = TTSModel.load_model(language=self.language)
        torch.set_num_threads(self.threads)
        self.state = self.m.get_state_for_audio_prompt(self.voice)
        self.sample_rate = self.m.sample_rate

    def synth(self, text):
        with torch.no_grad():
            return self.m.generate_audio(self.state, text).numpy().reshape(-1).astype(np.float32)

    def stream_ttfa(self, text):
        """Seconds until the first streamed audio frame is ready."""
        t = time.perf_counter()
        with torch.no_grad():
            for _ in self.m.generate_audio_stream(self.state, text):
                return time.perf_counter() - t
