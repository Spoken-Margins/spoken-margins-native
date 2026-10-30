#!/usr/bin/env python3
"""Scores what an extractor would speak against role-labelled ground truth.

    python3 tools/score.py --extractor pymupdf-raw
    python3 tools/score.py --extractor app-baseline   # after the (Mac) run

Reads candidates from cache/candidates/<extractor>/<id>.json (the format
tools/reference_extract.py and the Mac CLI both write: {"id", "spoken", ...})
and ground truth from cache/gt/<id>.json. Writes results/<extractor>/scores.json.

How a PDF is scored
-------------------
1. Both sides are cut into word tokens (letters and digits, case-folded, NFKC,
   so ligatures and full-width forms match).
2. Every spoken token is aligned to a ground-truth token by shared 4-grams,
   preferring the position that continues the previous match, then extended
   one token at a time into gaps. Alignment is not monotone: a caption read
   early or a column read out of order still aligns, and shows up in the
   order metrics instead of as missing text.
3. Each spoken token takes the role of the ground-truth token it aligned to.
   Unaligned tokens are classified from their line: page furniture (repeated
   lines, page and line numbers), stamps and links, math, short fragments
   (figure labels, axis ticks), or unattributed prose.
4. Each citation and footnote marker in the ground truth is looked up where
   its neighbouring words landed, and the spoken text between them says how
   the marker was rendered: silent, "citation 12", a bare number, the
   author-year text, or digits glued onto the word.

What counts as clutter: references, tables, footnote text, front matter
(authors, affiliations, identifiers), back matter (funding, contributions,
competing interests), repeated text, page furniture, stamps, math read as
symbols and stray fragments. Captions and citation markers are reported on
their own lines, because whether they should be spoken is an I14 decision.
Unattributed prose is reported but not counted: it may be real text the
ground truth lacks (for example text inside a figure or a boxed note).
"""

from __future__ import annotations

import argparse
import difflib
import json
import re
import statistics
import sys
import unicodedata
from collections import Counter, defaultdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import i14  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
GT_DIR = ROOT / "cache" / "gt"
RESULTS = ROOT / "results"
# Extracted text is the papers' content: it stays in the git-ignored cache.
CANDIDATES = ROOT / "cache" / "candidates"
MANIFEST = ROOT / "corpus" / "manifest.json"

K = 4
BODY_ROLES = {"title", "heading", "abstract", "body"}
CLUTTER = ["reference", "table", "footnote", "front_matter", "back_matter", "repeated", "furniture",
           "stamp_link", "math", "equation", "fragment"]
WORD = re.compile(r"\w+", re.UNICODE)
SECONDS_PER_WORD = 60 / 155  # typical narration rate

# Listener cost, in seconds of listening lost or wasted. These are assumptions,
# stated so they can be argued with; the ranking is not very sensitive to them.
COST = {
    "clutter_word": SECONDS_PER_WORD,         # hearing a word that isn't the paper
    "missing_word": SECONDS_PER_WORD,         # a body word never heard
    "order_break": 10.0,                      # lost the thread; rewinds or gives up
    "mid_sentence_interruption": 4.0,         # plus the words of the interruption
    "marker_number_read": 1.5,                # "cells twelve were" — a moment of confusion
    "marker_glued": 2.0,                      # "cells12" read as a nonsense word
    "hyphen_break": 1.0,                      # "bio logy"
}


def norm(token: str) -> str:
    return unicodedata.normalize("NFKC", token).casefold()


def tokens_of(text: str) -> list[str]:
    return [norm(t) for t in WORD.findall(unicodedata.normalize("NFKC", text))]


# ---------------------------------------------------------------- ground truth

class Truth:
    def __init__(self, segments: list[dict]):
        self.tokens: list[str] = []
        self.roles: list[str] = []
        self.segment_of: list[int] = []
        self.sentence_end: list[bool] = []
        self.markers: list[dict] = []  # {"kind", "label", "before": gt index}
        self.segments = segments
        for index, seg in enumerate(segments):
            text = seg["text"]
            offsets = sorted(seg.get("markers", []), key=lambda m: m["at"])
            start = len(self.tokens)
            for match in WORD.finditer(unicodedata.normalize("NFKC", text)):
                self.tokens.append(norm(match.group()))
                self.roles.append(seg["role"])
                self.segment_of.append(index)
                following = text[match.end():match.end() + 3].lstrip(" )]\"'”’")
                self.sentence_end.append(following[:1] in (".", "!", "?", ":"))
            for marker in offsets:
                if marker["kind"] == "math":
                    continue
                before = start + len(WORD.findall(unicodedata.normalize("NFKC", text[:marker["at"]])))
                self.markers.append({"kind": marker["kind"], "label": marker["label"], "before": before,
                                     "role": seg["role"]})
        self.index: dict[tuple, list[int]] = defaultdict(list)
        for i in range(len(self.tokens) - K + 1):
            self.index[tuple(self.tokens[i:i + K])].append(i)
        self.vocab = set(self.tokens)


# ------------------------------------------------------------------ candidate

class Spoken:
    def __init__(self, text: str, vocab: set[str]):
        self.tokens: list[str] = []
        self.raw: list[str] = []
        self.line_of: list[int] = []
        self.glued: set[int] = set()
        self.hyphen_joins = 0
        self.lines = text.split("\n")
        pending = None  # first half of a word broken with "-" at a line end
        for line_no, line in enumerate(self.lines):
            words = WORD.findall(unicodedata.normalize("NFKC", line))
            if pending is not None and words:
                joined = pending + norm(words[0])
                if joined in vocab:
                    # Line-end hyphenation left unrepaired: listener hears two halves.
                    self.tokens[-1] = joined
                    self.raw[-1] = self.raw[-1] + words[0]
                    self.hyphen_joins += 1
                    words = words[1:]
            pending = None
            for word in words:
                token = norm(word)
                glued = re.fullmatch(r"([^\W\d_]{2,})(\d{1,3})", token)
                if glued and token not in vocab and glued.group(1) in vocab:
                    self._add(glued.group(1), word, line_no)
                    self._add(glued.group(2), glued.group(2), line_no)
                    self.glued.add(len(self.tokens) - 1)
                    continue
                self._add(token, word, line_no)
            if words and re.search(r"\w-\s*$", line):
                pending = self.tokens[-1]

    def _add(self, token, raw, line_no):
        self.tokens.append(token)
        self.raw.append(raw)
        self.line_of.append(line_no)


def align(truth: Truth, spoken: Spoken) -> list[int | None]:
    c = spoken.tokens
    pos: list[int | None] = [None] * len(c)
    used = Counter()
    previous = -10
    for i in range(len(c) - K + 1):
        if pos[i] is not None and pos[i] == previous + 1 and all(p is not None for p in pos[i:i + K - 1]):
            previous = pos[i]
            # The window is already inside a run; extend it if the next token continues.
            j = i + K - 1
            if pos[j] is None and pos[j - 1] is not None and pos[j - 1] + 1 < len(truth.tokens) \
                    and truth.tokens[pos[j - 1] + 1] == c[j]:
                pos[j] = pos[j - 1] + 1
                used[pos[j]] += 1
            continue
        candidates = truth.index.get(tuple(c[i:i + K]))
        if not candidates:
            continue
        if previous + 1 in candidates:
            p = previous + 1
        else:
            unused = [q for q in candidates if not used[q]]
            p = unused[0] if unused else candidates[0]
        for offset in range(K):
            if pos[i + offset] is None:
                pos[i + offset] = p + offset
                used[p + offset] += 1
        previous = p
    # Extend matched runs into neighbouring gaps one token at a time.
    changed = True
    while changed:
        changed = False
        for i in range(len(c)):
            if pos[i] is not None:
                continue
            if i > 0 and pos[i - 1] is not None:
                q = pos[i - 1] + 1
                if q < len(truth.tokens) and truth.tokens[q] == c[i]:
                    pos[i] = q
                    changed = True
                    continue
            if i + 1 < len(c) and pos[i + 1] is not None:
                q = pos[i + 1] - 1
                if q >= 0 and truth.tokens[q] == c[i]:
                    pos[i] = q
                    changed = True
    # Gaps between two anchors that move forward through the truth: align the
    # gap's words to the truth words in between (monotone, exact matches only).
    # Catches short pieces between inline formulas, which have no 4-gram.
    i = 0
    while i < len(c):
        if pos[i] is not None:
            i += 1
            continue
        j = i
        while j < len(c) and pos[j] is None:
            j += 1
        if 0 < i and j < len(c) and 0 < pos[j] - pos[i - 1] <= 400 and j - i <= 400:
            lo, hi = pos[i - 1] + 1, pos[j]
            matcher = difflib.SequenceMatcher(None, c[i:j], truth.tokens[lo:hi], autojunk=False)
            for block in matcher.get_matching_blocks():
                for offset in range(block.size):
                    pos[i + block.a + offset] = lo + block.b + offset
        i = j
    # Short substitutions (OCR slips, ligature misses) inside a continuous run.
    i = 0
    while i < len(c):
        if pos[i] is None:
            j = i
            while j < len(c) and pos[j] is None:
                j += 1
            if 0 < i and j < len(c) and j - i <= 2 and pos[j] - pos[i - 1] == j - i + 1:
                for g in range(i, j):
                    pos[g] = pos[i - 1] + (g - i + 1)
            i = j
        else:
            i += 1
    return pos


STAMP = re.compile(r"(?i)(doi|https?:|www\.|©|copyright|licen[cs]e|downloaded|creative\s*commons|"
                   r"received|accepted|published|open access|correspond|e-?mail|@|all rights reserved|"
                   r"preprint|arxiv|biorxiv|medrxiv|journal|vol\.|issn)")


def classify_lines(spoken: Spoken) -> dict[int, str]:
    """Class for unaligned tokens, decided per line."""
    shapes = Counter()
    for line in spoken.lines:
        key = re.sub(r"\d+", "#", line.strip().casefold())
        if key:
            shapes[key] += 1
    result = {}
    for line_no, line in enumerate(spoken.lines):
        stripped = line.strip()
        words = WORD.findall(stripped)
        key = re.sub(r"\d+", "#", stripped.casefold())
        if not words:
            continue
        symbols = sum(1 for ch in stripped if not ch.isalnum() and not ch.isspace())
        singles = sum(1 for w in words if len(w) == 1)
        if (shapes[key] >= 3 and len(words) <= 20) or re.fullmatch(r"(?i)(page\s*)?[\divxlc]+(\s*(of|/)\s*\d+)?", stripped):
            result[line_no] = "furniture"
        elif STAMP.search(stripped) and len(words) <= 40:
            result[line_no] = "stamp_link"
        elif symbols / max(1, len(stripped)) >= 0.2 or singles / len(words) >= 0.5:
            result[line_no] = "math"
        elif len(words) <= 3:
            result[line_no] = "fragment"
        else:
            result[line_no] = "unattributed_prose"
    return result


def line_alignment(spoken: Spoken, pos) -> dict[int, float]:
    totals, aligned = Counter(), Counter()
    for i, p in enumerate(pos):
        totals[spoken.line_of[i]] += 1
        if p is not None:
            aligned[spoken.line_of[i]] += 1
    return {line: aligned[line] / totals[line] for line in totals}


def enclosing_role(truth: Truth, pos, i: int, prev_aligned, next_aligned) -> str | None:
    a, b = prev_aligned[i], next_aligned[i]
    if a is None or b is None:
        return None
    left, right = truth.roles[pos[a]], truth.roles[pos[b]]
    if left == right and left not in BODY_ROLES and left != "caption":
        return left
    return None


def residue_is_math(spoken: Spoken, i: int) -> bool:
    raw = spoken.raw[i]
    return len(raw) <= 2 or any(ch.isdigit() for ch in raw) or any(0x370 <= ord(ch) <= 0x3FF for ch in raw)


REFERENCE_WORDS = {"ref", "refs"}  # what the app keeps as words (nonCitationAbbreviations)


def starts_list_item(spoken: Spoken, index: int) -> bool:
    """The spoken token opens a line that begins "12." or "12)" after a finished sentence: an ordered
    list's own number. After a line that stops mid-sentence it is a wrapped citation, "RCC" then "21. Our"."""
    if index > 0 and spoken.line_of[index - 1] == spoken.line_of[index]:
        return False
    if index == 0 or re.search(r"[.?!][)\]”\"’]*\s*$", spoken.lines[spoken.line_of[index - 1]]) is None:
        return False
    return re.match(r"\s*\d{1,3}[.)](?:\s|$)", spoken.lines[spoken.line_of[index]]) is not None


def names_a_reference(spoken: Spoken, index: int) -> bool:
    """The word at `index`, or the one before the numbers and "and" ending at it, is "ref" or "refs"."""
    while index >= 0 and (spoken.tokens[index].isdigit() or spoken.tokens[index] in ("and", "to")):
        index -= 1
    return index >= 0 and spoken.tokens[index] in REFERENCE_WORDS


def label_numbers(label: str) -> set[int]:
    """The entry numbers a printed citation names, ranges filled in: "7 27–29" is {7, 27, 28, 29}."""
    numbers = {int(n) for n in re.findall(r"\d+", label)}
    for a, b in re.findall(r"(\d+)\s*[–-]\s*(\d+)", label):
        if 0 < int(b) - int(a) <= 50:
            numbers.update(range(int(a), int(b) + 1))
    return numbers


def reads_the_label(words: list[str], label: str) -> bool:
    """The numbers spoken at the site are the citation's own: "7 27 29" for [7, 27–29], or "1 3" for an
    OCR'd [13]. A "5" from "5×", an equation's "2" or "0.2%" next to [106] is the sentence's, not the citation's (#1189)."""
    digits = []
    for w in words:
        if not w.isdigit():
            break
        digits.append(w)
    numbers = label_numbers(label)
    return any(int(d) in numbers for d in digits) or (len(digits) > 1 and int("".join(digits)) in numbers)


def render_marker(truth: Truth, spoken: Spoken, pos, first_at: dict[int, int], marker: dict, claimed: dict):
    """How was this marker spoken? Claims the spoken tokens that rendered it."""
    k = marker["before"]
    a = first_at.get(k - 1)
    if a is None:
        return "context_missing"
    b = a + 1
    # The gap runs to the next body word: an author-year citation can align
    # to the reference list by its words, but here it is a marker.
    while b < len(pos) and (pos[b] is None or truth.roles[pos[b]] not in BODY_ROLES):
        b += 1
    gap = list(range(a + 1, min(b, a + 1 + 12)))
    if not gap:
        return "silent"
    words = [spoken.tokens[g] for g in gap]
    kind = "citation_markers" if marker["kind"] == "citation" else "footnote_markers"
    if gap[0] in spoken.glued:
        claimed[gap[0]] = kind
        return "glued_number"
    if words[0] in ("citation", "footnote", "citations", "footnotes"):
        n = 1
        while n < len(words) and (words[n].isdigit() or words[n] == "to"):
            n += 1
        for g in gap[:n]:
            claimed[g] = kind
        return "spoken_label"
    label = tokens_of(marker["label"])
    # "Smith et al. (2020) showed": the app keeps the name in the sentence and so keeps its year.
    narrative_year = len(label) == 1 and re.fullmatch(r"(?:19|20)\d\d[a-z]?", label[0]) is not None
    if label and words[0] == label[0] and (narrative_year or not all(t.isdigit() for t in label)):
        # Author-year groups like "(Wang, Vinocur & Altman, 2003; Li et al., 2023)".
        allowed = set(label) | {"and", "et", "al", "e", "g", "see", "also"}
        n = 0
        while n < len(words) and words[n] in allowed:
            n += 1
        for g in gap[:n]:
            claimed[g] = kind
        return "label_read"
    if words[0].isdigit() and starts_list_item(spoken, gap[0]):
        # "2." opening the next line: the paper's own numbered list, not the citation (#1189).
        return "silent"
    if words[0].isdigit() and names_a_reference(spoken, a):
        # "described in ref. 70, using": the sentence names the reference, so the number is its grammar.
        n = 0
        while n < len(words) and (words[n].isdigit() or words[n] in ("and", "to")):
            n += 1
        for g in gap[:max(1, n)]:
            claimed[g] = kind
        return "named_read"
    if words[0].isdigit() and marker["kind"] == "citation" and re.fullmatch(r"(?:19|20)\d\d", words[0]) \
            and not reads_the_label(words, marker["label"]) \
            and re.search(rf"\b{words[0]}[a-z]?\s*[);]", spoken.lines[spoken.line_of[gap[0]]]):
        # "(Weber & Davis 1987)" printed where the ground truth numbers it [71]: the printed year was read.
        # A year in the next sentence ("[12]. 2020 was") is not in a bracket and is the sentence's.
        claimed[gap[0]] = kind
        return "label_read"
    if words[0].isdigit() and marker["kind"] == "citation" and not reads_the_label(words, marker["label"]):
        return "silent"
    if words[0].isdigit() or (len(words[0]) == 1 and marker["kind"] == "footnote"):
        n = 0
        while n < len(words) and (words[n].isdigit() or (n > 0 and words[n] in ("and",))):
            n += 1
        for g in gap[:max(1, n)]:
            claimed[g] = kind
        return "number_read"
    return "silent"


def marker_sites(truth: Truth, spoken: Spoken, pos, first_at: dict[int, int], claimed: dict):
    """Every body marker site with how it was spoken: (site, outcome) pairs.

    Markers with nothing but punctuation between them, like [3, 4] or
    (Li, 2020; Wu, 2021), are one site with the labels joined."""
    sites: dict[tuple, dict] = {}
    for marker in truth.markers:
        if marker["role"] not in BODY_ROLES:
            continue
        site = (marker["kind"], marker["before"])
        if site in sites:
            sites[site]["label"] += " " + marker["label"]
        else:
            sites[site] = dict(marker)
    for marker in sites.values():
        yield marker, render_marker(truth, spoken, pos, first_at, marker, claimed)


def categorize(truth: Truth, text: str):
    """Aligns and labels every spoken token. Returns (spoken, categories, positions)."""
    spoken, category, pos, *_ = _categorize(truth, text)
    return spoken, category, pos


def _categorize(truth: Truth, text: str):
    spoken = Spoken(text, truth.vocab)
    pos = align(truth, spoken)
    n = len(pos)
    first_at: dict[int, int] = {}
    duplicate = set()
    for i, p in enumerate(pos):
        if p is None:
            continue
        if p in first_at:
            duplicate.add(i)
        else:
            first_at[p] = i

    claimed: dict[int, str] = {}
    marker_outcomes = {"citation": Counter(), "footnote": Counter()}
    for marker, outcome in marker_sites(truth, spoken, pos, first_at, claimed):
        marker_outcomes[marker["kind"]][outcome] += 1

    line_class = classify_lines(spoken)
    aligned_share = line_alignment(spoken, pos)
    # Unaligned text before the abstract or body starts is the title page:
    # author lists with superscripts glued on, affiliations, journal banners.
    body_start = next((i for i, p in enumerate(pos) if p is not None and truth.roles[p] in ("abstract", "body")), len(pos))
    prev_aligned, next_aligned = [None] * len(pos), [None] * len(pos)
    last = None
    for i, p in enumerate(pos):
        prev_aligned[i] = last
        if p is not None:
            last = i
    last = None
    for i in range(len(pos) - 1, -1, -1):
        next_aligned[i] = last
        if pos[i] is not None:
            last = i
    category: list[str] = []
    for i, p in enumerate(pos):
        if i in claimed:
            category.append(claimed[i])
        elif p is None:
            kind = line_class.get(spoken.line_of[i], "fragment")
            enclosing = enclosing_role(truth, pos, i, prev_aligned, next_aligned)
            if enclosing and kind not in ("furniture", "stamp_link"):
                # Inside a reference list, table or footnote: same role as its neighbours.
                kind = enclosing
            elif aligned_share.get(spoken.line_of[i], 0) >= 0.5:
                # Leftovers inside a line that is mostly body text.
                kind = "math" if residue_is_math(spoken, i) else "inline_residue"
            elif i < body_start and kind not in ("furniture", "stamp_link"):
                kind = "front_matter"
            category.append(kind)
        elif i in duplicate:
            category.append("repeated")
        else:
            role = truth.roles[p]
            category.append("body" if role in BODY_ROLES else role)
    # I14 announcements ("References skipped.", "Figure 2.") are the app
    # telling the listener what it skipped: not clutter, not body.
    for i in range(len(category)):
        if is_announcement(spoken.lines[spoken.line_of[i]]):
            category[i] = "announcement"
    return spoken, category, pos, first_at, marker_outcomes


FLOAT_LABEL = re.compile(r"(?i)^(?:figure|fig\.?|table|scheme|box|chart)\s*s?\d+[a-z]?\.$")


def is_announcement(line: str) -> bool:
    line = line.strip()
    return line in i14.ANNOUNCEMENTS or bool(FLOAT_LABEL.match(line))


def score(truth: Truth, text: str) -> dict:
    spoken, category, pos, first_at, marker_outcomes = _categorize(truth, text)
    n = len(pos)
    counts = Counter(category)

    body_total = sum(1 for r in truth.roles if r in BODY_ROLES)
    body_covered = sum(1 for p in first_at if truth.roles[p] in BODY_ROLES)

    # Reading order: consecutive body tokens that jump to text read elsewhere.
    order_breaks = 0
    body_seq = [(i, pos[i]) for i in range(n) if category[i] == "body"]
    for (i0, p0), (i1, p1) in zip(body_seq, body_seq[1:]):
        if p1 == p0 + 1:
            continue
        if p1 < p0 - 3:
            order_breaks += 1
        elif p1 > p0 + 1:
            skipped = [q for q in range(p0 + 1, p1) if truth.roles[q] in BODY_ROLES]
            if skipped and any(q in first_at and first_at[q] > i1 for q in skipped):
                order_breaks += 1

    # Interruptions: 3+ spoken non-body tokens where the body flow continues across them.
    interruptions = Counter()
    mid_sentence = Counter()
    for (i0, p0), (i1, p1) in zip(body_seq, body_seq[1:]):
        if i1 - i0 - 1 < 3 or p1 != p0 + 1:
            continue
        run = Counter(category[i0 + 1:i1])
        # Markers and inline math sit where the truth has them; they cost as
        # words, not as an interruption of the sentence.
        for in_place in ("citation_markers", "footnote_markers", "math", "inline_residue"):
            run.pop(in_place, None)
        if sum(run.values()) < 3:
            continue
        kind = run.most_common(1)[0][0]
        interruptions[kind] += 1
        if not truth.sentence_end[p0]:
            mid_sentence[kind] += 1

    # Figures and tables.
    captions = [(i, s) for i, s in enumerate(truth.segments) if s["role"] == "caption"]
    tables = [(i, s) for i, s in enumerate(truth.segments) if s["role"] == "table"]
    seg_tokens = defaultdict(list)
    for q, seg in enumerate(truth.segment_of):
        seg_tokens[seg].append(q)
    def covered(seg_index):
        qs = seg_tokens.get(seg_index, [])
        return sum(1 for q in qs if q in first_at) / len(qs) if qs else 0.0
    captions_read = sum(1 for i, _ in captions if covered(i) >= 0.5)
    tables_read = sum(1 for i, _ in tables if covered(i) >= 0.3)

    clutter = sum(counts[c] for c in CLUTTER)
    spoken_body = counts["body"]
    missing = body_total - body_covered
    cost = {c: counts[c] * COST["clutter_word"] for c in CLUTTER}
    cost["missing_body"] = missing * COST["missing_word"]
    cost["reading_order"] = order_breaks * COST["order_break"]
    cost["mid_sentence_interruptions"] = sum(mid_sentence.values()) * COST["mid_sentence_interruption"]
    markers_read = counts["citation_markers"] + counts["footnote_markers"]
    cost["markers_read_aloud"] = (markers_read * COST["clutter_word"]
                                  + sum(marker_outcomes[k]["number_read"] for k in marker_outcomes) * COST["marker_number_read"]
                                  + sum(marker_outcomes[k]["glued_number"] for k in marker_outcomes) * COST["marker_glued"])
    cost["hyphen_breaks"] = spoken.hyphen_joins * COST["hyphen_break"]
    return {
        "spoken_words": n,
        "body_words_truth": body_total,
        "clutter_rate": round(clutter / n, 4) if n else None,
        "missing_body_rate": round(missing / body_total, 4) if body_total else None,
        "body_share_of_spoken": round(spoken_body / n, 4) if n else None,
        "words_by_category": dict(counts),
        "order_breaks": order_breaks,
        "order_breaks_per_1000_body_words": round(1000 * order_breaks / max(1, spoken_body), 2),
        "interruptions": dict(interruptions),
        "mid_sentence_interruptions": dict(mid_sentence),
        "hyphen_breaks": spoken.hyphen_joins,
        "citations": dict(marker_outcomes["citation"]),
        # I14: numeric and parenthetical citations and footnote markers are silent.
        "markers_silent_share": silent_share(marker_outcomes),
        "footnote_markers": dict(marker_outcomes["footnote"]),
        "captions": {"total": len(captions), "read": captions_read},
        "tables": {"total": len(tables), "cells_read_aloud": tables_read},
        "listener_cost_seconds": {k: round(v, 1) for k, v in cost.items()},
    }


def silent_share(outcomes: dict) -> float | None:
    """Of the marker sites that could be judged, the share spoken as I14 asks: not at all."""
    judged = sum(n for kind in outcomes.values() for outcome, n in kind.items() if outcome != "context_missing")
    silent = sum(kind.get("silent", 0) for kind in outcomes.values())
    return round(silent / judged, 4) if judged else None


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--extractor", required=True)
    parser.add_argument("--only", nargs="*")
    args = parser.parse_args()
    manifest = json.loads(MANIFEST.read_text())
    out_dir = RESULTS / args.extractor
    out_dir.mkdir(parents=True, exist_ok=True)
    results = {}
    for entry in manifest["entries"]:
        if args.only and entry["id"] not in args.only:
            continue
        cand_path = CANDIDATES / args.extractor / f"{entry['id']}.json"
        gt_path = GT_DIR / f"{entry['id']}.json"
        if not cand_path.exists() or not gt_path.exists():
            print(f"skip {entry['id']}: missing {'candidate' if not cand_path.exists() else 'ground truth'}", file=sys.stderr)
            continue
        candidate = json.loads(cand_path.read_text())
        truth = Truth(json.loads(gt_path.read_text())["segments"])
        text = candidate.get("spoken") or candidate.get("markdown") or ""
        result = score(truth, text) if text.strip() else {
            "spoken_words": 0, "body_words_truth": sum(1 for r in truth.roles if r in BODY_ROLES),
            "clutter_rate": None, "missing_body_rate": 1.0, "error": candidate.get("error", "no text"),
            "listener_cost_seconds": {"missing_body": round(sum(1 for r in truth.roles if r in BODY_ROLES) * COST["missing_word"], 1)},
        }
        result["tags"] = entry["tags"]
        result["elapsed_ms"] = candidate.get("elapsed_ms")
        results[entry["id"]] = result
        print(f"{entry['id']:40s} clutter {result['clutter_rate']}  missing {result['missing_body_rate']}  "
              f"order {result.get('order_breaks')}")
    clutter = [r["clutter_rate"] for r in results.values() if r["clutter_rate"] is not None]
    missing = [r["missing_body_rate"] for r in results.values() if r["missing_body_rate"] is not None]
    summary = {
        "extractor": args.extractor,
        "papers": len(results),
        "median_clutter_rate": round(statistics.median(clutter), 4) if clutter else None,
        "median_missing_body_rate": round(statistics.median(missing), 4) if missing else None,
        "cost_model": COST,
    }
    if args.only:
        return  # a partial run never replaces the corpus scores
    (out_dir / "scores.json").write_text(json.dumps({"summary": summary, "papers": results}, indent=1) + "\n")
    print(json.dumps(summary, indent=1))


if __name__ == "__main__":
    main()
