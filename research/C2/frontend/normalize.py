"""I14 text normalization (published in docs/workstreams/interfaces.md, I14).

Runs before any engine so every voice says the same words. Covers what the
C2 research found engines getting wrong: numbers, statistics, units after a
number, Greek letters, citation markers and a few abbreviations.
Self-contained on purpose (no num2words, which is LGPL) so it ports to Swift.
"""
import re
import unicodedata

ONES = "zero one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen".split()
TENS = "_ _ twenty thirty forty fifty sixty seventy eighty ninety".split()
SCALES = [(10**12, "trillion"), (10**9, "billion"), (10**6, "million"), (1000, "thousand")]


def int_words(n: int) -> str:
    if n < 0:
        return "minus " + int_words(-n)
    if n < 20:
        return ONES[n]
    if n < 100:
        return TENS[n // 10] + ("-" + ONES[n % 10] if n % 10 else "")
    if n < 1000:
        rest = n % 100
        return ONES[n // 100] + " hundred" + (" " + int_words(rest) if rest else "")
    for value, name in SCALES:
        if n >= value:
            rest = n % value
            return int_words(n // value) + " " + name + (" " + int_words(rest) if rest else "")
    return str(n)


def year_words(n: int) -> str:
    if 2000 <= n <= 2009:
        return int_words(n)
    hi, lo = divmod(n, 100)
    if lo == 0:
        return int_words(hi) + " hundred"
    return int_words(hi) + " " + (("oh " + ONES[lo]) if lo < 10 else int_words(lo))


def number_words(tok: str) -> str:
    """'1,284' -> one thousand..., '61.3' -> sixty-one point three, '0.001' -> zero point zero zero one."""
    tok = tok.replace(",", "")
    if "." in tok:
        whole, frac = tok.split(".", 1)
        return (int_words(int(whole)) if whole else "zero") + " point " + " ".join(ONES[int(d)] for d in frac)
    return int_words(int(tok))


GREEK = {"α": "alpha", "β": "beta", "γ": "gamma", "δ": "delta", "ε": "epsilon", "ζ": "zeta", "η": "eta",
         "θ": "theta", "ι": "iota", "κ": "kappa", "λ": "lambda", "μ": "mu", "ν": "nu", "ξ": "xi",
         "π": "pi", "ρ": "rho", "σ": "sigma", "τ": "tau", "υ": "upsilon", "φ": "phi", "χ": "chi",
         "ψ": "psi", "ω": "omega", "Δ": "delta", "Σ": "sigma", "Ω": "omega"}

UNITS = {"mM": "millimolar", "µM": "micromolar", "μM": "micromolar", "nM": "nanomolar", "ng/mL": "nanograms per milliliter", "mg/dL": "milligrams per deciliter", "mg/kg": "milligrams per kilogram",
         "µg": "micrograms", "μg": "micrograms", "mg": "milligrams", "kg": "kilograms", "ng": "nanograms",
         "mL": "milliliters", "ml": "milliliters", "µm": "micrometers", "μm": "micrometers", "nm": "nanometers",
         "mm": "millimeters", "cm": "centimeters", "km": "kilometers", "°C": "degrees Celsius", "°F": "degrees Fahrenheit",
         "IU": "I U", "Hz": "hertz", "kHz": "kilohertz", "MHz": "megahertz", "GB": "gigabytes", "MB": "megabytes",
         "ms": "milliseconds", "mmHg": "millimeters of mercury", "h": "hours", "min": "minutes", "s": "seconds"}
SYMBOLS = {"±": " plus or minus ", "×": " times ", "≥": " greater than or equal to ", "≤": " less than or equal to ",
           "≈": " approximately ", "→": " to ", "%": " percent", "&": " and "}
ABBREV = [(r"\bet al\.(?=\s*$|\s+[A-Z])", "and colleagues."), (r"\bet al\.", "and colleagues"), (r"\be\.g\.,?", "for example,"), (r"\bi\.e\.,?", "that is,"),
          (r"\bvs\.?(?=\s)", "versus"), (r"\bapprox\.", "approximately"), (r"\bFig\.", "Figure"),
          (r"\bDr\.", "Doctor"), (r"\bMr\.", "Mister"), (r"\bMrs\.", "Missus"), (r"\bNo\.(?=\s*\d)", "number")]

NUM = r"\d{1,3}(?:,\d{3})+(?:\.\d+)?|\d+(?:\.\d+)?"


LETTER_NAMES = {c: c for c in "ABCDEFGHIJKLMNOPQRSTUVWXYZ"}


def spell_code(tok: str) -> str:
    """'HbA1c' -> 'H b A one c', 'CO2' -> 'C O two': mixed letter-digit codes are spelled."""
    return " ".join(ONES[int(c)] if c.isdigit() else c.upper() for c in tok)


def normalize(text: str) -> str:
    # strip accents ('Reykjavík' -> 'Reykjavik') but keep Greek letters and µ for the tables below
    t = "".join(c for c in unicodedata.normalize("NFD", text) if unicodedata.category(c) != "Mn")
    t = unicodedata.normalize("NFC", t)
    # I14 markers: numeric citations and parenthetical author-year citations are silent
    t = re.sub(r"\s*\[\d+(?:\s*[,–-]\s*\d+)*\]", "", t)
    t = re.sub(r"\s*\((?:[A-Z][A-Za-z'’-]+(?: et al\.)?(?:,| and [A-Z][A-Za-z'’-]+,)? \d{4}[a-z]?(?:; )?)+\)", "", t)
    for pat, rep in ABBREV:
        t = re.sub(pat, rep, t)
    # codes mixing letters and digits with a capital inside ('HbA1c', 'CO2', 'D3') are spelled out
    t = re.sub(r"\b(?=[A-Za-z0-9]*[A-Z])(?=[A-Za-z0-9]*\d)[A-Za-z][A-Za-z0-9]*\b",
               lambda m: spell_code(m.group(0)) if not re.fullmatch(r"[A-Z]\d+", m.group(0)) else m.group(0)[0] + " " + m.group(0)[1:], t)
    # statistics
    t = re.sub(r"\b95%\s*CI\b", "95 percent confidence interval", t)
    t = re.sub(r"\bCI\b", "confidence interval", t)
    t = re.sub(r"\b([pP])\s*=\s*", r"\1 equals ", t)
    t = re.sub(r"\b([pP])\s*<\s*", r"\1 less than ", t)
    t = re.sub(r"\b([pP])\s*>\s*", r"\1 greater than ", t)
    t = re.sub(r"\s=\s", " equals ", t)
    # ranges: 10–20 -> 10 to 20
    t = re.sub(rf"({NUM})\s*[–—]\s*({NUM})", r"\1 to \2", t)
    # units after a number (longest first)
    for u in sorted(UNITS, key=len, reverse=True):
        t = re.sub(rf"({NUM})\s?{re.escape(u)}(?![A-Za-z])", lambda m: m.group(1) + " " + UNITS[u], t)
    for g, w in GREEK.items():
        t = t.replace(g, " " + w + " ")
    for s, w in SYMBOLS.items():
        t = t.replace(s, w)
    # clock times: 11:45 -> eleven forty-five, 9:05 -> nine oh five
    t = re.sub(r"\b(\d{1,2}):(\d{2})\b", lambda m: int_words(int(m.group(1))) + " " + (
        "o'clock" if m.group(2) == "00" else ("oh " + ONES[int(m.group(2))]) if m.group(2)[0] == "0" else int_words(int(m.group(2)))), t)
    # ordinals and years before plain numbers
    t = re.sub(r"\b(\d+)(st|nd|rd|th)\b", lambda m: ordinal(int(m.group(1))), t)
    t = re.sub(r"\b(1[1-9]\d\d|20\d\d)\b(?![.,]\d)", lambda m: year_words(int(m.group(1))), t)
    t = re.sub(rf"(?<![\w.]){NUM}(?![\w])", lambda m: number_words(m.group(0)), t)
    t = re.sub(r"\s*[\[\]()]\s*", ", ", t)
    t = re.sub(r"\s+,", ",", t)
    t = re.sub(r",(\s*,)+", ",", t)
    t = re.sub(r",\s*([.;:!?])", r"\1", t)
    t = re.sub(r"^,\s*", "", t)
    t = re.sub(r"\s{2,}", " ", t)
    return t.strip()


def ordinal(n: int) -> str:
    w = int_words(n)
    irregular = {"one": "first", "two": "second", "three": "third", "five": "fifth", "eight": "eighth",
                 "nine": "ninth", "twelve": "twelfth"}
    head, sep, last = w.rpartition("-") if "-" in w.split(" ")[-1] else w.rpartition(" ")
    if last in irregular:
        last = irregular[last]
    elif last.endswith("y"):
        last = last[:-1] + "ieth"
    else:
        last += "th"
    return head + sep + last
