#!/usr/bin/env python3
"""C1 M2: a cheap pre-check that predicts which PDFs will sound bad.

    python3 tools/precheck.py

Fits a threshold rule on the corpus and reports recall on the hard papers
and false alarms, in sample and leave-one-out. With the app's own output in
cache/candidates/app-baseline/ (a Mac run), it writes
results/app-baseline/precheck.json (numbers only). Otherwise it uses a proxy
for the app's text and writes cache/precheck-proxy.json, which is not a result.

Features use only what PDFKit gives before playback without Vision or
rendering: each page's text, and each text line with its bounds. The Swift
port (mac/…/PDFListeningPrecheck.swift) computes the same numbers the same
way; this file is the reference for both.

"Hard" is the bottom quintile of results/app-baseline/scores.json by listener
cost per minute of body text, plus any PDF with no text layer.
"""

from __future__ import annotations

import json
import re
import statistics
import sys
import unicodedata
from pathlib import Path

import pymupdf

ROOT = Path(__file__).resolve().parents[1]
PDF_DIR = ROOT / "cache" / "pdf"
TARGET = "app-baseline"
WORD = re.compile(r"\w+", re.UNICODE)
SAMPLE_PAGES = 12  # a cheap check reads at most this many pages, spread through the document


def is_mathy(ch: str) -> bool:
    """Math operators, Greek, and math alphanumerics: what equations leave in a text layer."""
    code = ord(ch)
    return (unicodedata.category(ch) == "Sm" or 0x370 <= code <= 0x3FF or 0x1D400 <= code <= 0x1D7FF
            or 0x2200 <= code <= 0x22FF)


def sample_indices(page_count: int) -> list[int]:
    if page_count <= SAMPLE_PAGES:
        return list(range(page_count))
    step = page_count / SAMPLE_PAGES
    return sorted({int(i * step) for i in range(SAMPLE_PAGES)})


def lines_of(page) -> list[tuple[str, tuple]]:
    out = []
    for block in page.get_text("dict")["blocks"]:
        for line in block.get("lines", []):
            text = "".join(span["text"] for span in line["spans"]).strip()
            if text:
                out.append((text, line["bbox"]))
    return out


def features(path: Path) -> dict:
    doc = pymupdf.open(path)
    pages = sample_indices(doc.page_count)
    letters = mathy = tokens = single_letters = lines_total = short_lines = hyphen_ends = 0
    narrow_lines = right_half_lines = chars = 0
    for index in pages:
        page = doc[index]
        width = page.rect.width
        for text, (x0, _, x1, _) in lines_of(page):
            lines_total += 1
            words = WORD.findall(text)
            chars += sum(1 for ch in text if not ch.isspace())
            letters += sum(1 for ch in text if ch.isalpha())
            mathy += sum(1 for ch in text if is_mathy(ch))
            tokens += len(words)
            single_letters += sum(1 for w in words if len(w) == 1 and w.isalpha() and w not in ("a", "A", "I"))
            if len(words) <= 3:
                short_lines += 1
            if re.search(r"\w-$", text):
                hyphen_ends += 1
            if len(words) >= 5 and (x1 - x0) < 0.48 * width:
                narrow_lines += 1
                if x0 >= 0.45 * width:
                    right_half_lines += 1
    long_lines = max(1, lines_total - short_lines)
    return {
        "pages": doc.page_count,
        "chars_per_page": round(chars / max(1, len(pages))),
        "math_share": round(mathy / max(1, letters + mathy), 4),
        "single_letter_share": round(single_letters / max(1, tokens), 4),
        "short_line_share": round(short_lines / max(1, lines_total), 4),
        "hyphen_end_share": round(hyphen_ends / long_lines, 4),
        "two_column_share": round(right_half_lines / long_lines, 4),
    }


# ---- features of the extracted text (what the app would speak) -----------

REFERENCES_HEADING = re.compile(r"(?i)^(?:#{1,6}\s*)?(?:[0-9]+[. ]+)?(?:references|bibliography|works cited)\s*$")
RECORD_START = re.compile(r"^\s*(?:\[\^?[0-9]+\]:?|[0-9]+[.)])\s+\S")
RECORD_BODY = re.compile(r"(?i)\b(?:19|20)[0-9]{2}\b.*(?:doi|journal|press|https?://)")
YEAR = re.compile(r"\b(?:19|20)[0-9]{2}\b")


def app_listening_markdown(markdown: str) -> str:
    """Python port of PDFStructuredTextExtractor.listeningMarkdown (the app's
    reference-list cut), used to approximate the app's output in the cloud."""
    lines = markdown.split("\n")
    for index, line in enumerate(lines):
        if index == 0 or not REFERENCES_HEADING.match(line.strip()):
            continue
        tail = [l for l in lines[index + 1:] if l.strip()][:40]
        records = [l for l in tail if RECORD_START.search(l) or RECORD_BODY.search(l)]
        if len(records) >= 3 and sum(1 for l in tail if YEAR.search(l)) >= 3:
            return "\n".join(lines[:index]).strip()
    return markdown


# A line that looks like a bibliography entry: a year plus a citation cue.
BIB_LINE = re.compile(r"(?i)(?:\b(?:19|20)\d{2}[a-z]?\b.*(?:\bet al\b|doi|\bvol\b|\bpp\b|journal|proc\b|"
                      r"conference|press|arxiv|\d+\s*[:(]\s*\d+))|(?:doi\.org|^\s*\[\d+\]\s+[A-Z])")


def text_features(text: str) -> dict:
    lines = [l.strip() for l in text.split("\n") if l.strip()]
    tokens = WORD.findall(text)
    if not lines or not tokens:
        return {"words": 0, "bib_line_share": 0.0, "numeric_line_share": 0.0, "text_single_letter_share": 0.0}
    numeric = 0
    for line in lines:
        words = WORD.findall(line)
        if words and sum(1 for w in words if any(ch.isdigit() for ch in w)) / len(words) >= 0.5:
            numeric += 1
    tail = lines[len(lines) // 2:]  # reference lists sit in the second half
    return {
        "words": len(tokens),
        "bib_line_share": round(sum(1 for l in tail if BIB_LINE.search(l)) / len(tail), 4),
        "numeric_line_share": round(numeric / len(lines), 4),
        "text_single_letter_share": round(sum(1 for w in tokens if len(w) == 1 and w.isalpha() and w not in ("a", "A", "I"))
                                          / len(tokens), 4),
    }


def burden(result: dict) -> float:
    body_minutes = max(1e-9, result["body_words_truth"] / 155)
    return sum(result.get("listener_cost_seconds", {}).values()) / 60 / body_minutes


def labels() -> dict[str, bool]:
    papers = json.loads((ROOT / "results" / TARGET / "scores.json").read_text())["papers"]
    ranked = sorted(papers, key=lambda pid: -burden(papers[pid]))
    hard = set(ranked[: round(len(ranked) / 5)])
    hard |= {pid for pid, r in papers.items() if r.get("spoken_words", 0) == 0}
    return {pid: pid in hard for pid in papers}


def approximate_app_text(pid: str, path: Path) -> tuple[str, str]:
    """The app's own output when a Mac run left it in the cache, else PyMuPDF
    text with the app's reference cut applied."""
    app = ROOT / "cache" / "candidates" / "app-baseline" / f"{pid}.json"
    if app.exists():
        return json.loads(app.read_text()).get("markdown") or "", "app"
    with pymupdf.open(path) as doc:
        return app_listening_markdown("\n".join(page.get_text("text") for page in doc)), "proxy"


# Features the rule may use, and which side is "hard".
RULE_FEATURES = {
    "words_per_page": "low",            # no text layer, or almost none
    "text_single_letter_share": "high", # math read as letters
    "bib_line_share": "high",           # reference list left in the text
    "numeric_line_share": "high",       # table cells in the text
    "two_column_share": "high",         # column interleaving risk
    "short_line_share": "high",         # fragments: figure labels, captions, math lines
}
FALSE_ALARM_BUDGET = 0.10  # of easy papers
# A PDF with (almost) no text layer is hard by definition: the listener hears nothing.
FIXED_RULE = {"words_per_page": 20.0}


def flags(row: dict, rule: dict) -> bool:
    for key, threshold in rule.items():
        value = row[key]
        if (RULE_FEATURES[key] == "low" and value <= threshold) or (RULE_FEATURES[key] == "high" and value >= threshold):
            return True
    return False


def fit(rows: dict) -> dict:
    """Greedy OR-of-thresholds: keep adding the one threshold that catches the
    most still-missed hard papers without taking false alarms past budget."""
    easy_count = sum(1 for r in rows.values() if not r["hard"])
    budget = int(FALSE_ALARM_BUDGET * easy_count)
    rule: dict = dict(FIXED_RULE)
    while True:
        caught = {pid for pid, r in rows.items() if r["hard"] and flags(r, rule)}
        alarms = {pid for pid, r in rows.items() if not r["hard"] and flags(r, rule)}
        best = None
        for key, side in RULE_FEATURES.items():
            if key in rule:
                continue
            values = sorted({r[key] for r in rows.values()})
            # Thresholds sit halfway between neighbouring observed values, so a
            # paper at the edge isn't what defines the edge.
            for threshold in [round((a + b) / 2, 4) for a, b in zip(values, values[1:])]:
                trial = {**rule, key: threshold}
                new_caught = {pid for pid, r in rows.items() if r["hard"] and flags(r, trial)} - caught
                new_alarms = {pid for pid, r in rows.items() if not r["hard"] and flags(r, trial)} - alarms
                if not new_caught or len(alarms) + len(new_alarms) > budget:
                    continue
                score = (len(new_caught), -len(new_alarms))
                if best is None or score > best[0]:
                    best = (score, key, threshold)
        if best is None:
            return rule
        rule[best[1]] = best[2]


def evaluate(rows: dict, predicted: dict[str, bool]) -> dict:
    hard = [pid for pid, r in rows.items() if r["hard"]]
    easy = [pid for pid, r in rows.items() if not r["hard"]]
    flagged = [pid for pid in rows if predicted[pid]]
    caught = sum(1 for pid in hard if predicted[pid])
    alarms = sum(1 for pid in easy if predicted[pid])
    return {
        "hard": len(hard), "caught": caught, "recall": round(caught / max(1, len(hard)), 3),
        "easy": len(easy), "false_alarms": alarms, "false_alarm_rate": round(alarms / max(1, len(easy)), 3),
        "flagged": len(flagged), "share_of_flags_wrong": round(alarms / max(1, len(flagged)), 3),
        "missed": sorted(pid for pid in hard if not predicted[pid]),
        "false_alarm_papers": sorted(pid for pid in easy if predicted[pid]),
    }


def main() -> None:
    truth = labels()
    rows = {}
    sources = set()
    for pid in truth:
        path = PDF_DIR / f"{pid}.pdf"
        if not path.exists():
            print(f"skip {pid}: not fetched", file=sys.stderr)
            continue
        text, source = approximate_app_text(pid, path)
        sources.add(source)
        row = {**features(path), **text_features(text), "hard": truth[pid]}
        row["words_per_page"] = round(row["words"] / max(1, row["pages"]), 1)
        rows[pid] = row
    rule = fit(rows)
    in_sample = evaluate(rows, {pid: flags(r, rule) for pid, r in rows.items()})
    # Leave-one-out: fit without each paper, then predict it.
    loo = {}
    for pid in rows:
        rest = {k: v for k, v in rows.items() if k != pid}
        loo[pid] = flags(rows[pid], fit(rest))
    held_out = evaluate(rows, loo)
    source = "app-baseline markdown" if sources == {"app"} else "proxy: PyMuPDF text + Python port of the app's reference cut"
    result = {"text_source": source, "rule": rule, "in_sample": in_sample, "leave_one_out": held_out,
              "papers": {pid: {**r, "flagged": flags(r, rule)} for pid, r in rows.items()}}
    # Only the app's own text gives a result worth committing; a proxy run stays in the cache.
    out = ROOT / "results" / TARGET / "precheck.json" if sources == {"app"} else ROOT / "cache" / "precheck-proxy.json"
    out.write_text(json.dumps(result, indent=1) + "\n")
    print(f"text source: {source}")
    print(f"rule: {rule}")
    for name, ev in (("in sample", in_sample), ("leave-one-out", held_out)):
        print(f"{name:14s} caught {ev['caught']}/{ev['hard']} ({ev['recall']:.0%}), false alarms {ev['false_alarms']}/{ev['easy']} "
              f"({ev['false_alarm_rate']:.0%} of easy papers, {ev['share_of_flags_wrong']:.0%} of flags)")
    print(f"missed (leave-one-out): {held_out['missed']}")
    print(f"wrote {out}")


if __name__ == "__main__":
    main()
