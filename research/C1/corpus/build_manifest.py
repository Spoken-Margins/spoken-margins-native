#!/usr/bin/env python3
"""Selects the C1 PDF corpus and writes corpus/manifest.json.

The manifest holds URLs and licenses only; PDFs and ground truth are fetched
into research/C1/cache/ by tools/fetch.py. Selection is deterministic for a
given day's search results, and the committed manifest is the record: rerun
this only to rebuild the corpus on purpose.

Two sources, both with machine-readable ground truth:

- PubMed Central open access (pmc-oa-opendata S3 bucket): the publisher's PDF
  plus JATS XML with body, captions, footnotes, tables and references tagged.
  Covers journals across publishers, author manuscripts, and scanned 1960s
  NBS papers whose PDFs are page images with an OCR text layer.
- arXiv: the PDF compiled from the authors' LaTeX plus arXiv's own HTML
  rendering of that same LaTeX source (LaTeXML), pinned to the same version.
  Covers conference papers (ACL, CVPR, ICML two-column; NeurIPS single),
  physics and astronomy journal styles, math-heavy papers and PhD theses.
"""

from __future__ import annotations

import json
import re
import sys
import urllib.parse
import xml.etree.ElementTree as ET
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
import net  # noqa: E402

MANIFEST = Path(__file__).with_name("manifest.json")
PMC_BUCKET = "https://pmc-oa-opendata.s3.amazonaws.com"
EUTILS = "https://eutils.ncbi.nlm.nih.gov/entrez/eutils/esearch.fcgi"

# (label, publisher, esearch term, how many, format tags)
PMC_GROUPS = [
    ("PLOS Computational Biology", "PLOS", '"PLoS Comput Biol"[jour]', 2, ["journal", "single-column"]),
    ("PLOS ONE", "PLOS", '"PLoS One"[jour]', 2, ["journal", "single-column"]),
    ("eLife", "eLife Sciences", '"eLife"[jour]', 2, ["journal"]),
    ("Frontiers in Neuroscience", "Frontiers", '"Front Neurosci"[jour]', 2, ["journal"]),
    ("PeerJ", "PeerJ", '"PeerJ"[jour]', 2, ["journal"]),
    ("BMC Bioinformatics", "BMC (Springer Nature)", '"BMC Bioinformatics"[jour]', 2, ["journal", "two-column"]),
    ("Nature Communications", "Nature Portfolio (Springer Nature)", '"Nat Commun"[jour]', 2, ["journal", "two-column"]),
    ("Scientific Reports", "Nature Portfolio (Springer Nature)", '"Sci Rep"[jour]', 2, ["journal", "single-column"]),
    ("Nucleic Acids Research", "Oxford University Press", '"Nucleic Acids Res"[jour]', 2, ["journal", "two-column"]),
    ("Sensors", "MDPI", '"Sensors (Basel)"[jour]', 2, ["journal", "single-column", "math-heavy"]),
    ("BMJ Open", "BMJ", '"BMJ Open"[jour]', 2, ["journal"]),
    ("Journal of Medical Internet Research", "JMIR Publications", '"J Med Internet Res"[jour]', 2, ["journal"]),
    ("Royal Society Open Science", "The Royal Society", '"R Soc Open Sci"[jour]', 2, ["journal", "two-column"]),
    ("Cell Reports", "Cell Press (Elsevier)", '"Cell Rep"[jour]', 2, ["journal", "two-column"]),
    ("Heliyon", "Elsevier", '"Heliyon"[jour]', 2, ["journal", "two-column"]),
    ("F1000Research", "F1000 (Taylor & Francis)", '"F1000Res"[jour]', 2, ["journal", "two-column"]),
    ("eNeuro", "Society for Neuroscience", '"eNeuro"[jour]', 2, ["journal"]),
    ("NIH author manuscripts", "various (NIHMS author manuscript)", '"author manuscript"[filter]', 3, ["author-manuscript"]),
]
PMC_RECENT = " AND open access[filter] AND 2023[pdat]"
# Scanned: NBS Journal of Research, 1962. Page images with an OCR text layer;
# PMC's JATS body was re-keyed from the print, so it is independent of the OCR.
SCANNED_TERM = '"J Res Natl Bur Stand A Phys Chem"[jour] AND 1962[pdat] AND open access[filter]'

# (label, arXiv search, how many, tags). Search is the website's comments search.
ARXIV_GROUPS = [
    ("ACL 2025 paper", {"query": "ACL 2025", "searchtype": "comments"}, 3, ["conference", "two-column"]),
    ("EMNLP 2025 paper", {"query": "EMNLP 2025", "searchtype": "comments"}, 2, ["conference", "two-column"]),
    ("CVPR 2025 paper", {"query": "CVPR 2025", "searchtype": "comments"}, 3, ["conference", "two-column"]),
    ("ICML 2025 paper", {"query": "ICML 2025", "searchtype": "comments"}, 2, ["conference", "two-column", "math-heavy"]),
    ("NeurIPS 2025 paper", {"query": "NeurIPS 2025", "searchtype": "comments"}, 2, ["conference", "single-column"]),
    ("IEEE Transactions article", {"query": "IEEE Transactions", "searchtype": "comments"}, 2, ["journal", "two-column"]),
    ("Physical Review article", {"query": "Physical Review Letters", "searchtype": "comments"}, 2, ["journal", "two-column", "math-heavy"]),
    ("Astrophysical Journal article", {"query": "ApJ", "searchtype": "comments"}, 2, ["journal"]),
    ("PhD thesis", {"query": "PhD thesis", "searchtype": "comments"}, 3, ["thesis", "single-column"]),
]
# Math-heavy: monthly listings, primary category only.
ARXIV_MATH = [("math.AP", 2), ("math.PR", 1), ("math.NT", 1)]
ARXIV_MATH_MONTH = "2025-06"


def pmc_ids(term: str, limit: int = 60) -> list[str]:
    query = urllib.parse.urlencode({"db": "pmc", "term": term, "retmax": limit, "retmode": "json", "sort": "pub_date"})
    data = json.loads(net.get(f"{EUTILS}?{query}"))
    return [f"PMC{i}" for i in data["esearchresult"]["idlist"]]


def pmc_metadata(pmcid: str) -> dict | None:
    """Latest version's metadata, or None when the article isn't in the OA bucket."""
    latest = None
    for version in (1, 2, 3):
        try:
            latest = json.loads(net.get(f"{PMC_BUCKET}/metadata/{pmcid}.{version}.json"))
        except net.FetchError:
            break
    return latest


def s3_https(url: str) -> str:
    return re.sub(r"^s3://pmc-oa-opendata/", PMC_BUCKET + "/", url.split("?")[0])


LICENSE_URLS = {
    "CC BY": "https://creativecommons.org/licenses/by/4.0/",
    "CC BY-NC": "https://creativecommons.org/licenses/by-nc/4.0/",
    "CC BY-NC-ND": "https://creativecommons.org/licenses/by-nc-nd/4.0/",
    "CC BY-NC-SA": "https://creativecommons.org/licenses/by-nc-sa/4.0/",
    "CC BY-ND": "https://creativecommons.org/licenses/by-nd/4.0/",
    "CC BY-SA": "https://creativecommons.org/licenses/by-sa/4.0/",
    "CC0": "https://creativecommons.org/publicdomain/zero/1.0/",
}


def jats_is_usable(xml: bytes) -> bool:
    """Full text, not an abstract-only or PDF-only deposit."""
    text = xml.decode("utf-8", "replace")
    body = text.find("<body")
    return body >= 0 and text.count("<p", body) >= 12 and "<ref-list" in text


def pick_pmc(label, publisher, term, count, tags, *, require_license=True, extra=None) -> list[dict]:
    chosen = []
    for pmcid in pmc_ids(term):
        if len(chosen) == count:
            break
        meta = pmc_metadata(pmcid)
        if not meta or not meta.get("pdf_url") or not meta.get("xml_url"):
            continue
        if meta.get("is_retracted"):
            continue
        if require_license and meta.get("license_code") not in LICENSE_URLS:
            continue
        xml_url = s3_https(meta["xml_url"])
        try:
            if not jats_is_usable(net.get(xml_url)):
                continue
        except net.FetchError:
            continue
        entry_tags = list(tags)
        if meta.get("is_manuscript") and "author-manuscript" not in entry_tags:
            entry_tags.append("author-manuscript")
        license_code = meta.get("license_code")
        chosen.append({
            "id": f"pmc-{meta['pmcid'].lower()}",
            "source": "pmc",
            "venue": label if label != "NIH author manuscripts" else meta["citation"].split(".")[0],
            "publisher": publisher,
            "title": meta["title"],
            "citation": meta["citation"],
            "doi": meta.get("doi"),
            "landing_url": f"https://pmc.ncbi.nlm.nih.gov/articles/{meta['pmcid']}/",
            "pdf_url": s3_https(meta["pdf_url"]),
            "ground_truth": {"kind": "jats", "url": xml_url},
            "license": license_code or "US Government work (NBS/NIST), public domain in the US",
            "license_url": LICENSE_URLS.get(license_code, "https://www.nist.gov/open/copyright-fair-use-and-licensing-statements-srd-data-software-and-technical-series-publications"),
            "tags": entry_tags + (extra or []),
        })
    if len(chosen) < count:
        print(f"warning: only {len(chosen)}/{count} for {label}", file=sys.stderr)
    return chosen


# ---- arXiv -----------------------------------------------------------------

OAI = "{http://www.openarchives.org/OAI/2.0/}"
ARX = "{http://arxiv.org/OAI/arXiv/}"


def arxiv_search(params: dict) -> list[str]:
    query = urllib.parse.urlencode({**params, "abstracts": "hide", "size": 50, "order": "-announced_date_first"})
    html = net.get(f"https://arxiv.org/search/?{query}").decode("utf-8", "replace")
    return list(dict.fromkeys(re.findall(r"arxiv\.org/abs/(\d{4}\.\d{4,5})", html)))


def arxiv_listing(category: str, month: str) -> list[str]:
    html = net.get(f"https://arxiv.org/list/{category}/{month}?skip=0&show=100").decode("utf-8", "replace")
    return list(dict.fromkeys(re.findall(r"/abs/(\d{4}\.\d{4,5})", html)))


def arxiv_record(arxiv_id: str) -> dict | None:
    url = f"https://oaipmh.arxiv.org/oai?verb=GetRecord&identifier=oai:arXiv.org:{arxiv_id}&metadataPrefix=arXiv"
    try:
        root = ET.fromstring(net.get(url))
    except (net.FetchError, ET.ParseError):
        return None
    node = root.find(f".//{ARX}arXiv")
    if node is None:
        return None
    def text(tag):
        found = node.find(f"{ARX}{tag}")
        return " ".join(found.text.split()) if found is not None and found.text else None
    return {
        "title": text("title"),
        "comments": text("comments") or "",
        "categories": (text("categories") or "").split(),
        "license": text("license") or "http://arxiv.org/licenses/assumed-1991-2003/",
    }


def arxiv_versioned_html(arxiv_id: str) -> tuple[str, bytes] | None:
    """Finds the latest version that has an arXiv HTML rendering."""
    try:
        abstract = net.get(f"https://arxiv.org/abs/{arxiv_id}").decode("utf-8", "replace")
    except net.FetchError:
        return None
    versions = [int(v) for v in re.findall(rf"/abs/{re.escape(arxiv_id)}v(\d+)", abstract)] or [1]
    version = max(versions)
    try:
        html = net.get(f"https://arxiv.org/html/{arxiv_id}v{version}")
    except net.FetchError:
        return None
    return f"{arxiv_id}v{version}", html


def latexml_is_usable(html: bytes, thesis: bool) -> bool:
    text = html.decode("utf-8", "replace")
    if "LaTeXML" not in text:
        return False
    paragraphs = text.count('class="ltx_para')
    errors = text.count("ltx_ERROR")
    has_bib = "ltx_bibliography" in text
    return has_bib and paragraphs >= (80 if thesis else 20) and errors <= 3


LICENSE_NAMES = {
    "http://creativecommons.org/licenses/by/4.0/": "CC BY 4.0",
    "http://creativecommons.org/licenses/by-sa/4.0/": "CC BY-SA 4.0",
    "http://creativecommons.org/licenses/by-nc-sa/4.0/": "CC BY-NC-SA 4.0",
    "http://creativecommons.org/licenses/by-nc-nd/4.0/": "CC BY-NC-ND 4.0",
    "http://creativecommons.org/publicdomain/zero/1.0/": "CC0 1.0",
    "http://arxiv.org/licenses/nonexclusive-distrib/1.0/": "arXiv non-exclusive distribution license",
}


# Candidates rejected after fetching, with the reason. Checked before any request.
EXCLUDE = {
    "2609.28019": "arXiv's HTML holds about a quarter of the PDF's words (chapters missing), so it can't be ground truth",
}


def pick_arxiv(label, ids, count, tags, *, primary=None, thesis=False, taken=set()) -> list[dict]:
    chosen = []
    for arxiv_id in ids:
        if len(chosen) == count:
            break
        if arxiv_id in taken or arxiv_id in EXCLUDE:
            continue
        record = arxiv_record(arxiv_id)
        if not record or not record["categories"]:
            continue
        if primary and record["categories"][0] != primary:
            continue
        if thesis and not re.search(r"(?i)\b(ph\.?\s?d|doctoral)\b.*\bthesis|\bdissertation\b", record["comments"]):
            continue
        versioned = arxiv_versioned_html(arxiv_id)
        if not versioned or not latexml_is_usable(versioned[1], thesis):
            continue
        vid = versioned[0]
        taken.add(arxiv_id)
        chosen.append({
            "id": f"arxiv-{vid}",
            "source": "arxiv",
            "venue": label,
            "publisher": "arXiv (" + record["categories"][0] + ")",
            "title": record["title"],
            "citation": f"arXiv:{vid} [{record['categories'][0]}]. {record['comments']}".strip(),
            "doi": f"10.48550/arXiv.{arxiv_id}",
            "landing_url": f"https://arxiv.org/abs/{vid}",
            "pdf_url": f"https://arxiv.org/pdf/{vid}",
            "ground_truth": {"kind": "latexml", "url": f"https://arxiv.org/html/{vid}"},
            "license": LICENSE_NAMES.get(record["license"], record["license"]),
            "license_url": record["license"],
            "tags": list(tags),
        })
    if len(chosen) < count:
        print(f"warning: only {len(chosen)}/{count} for {label}", file=sys.stderr)
    return chosen


def main() -> None:
    entries: list[dict] = []
    for label, publisher, term, count, tags in PMC_GROUPS:
        entries += pick_pmc(label, publisher, term + PMC_RECENT, count, tags)
        print(f"{label}: {len(entries)} total", file=sys.stderr)
    entries += pick_pmc(
        "Journal of Research of the NBS (1962)", "National Bureau of Standards (NIST)",
        SCANNED_TERM, 3, ["journal", "scanned", "ocr-text-layer", "math-heavy"], require_license=False,
    )
    taken: set[str] = set()
    for label, params, count, tags in ARXIV_GROUPS:
        entries += pick_arxiv(label, arxiv_search(params), count, tags, thesis=label == "PhD thesis", taken=taken)
        print(f"{label}: {len(entries)} total", file=sys.stderr)
    for category, count in ARXIV_MATH:
        entries += pick_arxiv(f"{category} preprint", arxiv_listing(category, ARXIV_MATH_MONTH), count,
                              ["preprint", "math-heavy", "single-column"], primary=category, taken=taken)
        print(f"{category}: {len(entries)} total", file=sys.stderr)

    # A scanned PDF with no text layer at all is the case the shipping app
    # rejects (pdfHasNoExtractableText). No open corpus pairs such a PDF with
    # clean ground truth, so derive one: tools/fetch.py rasterizes this
    # corpus paper to page images at 200 dpi and drops the text layer.
    base = next(e for e in entries if e["source"] == "pmc" and "single-column" in e["tags"])
    entries.append({
        **base,
        "id": base["id"] + "-imageonly",
        "venue": base["venue"] + " (rasterized, no text layer)",
        "derived_from": base["id"],
        "derivation": "rasterize every page at 200 dpi, grayscale, no text layer (tools/fetch.py)",
        "tags": ["journal", "scanned", "image-only", "derived"],
    })

    manifest = {
        "schema": "c1-corpus-manifest/1",
        "description": "Spoken Margins C1 PDF corpus. URLs and licenses only; fetch with tools/fetch.py.",
        "entries": entries,
    }
    MANIFEST.write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n")
    venues = {e["venue"] for e in entries}
    print(f"wrote {len(entries)} entries from {len(venues)} venues", file=sys.stderr)


if __name__ == "__main__":
    main()
