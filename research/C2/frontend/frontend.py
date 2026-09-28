"""Non-GPL text front end for KittenTTS: text -> espeak-style IPA -> Kitten ids.

Pipeline per word: I14 normalization -> misaki US gold dictionary (Apache-2.0)
-> CMU Pronouncing Dictionary (BSD) -> compound split into two dictionary words
-> neural letter-to-sound (g2p_en weights, Apache-2.0). Every pronunciation is
rewritten into espeak-ng's conventions (lexmap.py), because Kitten was trained on
espeak output. No espeak code or data is used.
"""
import json
import re
from functools import lru_cache
from pathlib import Path

from lexmap import espeakify, misaki_to_espeak
from neural_g2p import NeuralG2P
from normalize import ALWAYS_SPELL, normalize

ROOT = Path(__file__).resolve().parents[1]
DATA = ROOT / "models" / "frontend"
MISAKI = ROOT / ".venv" / "lib" / "python3.11" / "site-packages" / "misaki" / "data"

ARPA = {"AA": "ɑ", "AE": "æ", "AH": "ʌ", "AO": "ɔ", "AW": "aʊ", "AY": "aɪ", "B": "b", "CH": "tʃ", "D": "d",
        "DH": "ð", "EH": "ɛ", "ER": "ɜɹ", "EY": "eɪ", "F": "f", "G": "ɡ", "HH": "h", "IH": "ɪ", "IY": "i",
        "JH": "dʒ", "K": "k", "L": "l", "M": "m", "N": "n", "NG": "ŋ", "OW": "oʊ", "OY": "ɔɪ", "P": "p",
        "R": "ɹ", "S": "s", "SH": "ʃ", "T": "t", "TH": "θ", "UH": "ʊ", "UW": "u", "V": "v", "W": "w",
        "Y": "j", "Z": "z", "ZH": "ʒ"}
LETTERS = {"a": "ˈeɪ", "b": "bˈiː", "c": "sˈiː", "d": "dˈiː", "e": "ˈiː", "f": "ˈɛf", "g": "dʒˈiː",
           "h": "ˈeɪtʃ", "i": "ˈaɪ", "j": "dʒˈeɪ", "k": "kˈeɪ", "l": "ˈɛl", "m": "ˈɛm", "n": "ˈɛn",
           "o": "ˈoʊ", "p": "pˈiː", "q": "kjˈuː", "r": "ˈɑːɹ", "s": "ˈɛs", "t": "tˈiː", "u": "jˈuː",
           "v": "vˈiː", "w": "dˈʌbəljuː", "x": "ˈɛks", "y": "wˈaɪ", "z": "zˈiː"}
VOW = "aeiouæɑɐɒɔəɚɛɜɪʊʌᵻ"

# Function words in espeak-style reduced forms (written by hand from standard US
# pronunciations). "the" becomes ðɪ before a vowel; see FrontEnd.phonemize.
FUNCTION = {"the": "ðə", "a": "ɐ", "an": "ɐn", "to": "tə", "of": "ʌv", "and": "ænd", "or": "ɔːɹ",
            "for": "fɔːɹ", "at": "æt", "in": "ɪn", "on": "ɔn", "by": "baɪ", "with": "wɪð", "from": "fɹʌm",
            "as": "æz", "is": "ɪz", "was": "wʌz", "are": "ɑːɹ", "were": "wɜː", "be": "biː", "been": "bɪn",
            "i": "aɪ", "you": "juː", "he": "hiː", "she": "ʃiː", "we": "wiː", "they": "ðeɪ", "it": "ɪt",
            "me": "mˌiː", "him": "hˌɪm", "her": "hɜː", "us": "ˌʌs", "them": "ðˌɛm", "his": "hɪz",
            "its": "ɪts", "our": "aʊɚ", "their": "ðɛɹ", "my": "maɪ", "your": "jʊɹ",
            "but": "bˌʌt", "so": "sˌoʊ", "if": "ɪf", "than": "ðɐn", "that": "ðæt", "this": "ðɪs",
            "when": "wˌɛn", "who": "hˌuː", "what": "wˌʌt", "which": "wˌɪtʃ", "why": "wˌaɪ",
            "not": "nˈɑːt", "can": "kæn", "could": "kʊd", "should": "ʃˌʊd", "would": "wʊd",
            "will": "wɪl", "do": "dˈuː", "does": "dˈʌz", "did": "dˈɪd", "has": "hɐz", "have": "hæv",
            "had": "hæd", "there": "ðɛɹ", "then": "ðˈɛn", "up": "ˌʌp", "out": "ˈaʊt"}


def arpabet_to_ipa(phones: list[str]) -> str:
    out = []
    for p in phones:
        base, stress = re.match(r"([A-Z]+)(\d?)", p).groups()
        ipa = ARPA[base]
        if base == "AH" and stress in ("0", ""):
            ipa = "ə"
        if base == "ER" and stress == "0":
            ipa = "əɹ"
        mark = {"1": "ˈ", "2": "ˌ"}.get(stress, "")
        out.append(mark + ipa)
    s = "".join(out)
    # move stress marks before the vowel only (they already are); flap t/d between vowels before an unstressed vowel
    s = re.sub(rf"(?<=[{VOW}ː])t(?=[əɪᵻɚi](?!ː))", "ɾ", s)
    return s


class FrontEnd:
    def __init__(self, use_silver: bool = False):
        # Lookup is exact key first, then the lowercased word (see _dict); keys keep their case.
        self.lex = json.loads((MISAKI / "us_gold.json").read_text())
        if use_silver:
            for k, v in json.loads((MISAKI / "us_silver.json").read_text()).items():
                self.lex.setdefault(k, v)
        self.cmu = {}
        for line in (DATA / "cmudict.dict").read_text(encoding="latin-1").splitlines():
            parts = line.split("#")[0].split()
            if parts and "(" not in parts[0]:
                self.cmu[parts[0]] = parts[1:]
        self.neural = NeuralG2P(DATA / "checkpoint20.npz")
        self.source_counts = {}

    def _count(self, k):
        self.source_counts[k] = self.source_counts.get(k, 0) + 1

    def _dict(self, w: str):
        v = self.lex.get(w) or self.lex.get(w.lower())
        if isinstance(v, dict):
            v = v.get("DEFAULT") or next(iter(v.values()))
        if v:
            return misaki_to_espeak(v, w.lower())
        c = self.cmu.get(w.lower())
        if c:
            return espeakify(arpabet_to_ipa(c), w.lower())
        return None

    @lru_cache(maxsize=50_000)
    def word(self, w: str) -> str:
        if w.lower() in FUNCTION and not (len(w) > 1 and w.isupper()):
            self._count("function")
            return FUNCTION[w.lower()]
        if w in ALWAYS_SPELL or len(w) >= 2 and not re.search(r"[aeiouyAEIOUY]", w):
            self._count("letters")                            # 'km', 'tbh', 'PBS': no vowel letter, spell it
            letters = [LETTERS[c.lower()] for c in w]
            return "".join(l.replace("ˈ", "ˌ") if i < len(letters) - 1 else l for i, l in enumerate(letters))
        if len(w) == 1 and w.isupper() and w not in ("I", "A"):
            self._count("letters")
            return LETTERS[w.lower()]
        if re.fullmatch(r"[A-Z]{2,5}s?", w) and not self._dict(w) or re.fullmatch(r"[A-Z]{2,4}", w) and w not in self.lex:
            self._count("letters")
            letters = [LETTERS[c.lower()] for c in w.rstrip("s")] + (["z"] if w.endswith("s") and len(w) > 2 else [])
            return "".join(l.replace("ˈ", "ˌ") if i < len(letters) - 1 else l for i, l in enumerate(letters))
        d = self._dict(w)
        if d:
            self._count("dictionary")
            return d
        lw = w.lower()
        if lw.endswith("'s") and self._dict(lw[:-2]):
            self._count("dictionary")
            return self._dict(lw[:-2]) + "z"
        # two dictionary words glued together ('hydroxyvitamin')
        for i in range(len(lw) - 3, 2, -1):
            a, b = self._dict(lw[:i]), self._dict(lw[i:])
            if a and b and len(lw[:i]) >= 3 and len(lw[i:]) >= 4:
                self._count("compound")
                return a.replace("ˈ", "ˌ") + b
        self._count("neural")
        return espeakify(arpabet_to_ipa(self.neural(re.sub(r"[^a-z]", "", lw))), lw)

    def phonemize(self, text: str) -> str:
        """Text -> phoneme string in phonemizer's shape (words space-separated, punctuation kept)."""
        t = normalize(text)
        out, pending, open_quote = [], "", False
        for tok in re.findall(r"[A-Za-z]+(?:['’][A-Za-z]+)?|[.,!?;:—…\"“”]", t):
            if re.match(r"[A-Za-z]", tok):
                out.append(pending + self.word(tok.replace("’", "'")))
                pending = ""
            elif tok in '"“”':
                if open_quote or tok == "”":
                    if out:
                        out[-1] += '"'
                    open_quote = False
                else:
                    pending, open_quote = '"', True
            else:
                tok = {"—": ",", "…": "."}.get(tok, tok)
                if out:
                    out[-1] += tok
        # 'the' before a vowel sound
        for i in range(len(out) - 1):
            if out[i] in ("ðə", '"ðə') and re.match(rf'^"?[ˈˌ]?[{VOW}]', out[i + 1]):
                out[i] = out[i][:-1] + "ɪ"
        return " ".join(out)
