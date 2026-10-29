# C1 pdf: corpus, scorer and baseline

Stream C1's research half (brief: `docs/workstreams/streams/C1-pdf.md`, tracking issue #191). Everything here runs on Linux or macOS with Python 3.11+, except `mac/`, which runs the app's own extractor and needs macOS.

- **Latest numbers:** [results/REPORT.md](results/REPORT.md).
- **I13 draft:** [I13/](I13/).

## What's here

| Path | What it is |
| --- | --- |
| `corpus/manifest.json` | The corpus: 66 PDFs as URLs and licences. Also holds measured facts about each file: sha256, pages, columns, text-layer words, and math, caption and marker counts from ground truth. |
| `corpus/build_manifest.py` | How the corpus was chosen. Rerun it only to rebuild the corpus on purpose. The committed manifest is the record. |
| `tools/fetch.py` | Downloads the PDFs and ground truth into `cache/` (git-ignored), converts the ground truth, and derives the image-only scan. |
| `tools/groundtruth.py` | Converts JATS XML (PubMed Central) and LaTeXML HTML (arXiv) into role-labelled segments. |
| `tools/reference_extract.py` | Reference-parser baselines: `pymupdf-raw` and `pdfminer`. |
| `tools/score.py` | The scorer: spoken text in, per-paper scores out (`results/<extractor>/scores.json`). |
| `tools/report.py` | Writes `results/REPORT.md` from every `scores.json`. |
| `tools/precheck.py` | C1 M2: cheap pre-check features, a threshold rule fitted on the corpus, and its recall and false alarms, in sample and leave-one-out. It needs the app's own output (a Mac run) for a real result. |
| `tools/number_read_sites.py` | Lists the citation sites an extractor spoke as a bare number, with the words around each, so they can be sorted into a real citation style or something that only looks like one (#1189). `--markdown` prints a table. |
| `tools/inspect_alignment.py` | Prints one paper's spoken text with each run of words tagged by category, so you can check the scorer by eye. |
| `tools/test_score.py`, `tools/test_net.py` | Unit tests for the scorer, both parsers, and the downloader's handling of cut-off and mismatched files. |
| `mac/` | **(Mac)** `c1-extract`, a command-line tool that runs the app's `PDFStructuredTextExtractor` over the corpus, plus `run.sh`, which does fetch, build, extract, score and report in one go. |

Extracted text and PDFs never get committed. Only scores (numbers) and the report do.

## Run it

```sh
cd research/C1
python3 -m venv .venv && .venv/bin/pip install -r requirements.txt
.venv/bin/python tools/fetch.py                         # ~300 MB into cache/
.venv/bin/python tools/reference_extract.py pymupdf-raw
.venv/bin/python tools/score.py --extractor pymupdf-raw
.venv/bin/python tools/report.py
.venv/bin/python -m unittest tools/test_score.py tools/test_net.py tools/test_precheck.py
```

### (Mac) Score the app's own extractor

On a Mac with Xcode (macOS 15 or later), from the repo root on branch `ws/c1-pdf`:

```sh
research/C1/mac/run.sh
```

That runs, in order:

1. Creates `research/C1/.venv`.
2. Fetches the corpus.
3. Copies the app's current `PDFStructuredTextExtractor.swift` and `SpeechTextNormalizer.swift` into the tool. The only change is `import UIKit` → `import AppKit`, with a two-line `UIFont` shim.
4. Builds with `swift build -c release`.
5. Extracts every PDF.
6. Scores the output as `app-baseline`.
7. Regenerates the report.

It doesn't touch the simulator, the app's data or the Library. It takes a few minutes, mostly the download.

Post these on #191:

- `results/app-baseline/scores.json`
- `results/app-baseline/run-info.json` (extractor commit, macOS version, failures, median extraction time)
- the regenerated `results/REPORT.md`

Or commit them to `ws/c1-pdf`.

## How the score works

**Ground truth.**

- PubMed Central articles come with JATS XML beside the publisher's PDF. It tags body, headings, captions, tables, footnotes, references and front and back matter.
- arXiv papers come with arXiv's own HTML rendering (LaTeXML) of the same LaTeX version the PDF was compiled from.

Both are turned into role-labelled segments, the same shape as the I13 draft. Citation markers, footnote markers and inline math are lifted out of the body text into markers.

**Alignment.** The spoken text is aligned to ground truth by shared 4-word sequences. The alignment then fills gaps between anchors and repairs line-end hyphenation where the joined word exists in the ground truth. It isn't order-preserving, so a caption read early or a column read out of order still aligns. Those problems show up as order breaks and interruptions, not as missing text.

**Per paper, it reports:**

- **Clutter rate:** the share of spoken words that aren't body text. Clutter is:
  - reference lists
  - table cells
  - footnote text
  - front and back matter
  - repeated running titles
  - page furniture
  - stamps and links
  - math read as symbols
  - stray fragments

  Captions and citation markers are reported separately, because whether to speak them is an I14 decision.
- **Missing body rate:** the share of ground-truth body words never spoken.
- **Order breaks:** places where the body text jumps to text read at another point, per 1000 body words.
- **Mid-sentence interruptions:** 3 or more non-body words spoken inside a sentence that then continues.
- **How each citation and footnote marker was spoken:** silent, "citation 12", a bare number, glued to the word, or the author-year text read out.
- **Captions and tables:** how many captions were read, and how many tables had their cells read aloud.
- **Listener cost:** in seconds, using the cost model at the end of the report.

**Known limits.**

- Words the ground truth lacks are counted but kept out of clutter (`unattributed_prose`). These include text inside figures, some code listings LaTeXML drops, and publisher cover lines. They run at about 3% of spoken words.
- Math-heavy papers show some missing body because short words between formulas can't always be anchored.
- The image-only scan scores 100% missing for any extractor without OCR. That's correct, since the listener hears nothing.
