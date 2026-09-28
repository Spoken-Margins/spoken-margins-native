"""I14 text normalization (published in docs/workstreams/interfaces.md, I14).

Runs before any engine so every voice says the same words. Covers what the
C2 research found engines getting wrong: numbers, statistics, units after a
number, Greek letters, citation markers and a few abbreviations.
Self-contained on purpose (no num2words, which is LGPL) so it ports to Swift.
Digits are ASCII only ([0-9]); other scripts' digits pass through untouched.
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
            # a comma after the scale word: without it Kitten drops 'one thousand' ('1,250' heard as '250')
            return int_words(n // value) + " " + name + (", " + int_words(rest) if rest else "")
    return str(n)


def year_words(n: int) -> str:
    if 2000 <= n <= 2009:
        return "two thousand" + (" " + ONES[n - 2000] if n > 2000 else "")
    hi, lo = divmod(n, 100)
    if lo == 0:
        return int_words(hi) + " hundred"
    return int_words(hi) + " " + (("oh " + ONES[lo]) if lo < 10 else int_words(lo))


def number_words(tok: str) -> str:
    """'1,284' -> one thousand..., '61.3' -> sixty-one point three, '0.001' -> zero point zero zero one."""
    tok = tok.replace(",", "")
    if "." in tok:
        whole, frac = tok.split(".", 1)
        return (int_words(int(whole)) if whole else "zero") + " point " + " ".join(ONES[int(d)] for d in frac if d in "0123456789")
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
         "ms": "milliseconds", "mmHg": "millimeters of mercury", "min": "minutes"}
# one-letter units need a space before them ('48 h', '30 s') so '1990s' and '3D' aren't units
SHORT_UNITS = {"h": "hours", "s": "seconds"}
MONTHS = "January|February|March|April|May|June|July|August|September|October|November|December|Jan|Feb|Mar|Apr|Jun|Jul|Aug|Sep|Sept|Oct|Nov|Dec"
YEAR_CUE = rf"(?:{MONTHS})(?:\s+[0-9]{{1,2}}(?:st|nd|rd|th)?)?,?|in|since|by|until|from|during|before|after|circa|c\.|early|late|mid|spring|summer|autumn|fall|winter"
ALWAYS_SPELL = {"US", "UK", "IT", "AM", "PM", "AI", "EU", "UN", "TV", "ID", "OK"}
CURRENCY = {"$": "dollars", "£": "pounds", "€": "euros"}
SYMBOLS = {"±": " plus or minus ", "×": " times ", "≥": " greater than or equal to ", "≤": " less than or equal to ",
           "≈": " approximately ", "→": " to ", "%": " percent", "&": " and "}
ABBREV = [(r"\bSt\.(?=\s+[A-Z])", "Saint"), (r"\bPh\.D\.", "P H D"), (r"\b([ap])\.m\.", lambda m: m.group(1).upper() + " M"),
          (r"\bet al\.(?=\s*$|\s+[A-Z])", "and colleagues."), (r"\bet al\.", "and colleagues"), (r"\be\.g\.,?", "for example,"), (r"\bi\.e\.,?", "that is,"),
          (r"\bvs\.?(?=\s)", "versus"), (r"\bapprox\.", "approximately"), (r"\bFig\.", "Figure"),
          (r"\bDr\.", "Doctor"), (r"\bMr\.", "Mister"), (r"\bMrs\.", "Missus"), (r"\bNo\.(?=\s*\d)", "number")]

NUM = r"[0-9]{1,3}(?:,[0-9]{3})+(?:\.[0-9]+)?|[0-9]+(?:\.[0-9]+)?"


LETTER_NAMES = {c: c for c in "ABCDEFGHIJKLMNOPQRSTUVWXYZ"}


def spell_code(tok: str) -> str:
    """'HbA1c' -> 'H b A one c', 'CO2' -> 'C O two': mixed letter-digit codes are spelled."""
    return " ".join(ONES[int(c)] if c in "0123456789" else c.upper() for c in tok)


def plural_words(w: str) -> str:
    """'nineteen ninety' -> 'nineteen nineties' (decades)."""
    head, sep, last = w.rpartition(" ")
    last = last[:-1] + "ies" if last.endswith("y") else last + "s"
    return head + sep + last


def currency_words(sym: str, num: str, scale: str) -> str:
    unit = CURRENCY[sym]
    if scale:
        return f"{number_words(num)} {scale} {unit}"
    whole, _, cents = num.replace(",", "").partition(".")
    out = f"{int_words(int(whole))} {unit if whole != '1' else unit[:-1]}"
    if len(cents) == 2 and int(cents):
        out += " " + int_words(int(cents))
    return out


def normalize(text: str) -> str:
    # strip accents ('Reykjavík' -> 'Reykjavik') but keep Greek letters and µ for the tables below
    t = "".join(c for c in unicodedata.normalize("NFD", text) if unicodedata.category(c) != "Mn")
    t = unicodedata.normalize("NFC", t)
    # I14 markers: numeric citations and parenthetical author-year citations are silent
    t = re.sub(r"\s*\[[0-9]+(?:\s*[,–-]\s*[0-9]+)*\]", "", t)
    t = re.sub(rf"\s*\((?!(?:{MONTHS})\b)(?:[A-Z][A-Za-z'’-]+(?: et al\.)?(?:,| and [A-Z][A-Za-z'’-]+,)? [0-9]{{4}}[a-z]?(?:; )?)+\)", "", t)
    for pat, rep in ABBREV:
        t = re.sub(pat, rep, t)
    # dotted initialisms: 'U.S.' -> 'U S'
    t = re.sub(r"\b((?:[A-Za-z]\.){2,})", lambda m: " ".join(m.group(1).replace(".", "").upper()) + " ", t)
    # codes mixing letters and digits with a capital inside ('HbA1c', 'CO2', 'D3') are spelled out
    t = re.sub(r"\b(?=[A-Za-z0-9]*[A-Z])(?=[A-Za-z0-9]*[0-9])[A-Za-z][A-Za-z0-9]*\b",
               lambda m: spell_code(m.group(0)) if not re.fullmatch(r"[A-Z][0-9]+", m.group(0)) else m.group(0)[0] + " " + m.group(0)[1:], t)
    # version-like numbers: 4.2.1 -> four point two point one
    t = re.sub(r"\b[0-9]+(?:\.[0-9]+){2,}\b", lambda m: " point ".join(number_words(x) for x in m.group(0).split(".")), t)
    # currency: $12.50, $1.2 billion, £3
    t = re.sub(rf"([$£€])\s?({NUM})(?:\s?(thousand|million|billion|trillion)\b)?",
               lambda m: currency_words(m.group(1), m.group(2), m.group(3) or ""), t)
    # statistics
    t = re.sub(r"\b95%\s*CI\b", "95 percent confidence interval", t)
    t = re.sub(r"\bCI\b", "confidence interval", t)
    t = re.sub(r"\b([pP])\s*=\s*", r"\1 equals ", t)
    t = re.sub(r"\b([pP])\s*<\s*", r"\1 less than ", t)
    t = re.sub(r"\b([pP])\s*>\s*", r"\1 greater than ", t)
    t = re.sub(r"\s=\s", " equals ", t)
    # minus sign before a number at the start of a word: '-5', '−5'
    t = re.sub(r"(^|[\s(])[-−](?=[0-9])", r"\1minus ", t)
    # ranges: 10–20, 10-20 -> 10 to 20 (not codes like COVID-19)
    t = re.sub(rf"({NUM})\s*[–—]\s*({NUM})", r"\1 to \2", t)
    t = re.sub(rf"(?<![\w.\-])({NUM})\s?-\s?({NUM})(?![\w\-])", r"\1 to \2", t)
    # units after a number (longest first)
    for u in sorted(UNITS, key=len, reverse=True):
        t = re.sub(rf"({NUM})\s?{re.escape(u)}(?![A-Za-z])", lambda m: m.group(1) + " " + UNITS[u], t)
    for u, w in SHORT_UNITS.items():
        t = re.sub(rf"({NUM}) {u}(?![A-Za-z'’])", lambda m: m.group(1) + " " + w, t)
    for g, w in GREEK.items():
        t = t.replace(g, " " + w + " ")
    for sym, w in SYMBOLS.items():
        t = t.replace(sym, w)
    # clock times: 11:45 -> eleven forty-five, 9:05 -> nine oh five
    t = re.sub(r"\b([0-9]{1,2}):([0-9]{2})\b", lambda m: int_words(int(m.group(1))) + " " + (
        "o'clock" if m.group(2) == "00" else ("oh " + ONES[int(m.group(2))]) if m.group(2)[0] == "0" else int_words(int(m.group(2)))), t)
    # decades: 1990s -> nineteen nineties, '90s -> nineties
    t = re.sub(r"\b(1[0-9]|20)([0-9])0s\b", lambda m: plural_words(year_words(int(m.group(1) + m.group(2) + "0"))), t)
    t = re.sub(r"['’]([1-9])0s\b", lambda m: plural_words(TENS[int(m.group(1))]), t)
    # years only where the context says year: 'in 1990', 'March 3, 2024', '(2019)', '2010 to 2015'
    Y = r"(1[1-9][0-9][0-9]|20[0-9][0-9])"
    t = re.sub(rf"\b{Y} to {Y}\b", lambda m: year_words(int(m.group(1))) + " to " + year_words(int(m.group(2))), t)
    t = re.sub(rf"\b((?i:{YEAR_CUE}))\s+{Y}\b(?![.,][0-9])", lambda m: m.group(1) + " " + year_words(int(m.group(2))), t)
    t = re.sub(rf"\({Y}\)", lambda m: "(" + year_words(int(m.group(1))) + ")", t)
    # ordinals
    t = re.sub(r"\b([0-9]+)(st|nd|rd|th)\b", lambda m: ordinal(int(m.group(1))), t)
    # digits glued to letters: '4K', '101A', '3D' -> '4 K'
    t = re.sub(rf"({NUM})([A-Za-z]+)\b", r"\1 \2", t)
    t = re.sub(rf"(?<![\w.]){NUM}(?![\w])", lambda m: number_words(m.group(0)), t)
    t = re.sub(r"\s*[\[\]()]\s*", ", ", t)
    t = re.sub(r"\s+,", ",", t)
    t = re.sub(r",(\s*,)+", ",", t)
    t = re.sub(r",\s*([.;:!?])", r"\1", t)
    t = re.sub(r"^,\s*|,\s*$", "", t)
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
