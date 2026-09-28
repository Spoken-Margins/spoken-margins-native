"""Map misaki / CMUdict pronunciations onto espeak-ng en-us IPA conventions.

Kitten was trained on espeak-ng's phoneme strings, so the front end must spell
sounds the way espeak does, without using espeak's code or data. These rules were
derived by comparing dictionary entries with espeak output on common words
(espeak is used only as a measuring stick in research; nothing from it ships).
"""
import re

VOWELS = "aeiouæɑɐɒɔəɚɛɜɪʊʌᵻ"
V = f"[{VOWELS}]"


def misaki_to_espeak(ps: str, word: str = "") -> str:
    s = ps
    for a, b in [("A", "eɪ"), ("I", "aɪ"), ("W", "aʊ"), ("Y", "ɔɪ"), ("O", "oʊ"),
                 ("ʤ", "dʒ"), ("ʧ", "tʃ"), ("ᵊ", "ə")]:
        s = s.replace(a, b)
    return espeakify(s, word)


def espeakify(s: str, word: str = "") -> str:
    """Apply espeak's spelling habits to an IPA string in misaki-like conventions."""
    # r-coloured vowels
    s = s.replace("ɜɹ", "ɜː").replace("əɹ", "ɚ")
    s = re.sub(rf"(ɚ|ɜː)(?=[ˈˌ]?{V})", r"\1ɹ", s)          # 'around' ɚɹˈaʊnd
    # long vowels: stressed i/u/ɑ, ɔ only before l/ɹ/ɾ/end, and ɑ/ɔ before ɹ
    s = re.sub(r"([ˈˌ])(i|u|ɑ)(?!ː)", r"\1\2ː", s)
    s = re.sub(r"([ˈˌ])ɔ(?=[lɹɾ]|$)", r"\1ɔː", s)
    s = re.sub(r"(?<![ˈˌ])(ɑ|ɔ)(?=ɹ)", r"\1ː", s)
    nvowels = len(re.findall(r"aɪ|aʊ|eɪ|oʊ|ɔɪ|" + V, s))
    if nvowels == 1:
        s = re.sub(r"(?<![ˈˌ])(i|u|ɑ|ɔ)(?![ːɪ])(?=\S*$)", r"\1ː", s)   # 'to' tuː, 'he' hiː
        if "ˈ" not in s:
            s = s.replace("ˌ", "ˈ")                          # 'not' nˈɑːt
    # secondary stress: espeak drops it right before the primary and after it
    if "ˈ" in s:
        head, _, tail = s.partition("ˈ")
        if head.count("ˌ") == 1 and len(re.findall(r"aɪ|aʊ|eɪ|oʊ|ɔɪ|" + V, head.split("ˌ", 1)[1])) <= 1:
            head = head.replace("ˌ", "")
        # after the primary: dropped when it's the very next syllable ('something'), kept later ('anything')
        m = re.match(rf"^(.*?(?:aɪ|aʊ|eɪ|oʊ|ɔɪ|{V})ː?)([^ˌ]*)ˌ", tail)
        if m and not re.search(r"aɪ|aʊ|eɪ|oʊ|ɔɪ|" + V, m.group(2)):
            tail = tail.replace("ˌ", "", 1)
        s = head + "ˈ" + tail
    # reduced vowels
    s = re.sub(rf"^ə(?=[^{VOWELS}ː])", "ɐ", s)              # 'about' ɐbˈaʊt
    s = re.sub(rf"(?<![ˈˌ])i(?=[^\sː])", "ɪ", s)            # unstressed non-final i: 'video'
    if word.startswith(("ex", "en", "em")):
        s = re.sub(r"^ɪ", "ɛ", s)                            # 'example' ɛɡzˈæmpəl
    if re.match(r"^(be|re|de|pre)[^aeiou]", word):
        s = re.sub(rf"^([^{VOWELS}ˈˌ]+)ə(?=[^ˈˌ]*ˈ)", r"\1ᵻ", s)  # 'before' bᵻfˈɔːɹ
    return s
