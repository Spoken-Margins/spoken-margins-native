#!/usr/bin/env python3
"""Reference-parser baselines: what a listener hears with no cleanup at all.

    python3 tools/reference_extract.py pymupdf-raw
    python3 tools/reference_extract.py pdfminer

Writes cache/candidates/<extractor>/<id>.json in the same format the Mac CLI
writes for the app's extractor: {"id", "extractor", "spoken", "elapsed_ms"}.

- pymupdf-raw: MuPDF's text in content-stream order, page after page.
- pdfminer: pdfminer.six layout analysis (groups text boxes into reading order).
"""

from __future__ import annotations

import json
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PDF_DIR = ROOT / "cache" / "pdf"


def pymupdf_raw(path: Path) -> str:
    import pymupdf
    with pymupdf.open(path) as doc:
        return "\n".join(page.get_text("text") for page in doc)


def pdfminer_text(path: Path) -> str:
    from pdfminer.high_level import extract_text
    return extract_text(str(path))


EXTRACTORS = {"pymupdf-raw": pymupdf_raw, "pdfminer": pdfminer_text}


def main() -> None:
    name = sys.argv[1]
    extract = EXTRACTORS[name]
    manifest = json.loads((ROOT / "corpus" / "manifest.json").read_text())
    out = ROOT / "cache" / "candidates" / name
    out.mkdir(parents=True, exist_ok=True)
    for entry in manifest["entries"]:
        path = PDF_DIR / f"{entry['id']}.pdf"
        if not path.exists():
            print(f"skip {entry['id']}: not fetched", file=sys.stderr)
            continue
        start = time.monotonic()
        record = {"id": entry["id"], "extractor": name}
        try:
            record["spoken"] = extract(path)
        except Exception as error:
            record["spoken"] = ""
            record["error"] = str(error)
        record["elapsed_ms"] = round((time.monotonic() - start) * 1000)
        (out / f"{entry['id']}.json").write_text(json.dumps(record, ensure_ascii=False))
        print(f"{entry['id']}: {len(record['spoken'].split())} words, {record['elapsed_ms']} ms")


if __name__ == "__main__":
    main()
