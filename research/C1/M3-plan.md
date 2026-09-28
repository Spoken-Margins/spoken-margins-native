# C1 M3 plan: clean body text

Draft, 2026-09-28. This is the plan for the brief's M3 (`docs/workstreams/streams/C1-pdf.md`), built on:
- the corpus baseline in `results/REPORT.md`;
- the I13 draft (`I13/`);
- C2's published I14 rules (`docs/workstreams/interfaces.md` on `ws/c2-voice`, coming to `next` through #218).

Progress and decisions live on #191, not here.

## Done when (from the brief)

1. The corpus median clutter rate is halved from the M1 app baseline, 24.9% → **12.4% or lower**, and no category regresses.
2. Footnote markers and citations are spoken per I14.
3. J7 still passes on the lane.
4. Written Margins on already-imported PDFs still open at the right passage. A test proves this with a PDF imported under the old extractor.
5. From "Must not break": median import time on the corpus doesn't slow by more than 20%. The app baseline is 843 ms on a MacBook Pro (`results/app-baseline/run-info.json`).

## What the corpus says has to change

These figures are from the app's own extraction of 64 papers (`results/app-baseline/scores.json`). The simulation removes a category's words from each paper's spoken text, then takes the median clutter rate.

| If the app stopped speaking… | Median clutter |
| --- | ---: |
| (today) | 24.9% |
| reference lists | 18.6% |
| + table cells | 13.8% |
| + running heads, page numbers, stamps | **9.3%** |
| + footnote text | 7.7% |
| + back matter (funding, contributions, competing interests) | 5.9% |

Real detection won't be perfect. If each of the first three is caught for a fraction of its words, the median becomes:

| Detection | Refs + tables + heads | + footnotes + back matter |
| --- | ---: | ---: |
| 80% | 14.7% | 13.5% |
| 90% | 12.0% | **9.9%** |

What that means:
- **Reference lists, tables and running heads carry the target.** They each need about 90% word-level detection to reach it on their own. Footnotes and back matter give margin, but only if I14 lets back matter be skipped (open question 1).
- **Math and equations cost as much listening time as tables** (218 and 111 corpus minutes), but no role skip fixes them. I14's normalization (Greek by name, operators as words) makes math *sound* better without removing words. Math-heavy PDFs are what M2's pre-check warns about. M3 doesn't try to fix math.

Two bugs are part of M3:
- **#215:** appendices after the references are lost.
- **#219:** 18–62% of the body is lost on four papers, cause unknown.

"No category regresses" includes missing body text, so the new extractor must not lose more. Ideally it recovers what these two bugs lose.

## Principles

1. **Roles, not cuts.** Extraction stops deleting text. A reference list becomes `reference` segments, and a running head becomes `page_header`. The speech path applies I14 to decide what's heard.
   - This fixes #215 by construction: I14 says reading resumes after the references, so an appendix is heard.
   - It also meets I14's invariant that text never disappears silently.
2. **New extraction, new version; old items stay put** (I13 rule 1). Everything M3 changes is extraction version 2.
   - Items imported before M3 keep their v1 text and their Margins.
   - A v1 item moves to v2 only when every Margin provably lands on the same words.
3. **Measure every change on the corpus before it lands.** Each step below says what it's expected to move. A step that doesn't move it, or that regresses a category, doesn't merge.
4. **SessionKit for logic, `App/` only for PDFKit.**
   - The I14 projection (roles to spoken text) and the anchor migration are pure logic. They go in SessionKit with host tests.
   - Only the PDFKit reading stays in `App/SharedSources`. `Gate1AppModel` only calls these.

## Steps

Every step except 0 needs the Mac (PDFKit, SessionKit tests, the lane). The cloud prepares the scorer side and reviews.

**Step 0 (cloud): make the scorer I14-aware.**

Today the scorer counts any announcement ("References skipped", "Table not read", "Figure 2.") as unattributed words, and treats a silent citation as merely "silent".

- Add an `announcement` category, not counted as clutter.
- Make "silent" the I14-correct outcome for numeric and parenthetical citations and footnote markers.
- Add a Python reference of the I14 projection that turns an I13 document into spoken text. Scoring an I13 document then measures exactly what the app will say.
- Teach `c1-extract` to write I13 output beside the markdown.

**Step 1 (Mac): guard existing Margins before anything changes.** This lands first, alone.

- **The re-import guard.** Re-importing a PDF must not overwrite `Item.text` under existing Margins. Apply the same `-edition-<sha>` guard `readablePage` imports get (`SessionEngine.swift` ~3375) to `.markdownFile` PDF imports.
- **Offsets only today.** A written Margin resolves by offset alone. This step doesn't change that, because no text changes yet. Step 5's migration is where the words are checked.
- **Tests:** re-importing the same PDF with different extracted text keeps the old item and text; and J7.

**Step 2 (Mac): emit I13 v1 with `Item.text` unchanged.**

`PDFStructuredTextExtractor` returns an I13 document alongside today's markdown:
- roles from its existing heuristics: headings, table-of-contents lines, the reference cut point;
- extraction version 1.

**Check:** every corpus PDF's `markdown_sha256` is unchanged from the baseline run. That proves v1 is today's text. No product behaviour changes.

**Step 3 (Mac): extraction v2, roles instead of cuts, plus #219.**

- **Reference lists.** Keep them as `reference` segments instead of cutting.
  - Detection: the heading rule plus a run of bibliography-shaped lines (numbered, author-year, DOI).
  - Measure: the "Reference list read aloud" cost falls from 291 corpus minutes to near zero. Missing body improves on #215's papers.
- **Running heads, footers, page numbers, stamps.** Today's repetition and position rule removes some. v2 keeps them as `page_header` / `page_footer`, normalizing digits so "Page 3" and "Page 4" match, and adds first-page journal banners.
  - Measure: furniture + repeated + stamps fall from 177 corpus minutes.
- **Fix #219** once its cause is found (`inspect_alignment.py app-baseline <id> --missing` on the Mac).
- **Tables.** Two options, measured on the corpus before choosing:
  - (a) A geometric rule: blocks of short, numeric-dense lines aligned in columns.
  - (b) The existing Vision table detector in `NativePDFDocumentExtractor`, never called today. It is better, but costs import time.
  - Choose (b) only if it clears the 20% import-time budget, or runs after import as a background pass that produces a new extraction version (open question 3).
  - Measure: "Table cells read aloud" falls from 195 corpus minutes.
- **Footnotes and back matter.**
  - Footnotes: small text at the bottom of a page, under a rule or starting with a marker.
  - Back matter: headings such as Acknowledgements, Funding, Author contributions, Competing interests, Data availability.

**Step 4 (Mac, SessionKit): speak per I14.**

A SessionKit projection turns an I13 document into spoken text. It uses C2's I14 Swift type when it lands (#183); until then, a C1 stub with the same rules.
- **Skipping roles:** skip or announce each role per the I14 table.
- **Markers:**
  - numeric and superscript citations silent;
  - parenthetical author-year citations silent;
  - narrative citations read, with "et al." → "and colleagues";
  - footnote markers silent.
- **Superscripts:** detecting them needs PDFKit's baseline-offset or font-size attributes on the marker glyphs. Step 3 records superscript markers as I13 `markers`.
- **Replaces today's behaviour:** `SpeechTextNormalizer.speakReferenceMarkers` ("citation 12") is removed for PDF items. I14 makes those markers silent.
- **Measure:** citation outcomes move from today's mix (44% "citation N", 18% bare number, 7% glued) to silent. The corpus median clutter rate reaches 12.4% or lower. No category regresses.

**Step 5 (Mac): move existing items to v2 where it's safe** (I13 rule 1d).

- **When to migrate:** an item with no text-anchored Margins moves on re-extraction. An item with Margins moves only if, for each Margin:
  - its v1 range's words are found in the v2 text at a unique position;
  - `anchorBefore`/`anchorAfter` agree when that position is ambiguous.

  Otherwise it stays on v1.
- **The test the brief requires:**
  1. Import a corpus PDF under v1.
  2. Write Margins at the start, the middle and the end, and one inside a paragraph v2 changes.
  3. Upgrade.
  4. Assert every Margin opens at the same words, or the item stays on v1.
- **Also:** J7 on the lane, and the previous build still opens the database. The v2 document is a new record kind, per I13 rule 1c.

**Step 6: verify and hand over.**
- Corpus report: before and after per category, and import time.
- Journeys J7 and a PDF listen-through on the lane.
- Owner pass on a device: does a paper *sound* right?

## Open questions

1. **For C2: the roles I14 doesn't list.** I14's table has no row for `front_matter`, `back_matter`, `equation`, `abstract`, `title` or `unknown`. Proposed defaults:

   | Role | Proposed default |
   | --- | --- |
   | `title`, `abstract` | read |
   | `front_matter` | read the author list, skip affiliations, identifiers and dates |
   | `back_matter` | skipped with "Back matter skipped." |
   | `equation` | "Equation." |
   | `unknown` | read |

   Back matter matters for the target (see the table above).
2. **For the owner: should author names be read?** Title-page matter costs a median 0.6 minutes per paper. Researchers may want to hear who wrote it.
3. **For the owner: table detection with Vision.** The Vision detector is the better detector but costs import time.
   - One option is to run it after import as a background pass, which quietly produces a v2+ extraction.
   - The listener would then hear tables announced only once that pass finishes.
   - Or it stays within the 20% budget, if measured to fit.
4. **For the owner: the old "citation 12" behaviour.** I14 makes numeric citations silent. Today's app says "citation 12", so listeners who are used to that will hear a change.

## What is explicitly not in M3

- Showing figures on screen (M4).
- OCR for scans (a separate follow-up, tracked by M2's `no_text_layer` warning).
- Reading math as speech beyond I14's normalization.
- EPUB (#61).
