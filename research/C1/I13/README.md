# I13 · Structured document: DRAFT

**Status:** draft from C1 M1 (cloud). It becomes published when the schema moves to `Contracts/schemas/structured-document.schema.json`, with a SessionKit `Codable` mirror and a stub. That happens in C1's Mac milestone work, so consumers can build against this file now.

- **Owner:** C1 `pdf`.
- **Consumers:**
  - C2 `voice`: how each role sounds (I14).
  - The listening map for PDFs (#124).
  - The player: show a figure while its caption is read.
  - Written-Margin text anchors.

**Files:**

- [`structured-document.schema.json`](structured-document.schema.json): the shape.
- [`fixture.json`](fixture.json): a two-page example that uses every part. It doubles as the stub a consumer can load today.
- `tools/to_i13.py`: converts all 66 corpus ground-truth files into this shape. They and the fixture validate against the schema, and their ranges are checked to index the text correctly.

## What crosses

A structured document has five parts, and optionally a sixth.

1. **`text`: one canonical string for the item.**
   - Every range in the document indexes into it.
   - For a given extraction version, it is the text that written Margins anchor into.
2. **`segments`: role-labelled ranges of `text` in reading order.**
   - Contiguous and non-overlapping. Anything between two segments is whitespace.
   - Each has a role (table below). Optional fields: a heading level, the page it starts on, and the float it belongs to.
3. **`markers`: inline marks inside a segment.**
   - Kinds: `citation`, `footnote`, `math`, `figure_reference`, `table_reference`, `soft_hyphen` (a line-end hyphen that splits one word, "agree-" + "ment"; spoken whole).
   - Each carries the printed label (`12`, `3–5`, `Smith et al., 2020`, `*`) and, when known, the segment it points to.
   - The marker's characters stay in `text`. Removing them would move every anchor after them. How they sound is the speech path's decision.
4. **`floats`: figures and tables that can be shown on screen.**
   - Each has a kind, a label, a page, bounds, and its caption segment.
   - Bounds follow `pdf-document-structure.v1`: fractions of the page's crop box, with a lower-left origin, as PDFKit and Vision use. A player crops the rendered page with them.
5. **`extraction`: which engine made this, and at what version.** The version rule below is built on it.
   - Also carries the source PDF's SHA-256, the page count, and the SHA-256 of `text`.
   - Optional `quality` holds C1 M2's pre-check verdict (`good`, `fair` or `hard`) and its reasons.
6. **`outline` (optional): chapters with no printed heading.**
   - An entry in the PDF's outline that no printed line matches (#355) becomes `{title, level, start}`: a chapter that starts at `start` in `text`.
   - It has no text of its own, so it is never spoken and never moves an anchor. Absent when there are none.

**Units.** Ranges count **Swift `Character`s** (extended grapheme clusters), the same unit as `Anchor.startChar`/`endChar` and `SpeechTextNormalizer`'s source offsets. A Margin anchor and a segment range compare directly, with no conversion.

### Roles

Roles are advisory. **I14 decides how each role sounds.** The "likely treatment" column is a suggestion from C1's baseline, not a rule.

| Role | What it is | Likely treatment (I14 decides) |
| --- | --- | --- |
| `title` | Document title | read |
| `heading` | Section heading (`level` 1–6) | read; chapter boundary in the listening map |
| `abstract` | Abstract paragraphs | read |
| `body` | Running text, lists, appendix text | read |
| `caption` | Figure or table caption (`floatId` set) | announce ("Figure 2: …") and show the float |
| `table` | Table cell text (`floatId` set) | skip; announce the table |
| `footnote` | Footnote text | skip inline; maybe read at the paragraph end |
| `equation` | Display equation | say "equation" |
| `reference` | Bibliography entry | skip |
| `authors` | The author names on the title page | read (owner, #191) |
| `front_matter` | Affiliations, emails, identifiers, dates, licence lines | skip (C1 proposes silently; C2 to confirm) |
| `back_matter` | Acknowledgements, funding, contributions, competing interests, data availability, reviewer reports | skip |
| `page_header`, `page_footer` | Running heads, page numbers, download stamps | skip |
| `figure_text` | Text printed inside a figure: axis ticks, panel labels, screenshots | skip; the caption announces the figure (C1 proposal, C2 to confirm) |
| `unknown` | The extractor couldn't tell | read |

The baseline report (`results/REPORT.md`) says why these roles matter. With no handling, a reference list costs a median of 9.3 minutes of listening per paper.

## Invariants

1. **Existing Margins keep their place: the extraction version rule.**
   - **(a) Version on every change.** `extraction.version` is a monotonic integer per engine. It goes up with any change that can change `text` for some PDF. The C1 corpus is the check: rerun the extractor and compare each output's `textSHA256` with the previous run. Any difference without a version bump is a bug.
   - **(b) An item stays on the version it was imported with.** A newer extractor never silently replaces an item's text.
   - **(c) Re-extraction goes into a new record.** The newer version is stored beside the old one as its own record kind, keyed by item id and version. `Item.text` is never rewritten in place. This keeps the previous build working: it keeps reading `Item.text`, and it never sees the new record. That follows the "new record kinds, not new fields" guidance in `interfaces.md`.
   - **(d) An item moves to a new version only if one of these holds:**
     - it has no text-anchored Margins; or
     - every anchor is migrated. For each Margin, the new position must hold exactly the same text the old range did. Because `text` is canonical, that can be checked, not guessed. Stored `anchorBefore`/`anchorAfter` context breaks ties.

     If any anchor fails, the item stays on the old version and its old text. The listener keeps the worse extraction but correct Margins.
   - **(e) C1 M3 proves it with a test.** The test imports a corpus PDF under the current (v1) extractor, writes Margins, upgrades, and checks every Margin opens at the same words.
2. **Roles are advisory.** A wrong role must never lose text. Every character of `text` stays in some segment, and a consumer that ignores roles gets the whole document.
3. **Structured documents don't travel in packets.**
   - A recipient extracts their own copy.
   - Portable anchors already carry `exactText`, `prefix` and `suffix`. `PortableArticleAnchorResolver` places them by quote against the recipient's text, whatever extractor version made it.
   - So I13 changes never touch the packet format (I10). Build 29's reader stays compatible because nothing new is sent.
4. **Floats are optional.** A document with no floats is valid. The player shows a figure only when it has bounds.

## Found while drafting: the rule isn't enforced today

A read-only review of current code found three things.

- **Written Margins resolve by offset only.** `SessionEngine.playInterjectionAnchor` (`SessionEngine.swift:1399`) checks `endChar <= text.count` and jumps to `startChar`. It has no quote fallback, so if `Item.text` changes and is still long enough, a Margin lands in the wrong place silently.
- **Re-importing a PDF can overwrite its text.** Re-importing the same PDF file reaches `browserTextImportRecords` (`SessionEngine.swift:3374`) with the same deterministic item id. The "corrected extraction gets its own `-edition-<sha>` id" guard (`:3375`) covers only `.readablePage` captures, not `.markdownFile`, which is how PDFs arrive.
- **Why it's harmless now, and when it stops being.** Today it does no harm, because the extractor hasn't changed and the text comes out identical. The first extractor change in C1 M3 would make it real. Rule 1(c) closes it: a PDF re-import must keep the old edition (the same guard as readable pages) or go through rule 1(d).

`PDFDocumentStructure.schemaVersion` and `extractionEngine` exist on `Item.documentStructure` but drive no decisions (diagnostics only). They are too coarse to act as the version in rule 1(a).

## Relation to what exists

`Item.documentStructure` (`pdf-document-structure.v1`) holds Vision's tables and page titles. I13 replaces it for new extractions but doesn't remove it: old items keep it, and old builds keep reading it.

The first app-side implementation should:

- produce I13 from `PDFStructuredTextExtractor`, with roles from its existing heuristics (running headers, stamps, the table of contents, reference cutting);
- keep `Item.text` byte-identical to today's output for version 1.

Before M3 changes anything, a corpus run must show `textSHA256` unchanged for every PDF.
