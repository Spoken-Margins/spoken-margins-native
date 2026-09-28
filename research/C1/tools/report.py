#!/usr/bin/env python3
"""Writes results/REPORT.md from every results/<extractor>/scores.json present.

    python3 tools/report.py
"""

from __future__ import annotations

import json
import statistics
from collections import Counter, defaultdict
from pathlib import Path

import sys
sys.path.insert(0, str(Path(__file__).resolve().parent))
import score  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
RESULTS = ROOT / "results"
MANIFEST = ROOT / "corpus" / "manifest.json"
ORDER = ["app-baseline", "pymupdf-raw", "pdfminer", "gt-i14"]
# Not an extractor: ground truth projected through I14 (tools/i14.py). It is
# the floor a perfect extractor could reach under I14's rules.
NOTES = {"gt-i14": "ground truth spoken per I14: the floor for M3"}

PLAIN = {
    "reference": "Reference list read aloud",
    "missing_body": "Body text missing (never spoken)",
    "table": "Table cells read aloud",
    "math": "Math read as symbols and letters",
    "equation": "Display equations read aloud",
    "furniture": "Page furniture: running headers, footers, page and line numbers",
    "repeated": "Repeated text (running titles, duplicated lines)",
    "back_matter": "Back matter: funding, contributions, competing interests, reviewer reports",
    "front_matter": "Title-page matter: authors, affiliations, identifiers",
    "stamp_link": "Stamps, licences and links",
    "fragment": "Stray fragments: figure labels, axis ticks",
    "footnote": "Footnote text read inline",
    "reading_order": "Reading order broken (columns, floats)",
    "mid_sentence_interruptions": "Mid-sentence interruptions (captions, footers inside a sentence)",
    "markers_read_aloud": "Citation and footnote markers read as numbers or names",
    "hyphen_breaks": "Line-end hyphenation left in (\"bio- logy\")",
}


def load() -> dict[str, dict]:
    runs = {}
    for path in sorted(RESULTS.glob("*/scores.json")):
        runs[path.parent.name] = json.loads(path.read_text())
    return dict(sorted(runs.items(), key=lambda kv: ORDER.index(kv[0]) if kv[0] in ORDER else 99))


def median(values):
    values = [v for v in values if v is not None]
    return statistics.median(values) if values else None


def fmt_ms(value):
    return "–" if value is None else f"{value:.0f} ms"


def pct(value):
    return "–" if value is None else f"{100 * value:.1f}%"


def cost_table(papers: dict) -> list[tuple]:
    totals, per_paper, affected = Counter(), defaultdict(list), Counter()
    for result in papers.values():
        for key, seconds in result.get("listener_cost_seconds", {}).items():
            totals[key] += seconds
            per_paper[key].append(seconds)
            if seconds >= 30:
                affected[key] += 1
    rows = []
    for key, seconds in totals.most_common():
        values = per_paper[key] + [0] * (len(papers) - len(per_paper[key]))
        rows.append((key, seconds / 60, statistics.median(values) / 60, affected[key]))
    return rows


def extractor_section(name: str, run: dict, manifest: dict) -> list[str]:
    papers = run["papers"]
    lines = [f"## {name}", ""]
    failed = [pid for pid, r in papers.items() if r.get("spoken_words", 0) == 0]
    scored = {pid: r for pid, r in papers.items() if pid not in failed}
    total_spoken = sum(r["spoken_words"] for r in scored.values())
    lines += [
        f"- Papers scored: {len(papers)}; produced no text: {len(failed)} ({', '.join(failed) or 'none'})",
        f"- Median clutter rate: **{pct(run['summary']['median_clutter_rate'])}** of spoken words",
        f"- Median missing body text: **{pct(run['summary']['median_missing_body_rate'])}**",
        f"- Median reading-order breaks: {median([r['order_breaks_per_1000_body_words'] for r in scored.values()]):.2f} per 1000 body words",
        f"- Median extraction time: {fmt_ms(median([r.get('elapsed_ms') for r in papers.values()]))}",
        "",
        "### Failure categories ranked by listener cost",
        "",
        "Cost is listening time wasted or lost, summed over the corpus (cost model below).",
        "\"Papers ≥ 30 s\" counts papers where the category costs a listener half a minute or more.",
        "",
        "| Rank | Category | Corpus total (min) | Median per paper (min) | Papers ≥ 30 s |",
        "| ---: | --- | ---: | ---: | ---: |",
    ]
    for rank, (key, total, med, affected) in enumerate(cost_table(papers), 1):
        lines.append(f"| {rank} | {PLAIN.get(key, key)} | {total:.0f} | {med:.1f} | {affected} |")
    words = Counter()
    for r in scored.values():
        words.update(r.get("words_by_category", {}))
    lines += ["", "### Where the spoken words came from", "",
              "| Category | Words | Share of spoken |", "| --- | ---: | ---: |"]
    for key, count in words.most_common():
        lines.append(f"| {key} | {count} | {pct(count / total_spoken)} |")
    lines += ["", "`unattributed_prose` and `inline_residue` are not counted as clutter: they may be "
              "real text the ground truth lacks (text inside figures, code listings LaTeXML dropped) or "
              "body words garbled by the extractor.", ""]

    # Markers, captions, tables.
    citations, footnotes = Counter(), Counter()
    captions = tables = captions_read = tables_read = 0
    interruptions = Counter()
    hyphens = 0
    for r in scored.values():
        citations.update(r.get("citations", {}))
        footnotes.update(r.get("footnote_markers", {}))
        captions += r.get("captions", {}).get("total", 0)
        captions_read += r.get("captions", {}).get("read", 0)
        tables += r.get("tables", {}).get("total", 0)
        tables_read += r.get("tables", {}).get("cells_read_aloud", 0)
        interruptions.update(r.get("mid_sentence_interruptions", {}))
        hyphens += r.get("hyphen_breaks", 0)
    def outcome_line(counter):
        total = sum(counter.values()) or 1
        return ", ".join(f"{k.replace('_', ' ')} {v} ({100 * v / total:.0f}%)" for k, v in counter.most_common())
    lines += [
        "### Citations, footnotes, figures and tables", "",
        f"- Citation markers ({sum(citations.values())} sites): {outcome_line(citations)}",
        f"- Footnote markers ({sum(footnotes.values())} sites): {outcome_line(footnotes)}",
        f"- Figure and table captions: {captions_read} of {captions} read aloud (≥ half their words spoken)",
        f"- Tables: {tables_read} of {tables} had their cells read aloud (≥ 30% of cell words)",
        f"- Mid-sentence interruptions by what interrupted: {dict(interruptions.most_common()) or 'none'}",
        f"- Line-end hyphenation left unrepaired: {hyphens} words",
        "",
        "Marker outcomes: *silent* (nothing spoken between the words around it), *spoken label* "
        "(\"citation 12\", the app's normalizer), *number read* (\"cells 12 divide\"), *glued number* "
        "(\"cells12\"), *label read* (the author-year text read in full), *context missing* (the "
        "neighbouring words weren't spoken, so the marker can't be judged).",
        "",
    ]

    # By format.
    by_tag = defaultdict(list)
    for pid, r in papers.items():
        for tag in r.get("tags", []):
            by_tag[tag].append(r)
    lines += ["### By format", "",
              "| Format | Papers | Median clutter | Median missing | Median order breaks /1000 |",
              "| --- | ---: | ---: | ---: | ---: |"]
    for tag, rs in sorted(by_tag.items(), key=lambda kv: -len(kv[1])):
        order = median([r.get("order_breaks_per_1000_body_words") for r in rs])
        lines.append(f"| {tag} | {len(rs)} | {pct(median([r['clutter_rate'] for r in rs]))} | "
                     f"{pct(median([r['missing_body_rate'] for r in rs]))} | {'–' if order is None else f'{order:.2f}'} |")

    # Worst papers: bottom quintile by total cost per minute of body text (M2's target).
    def burden(r):
        body_minutes = max(1e-9, r["body_words_truth"] / 155)
        return sum(r.get("listener_cost_seconds", {}).values()) / 60 / body_minutes
    ranked = sorted(papers.items(), key=lambda kv: -burden(kv[1]))
    quintile = ranked[: max(1, round(len(ranked) / 5))]
    lines += ["", "### Bottom quintile (M2 target)", "",
              "Ranked by listener cost per minute of real body text.", "",
              "| Paper | Formats | Cost per body minute | Clutter | Missing |", "| --- | --- | ---: | ---: | ---: |"]
    for pid, r in quintile:
        lines.append(f"| {pid} | {', '.join(r.get('tags', []))} | {burden(r):.2f} | {pct(r['clutter_rate'])} | "
                     f"{pct(r['missing_body_rate'])} |")
    lines.append("")
    return lines


def comparison(runs: dict) -> list[str]:
    lines = ["## Comparison", "",
             "| Extractor | Median clutter | Median missing | Markers silent (I14) | No text |",
             "| --- | ---: | ---: | ---: | ---: |"]
    for name, run in runs.items():
        none = sum(1 for r in run["papers"].values() if r.get("spoken_words", 0) == 0)
        silent = median([r.get("markers_silent_share", score.silent_share(
            {"citation": r.get("citations", {}), "footnote": r.get("footnote_markers", {})}))
            for r in run["papers"].values()])
        label = f"{name} ({NOTES[name]})" if name in NOTES else name
        lines.append(f"| {label} | {pct(run['summary']['median_clutter_rate'])} | "
                     f"{pct(run['summary']['median_missing_body_rate'])} | {pct(silent)} | {none} |")
    return lines + [""]


def corpus_section(manifest: dict) -> list[str]:
    entries = manifest["entries"]
    tags = Counter(t for e in entries for t in e["tags"])
    pmc_publishers = sorted({e["publisher"] for e in entries if e["source"] == "pmc"})
    return [
        "## Corpus", "",
        f"{len(entries)} PDFs: {sum(e['source'] == 'pmc' for e in entries)} from PubMed Central "
        f"({len(pmc_publishers)} publishers) and {sum(e['source'] == 'arxiv' for e in entries)} from arXiv "
        f"({len({e['venue'] for e in entries if e['source'] == 'arxiv'})} formats). "
        "Ground truth: JATS XML for PMC, arXiv's LaTeXML rendering of the same LaTeX version for arXiv.",
        "",
        "Formats: " + ", ".join(f"{k} {v}" for k, v in tags.most_common()) + ".",
        "",
        "Publishers: " + "; ".join(pmc_publishers) + ".",
        "",
    ]


def main() -> None:
    manifest = json.loads(MANIFEST.read_text())
    runs = load()
    first = next(iter(runs.values()))
    lines = [
        "# C1 baseline report",
        "",
        "Generated by `tools/report.py` from `results/*/scores.json`. Don't edit by hand.",
        "",
    ]
    lines += corpus_section(manifest)
    lines += comparison(runs)
    for name, run in runs.items():
        lines += extractor_section(name, run, manifest)
    cost = first["summary"]["cost_model"]
    lines += [
        "## Cost model", "",
        "Assumptions, stated so they can be argued with: narration at 155 words per minute, so every "
        f"clutter word costs {cost['clutter_word']:.2f} s and every missing body word the same. A reading-order "
        f"break costs {cost['order_break']:.0f} s (the listener loses the thread), a mid-sentence interruption "
        f"{cost['mid_sentence_interruption']:.0f} s on top of its words, a citation read as a bare number "
        f"{cost['marker_number_read']} s, a number glued to a word {cost['marker_glued']} s, an unrepaired "
        f"hyphenation {cost['hyphen_break']:.0f} s.", "",
    ]
    (RESULTS / "REPORT.md").write_text("\n".join(lines))
    print(f"wrote {RESULTS / 'REPORT.md'}")


if __name__ == "__main__":
    main()
