"""Shared benchmark harness: every engine gets the same chunks, clock and gap.

Time to first audio (TTFA) = wall time to render the first chunk with the
model already loaded (what the listener waits for after pressing play).
Real-time factor (RTF) = render wall time / audio duration; below 1.0 is
faster than real time, and "speed" = 1/RTF (the brief's ">=2x" means speed >= 2).
"""
import importlib
import json
import re
import sys
import time
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parent
GAP_S = 0.25          # silence between chunks, the same for every engine
MAX_CHARS = 240       # the app's Supertonic chunk size


def chunk_text(text, max_chars=MAX_CHARS):
    sentences = re.split(r"(?<=[.!?])\s+(?=[\"A-Z0-9])", text.strip())
    chunks, cur = [], ""
    for s in sentences:
        if cur and len(cur) + 1 + len(s) > max_chars:
            chunks.append(cur)
            cur = s
        else:
            cur = f"{cur} {s}".strip()
    if cur:
        chunks.append(cur)
    return chunks


def run(engine, text, first_chunk_sentence=True):
    """Render text chunk by chunk. First chunk is one sentence (as a player would do to start fast)."""
    chunks = chunk_text(text)
    if first_chunk_sentence:
        sents = re.split(r"(?<=[.!?])\s+(?=[\"A-Z0-9])", chunks[0])
        if len(sents) > 1:
            chunks = [sents[0], " ".join(sents[1:])] + chunks[1:]
    audio, ttfa = [], None
    t0 = time.perf_counter()
    for i, c in enumerate(chunks):
        wav = engine.synth(c)
        if ttfa is None:
            ttfa = time.perf_counter() - t0
        if i:
            audio.append(np.zeros(int(GAP_S * engine.sample_rate), dtype=np.float32))
        audio.append(np.asarray(wav, dtype=np.float32).reshape(-1))
    total = time.perf_counter() - t0
    wav = np.concatenate(audio)
    dur = len(wav) / engine.sample_rate
    return wav, {"ttfa_s": round(ttfa, 3), "render_s": round(total, 3), "audio_s": round(dur, 2),
                 "rtf": round(total / dur, 3), "chunks": len(chunks)}


def load_engine(spec, threads):
    mod, _, kw = spec.partition(":")
    kwargs = dict(x.split("=") for x in kw.split(",") if x) if kw else {}
    m = importlib.import_module(f"engines.{mod}")
    return m.Engine(threads=threads, **kwargs)
