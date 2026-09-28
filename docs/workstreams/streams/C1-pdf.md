# C1 · pdf: scientific papers that sound right and show what can't be heard

**Outcome.** A researcher imports a paper from any major publisher and hears the body text cleanly: no running headers, page numbers, stamps, footnote clutter or reference lists read out, and citations and symbols spoken sensibly. When the text reaches a figure or table, they can see it on screen while its caption is read. When a PDF is going to be hard (scanned, two-column chaos, math-heavy), the app knows before playback starts and says so.

**Why now.** People close to the owner read a lot of scientific literature, and the app doesn't read it well yet.

**Where.** Corpus, scoring and failure analysis in the cloud. Extraction and app changes on the Mac (PDFKit and Vision are Apple-only, so the app's extractor must run on macOS to be scored).

**Seams.** Owns **I13** (structured document), published in M1. Uses I14: C2 M1 publishes how each role is spoken, and M3 waits for it.

## Starting points

- **The Vision-based extractor is never called.** `NativePDFDocumentExtractor.extract(from:)` (table detection, OCR for scanned PDFs, thermal pausing) exists, but every import path calls `extractBaseline`. Shipping builds get no table handling and no OCR, and a scanned PDF fails with `pdfHasNoExtractableText`.
- `App/SharedSources/PDFStructuredTextExtractor.swift` does the baseline:
  - running header/footer removal by position and repetition;
  - download stamps (#162 fixed);
  - table-of-contents page removal;
  - headings from the outline or font size;
  - cutting the reference list after a "References" heading.
- No footnote detection: superscript digits are read aloud. Only `[1]`-style markers become "citation 1" (`SpeechTextNormalizer.speakReferenceMarkers`). Figures and captions get no handling (#105).
- There's no PDF corpus in the repo and no quality score. Tests synthesize PDFs.
- Open-access sources carry ground truth that can serve as a reference: PubMed Central articles have JATS XML alongside the PDF, and arXiv has LaTeX source. The owner suggested a speech round-trip (render with Supertonic or an Apple voice, transcribe with Whisper, compare). Use whichever reference the agent finds most reliable; the endpoint is the score, not the method.

## Milestones

**M1: Corpus and a score** (cloud, plus a small Mac CLI).
- Done when:
  - A corpus manifest of at least 60 PDFs from at least 10 publishers or formats is committed as URLs and licenses, not the PDFs themselves. Include journals, preprints, conference papers, theses, a scanned paper, two-column and math-heavy papers.
  - A scorer reports, per PDF, what fraction of the spoken text is body text versus clutter, what fraction of the body text is missing, and how citations, footnotes, figures and tables are handled.
  - (Mac) A command-line tool on macOS runs the app's current extractor over the corpus. The cloud agent writes it; a Mac session or the lane runs it and posts the output.
  - A baseline report ranks the failure categories by how much they cost listeners.
  - I13 is published: roles, figure and table references, and the extraction version rule.

**M2: Predict hard PDFs.**
- Done when a cheap pre-check (run before playback) flags at least 80% of the PDFs that score in the bottom quintile, with no more than 10% false alarms, and the app says so on import. Measured on the corpus.

**M3: Clean body text.**
- Done when:
  - The corpus score's median clutter rate is halved from the M1 baseline and no category regresses.
  - Footnote markers and citations are spoken per I14.
  - Existing J7 still passes on the lane.
  - **Written Margins made on already-imported PDFs still open at the right passage** (I13's versioning rule), proved by a test with a PDF imported under the old extractor.

**M4: See the figure.**
- Done when:
  - For corpus papers with figures and tables, at least 90% are detected with their captions.
  - During playback, reaching a caption shows the figure or table region from the page (tap to enlarge), and playback continues.
  - Lane T4 shows it on two papers.
  - (owner) The owner checks the listening side on a device.

## Must not break

J7. Anchors of existing written Margins. Import time for ordinary PDFs: measure it, and flag any slowdown over 20% on the corpus median.

## Out of scope

EPUB (#61). Reading equations aloud beyond saying "equation" sensibly. That can be a later milestone if M1 shows it matters.

## Related

#78, #105, #124, #138, #162.
