"""Build the blind listening page from out/<engine>/<passage>.wav.

Writes listening/index.html, listening/audio/<letter>-<passage>.mp3 and
listening/answer-key.md. Letters are assigned by a seeded shuffle, so a
rebuild (for example after adding the Samantha sample on the Mac) keeps
the same letters. Every clip is loudness-matched so "louder" can't win.

usage: .venv/bin/python build_page.py
"""
import html
import json
import random
from pathlib import Path

import lameenc
from scipy.signal import resample_poly
import numpy as np
import soundfile as sf

ROOT = Path(__file__).resolve().parent
OUT = ROOT / "out"
LIST = ROOT / "listening"
AUDIO = LIST / "audio"

# The blind set. Order here is irrelevant; letters come from the shuffle.
CANDIDATES = [
    ("supertonic3-int8-M2-8step", "Supertonic 3 INT8, voice M2, 8 steps (the app today)"),
    ("supertonic3-int8-M2-4step", "Supertonic 3 INT8, voice M2, 4 steps (same model, half the work)"),
    ("kokoro-fp32-af_heart", "Kokoro-82M v1.0 fp32, voice af_heart"),
    ("kitten-nano-fp32-0.8-Jasper", "KittenTTS nano 0.8 fp32, voice Jasper"),
    ("piper-en_US-ljspeech-high", "Piper, en_US ljspeech high"),
    ("pocket-alba", "Kyutai Pocket TTS, voice alba"),
    ("samantha-mac", "Apple Samantha via `say` (Mac)"),
]
SEED = 192  # the tracking issue; changing it re-letters everything
TARGET_RMS_DB = -20.0
PAGE_SR = 24000  # one rate for every clip, so the sample rate gives nothing away


def loudness_match(x):
    x = x.astype(np.float64)
    rms = np.sqrt(np.mean(x ** 2)) or 1e-9
    y = x * (10 ** (TARGET_RMS_DB / 20) / rms)
    peak = np.max(np.abs(y))
    if peak > 0.98:
        y = y * (0.98 / peak)
    return y


def to_mp3(wav, sr, path):
    enc = lameenc.Encoder()
    enc.set_bit_rate(96)
    enc.set_in_sample_rate(sr)
    enc.set_channels(1)
    enc.set_quality(2)
    pcm = (np.clip(wav, -1, 1) * 32767).astype("<i2").tobytes()
    path.write_bytes(enc.encode(pcm) + enc.flush())


def main():
    passages = json.loads((ROOT / "passages.json").read_text())["passages"]
    letters = "ABCDEFG"[: len(CANDIDATES)]
    order = CANDIDATES[:]
    random.Random(SEED).shuffle(order)
    assign = {c[0]: letters[i] for i, c in enumerate(order)}
    AUDIO.mkdir(parents=True, exist_ok=True)
    voices = []
    for key, desc in CANDIDATES:
        L = assign[key]
        clips = {}
        for p in passages:
            src = OUT / key / f"{p['id']}.wav"
            dst = AUDIO / f"{L}-{p['id']}.mp3"
            # Keep clips that already exist: the owner may have rated them, and
            # a re-render (Pocket samples randomly) would change what they heard.
            if not dst.exists():
                if not src.exists():
                    continue
                wav, sr = sf.read(src, dtype="float64")
                if wav.ndim > 1:
                    wav = wav.mean(axis=1)
                if sr != PAGE_SR:
                    g = np.gcd(sr, PAGE_SR)
                    wav = resample_poly(wav, PAGE_SR // g, sr // g)
                to_mp3(loudness_match(wav), PAGE_SR, dst)
            clips[p["id"]] = {"src": f"audio/{dst.name}"}
        voices.append({"letter": L, "pending": bool(not clips),
                       "clips": clips})
    voices.sort(key=lambda v: v["letter"])
    key_lines = ["# Blind listening answer key", "",
                 "Don't open this until you've rated every voice on the listening page.", "",
                 "| Letter | Candidate |", "| --- | --- |"]
    key_lines += [f"| {assign[k]} | {d} |" for k, d in sorted(CANDIDATES, key=lambda c: assign[c[0]])]
    (LIST / "answer-key.md").write_text("\n".join(key_lines) + "\n")
    data = {"passages": [{"id": p["id"], "title": p["title"], "text": p["text"]} for p in passages],
            "voices": voices, "seed": SEED}
    tpl = (ROOT / "listening_template.html").read_text()
    (LIST / "index.html").write_text(tpl.replace("/*DATA*/null", json.dumps(data)))
    print("letters:", {assign[k]: k for k, _ in CANDIDATES})


if __name__ == "__main__":
    main()
