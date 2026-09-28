"""Letter-to-sound fallback for words missing from the dictionaries.

A self-contained reimplementation of g2p_en's GRU encoder–decoder inference
(Apache-2.0, Kyubyong Park & Jongseok Kim; weights `checkpoint20.npz`, trained on
CMUdict). It's plain matrix math, so the Swift port is direct.
Output: CMUdict ARPAbet with stress digits.
"""
from pathlib import Path

import numpy as np

GRAPHEMES = ["<pad>", "<unk>", "</s>"] + list("abcdefghijklmnopqrstuvwxyz")
PHONEMES = ["<pad>", "<unk>", "<s>", "</s>"] + [
    "AA0", "AA1", "AA2", "AE0", "AE1", "AE2", "AH0", "AH1", "AH2", "AO0", "AO1", "AO2",
    "AW0", "AW1", "AW2", "AY0", "AY1", "AY2", "B", "CH", "D", "DH", "EH0", "EH1", "EH2",
    "ER0", "ER1", "ER2", "EY0", "EY1", "EY2", "F", "G", "HH", "IH0", "IH1", "IH2",
    "IY0", "IY1", "IY2", "JH", "K", "L", "M", "N", "NG", "OW0", "OW1", "OW2", "OY0",
    "OY1", "OY2", "P", "R", "S", "SH", "T", "TH", "UH0", "UH1", "UH2", "UW", "UW0",
    "UW1", "UW2", "V", "W", "Y", "Z", "ZH"]
G2I = {g: i for i, g in enumerate(GRAPHEMES)}


def _sigmoid(x):
    return 1 / (1 + np.exp(-x))


class NeuralG2P:
    def __init__(self, path: Path):
        v = np.load(path)
        self.w = {k: v[k].astype(np.float32) for k in v.files}

    def _cell(self, x, h, p):
        w = self.w
        gi = x @ w[p + "_w_ih"].T + w[p + "_b_ih"]
        gh = h @ w[p + "_w_hh"].T + w[p + "_b_hh"]
        n3 = gi.shape[-1] // 3
        r = _sigmoid(gi[:n3] + gh[:n3])
        z = _sigmoid(gi[n3:2 * n3] + gh[n3:2 * n3])
        n = np.tanh(gi[2 * n3:] + r * gh[2 * n3:])
        return (1 - z) * n + z * h

    def __call__(self, word: str) -> list[str]:
        w = self.w
        h = np.zeros(w["enc_w_hh"].shape[1], np.float32)
        for ch in list(word.lower()) + ["</s>"]:
            h = self._cell(w["enc_emb"][G2I.get(ch, 1)], h, "enc")
        x = w["dec_emb"][2]  # <s>
        out = []
        for _ in range(20):
            h = self._cell(x, h, "dec")
            pred = int(np.argmax(w["fc_w"] @ h + w["fc_b"]))
            if pred == 3:
                break
            out.append(PHONEMES[pred])
            x = w["dec_emb"][pred]
        return out
