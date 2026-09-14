# PDF contents and diagnostics — September 14, 2026

Candidate: local uncommitted changes on `codex/provisional-next`, base `ad533d6604dbacf892df85dc06f36d63c2f97a08`. Build number unchanged; no install, commit or distribution. iOS 18+ app; focused simulator evidence uses iOS 18.6. Source fingerprints accompany this report.

## Evidence and bounded repair

NASA Dynamics Simulation Model for Space Tethers (70 pages), source https://ntrs.nasa.gov/api/citations/20060051891/downloads/20060051891.pdf. Reproduced using the repository extractor with UIKit font types substituted by AppKit for a read-only macOS PDFKit harness. Before: dotted ToC entries entered canonical narration, the continued ToC was promoted to a heading, and front-matter typography generated date/publisher chapters. After: recognized directory entries omitted from new extracted narration, continued title recognized, pre-contents typography retained as prose, invalid C0 controls removed. Authored destination handling and documents without a ToC retain their existing heading rules. Actual source output contains no dotted leaders or C0 controls (16 control characters before).

The original PDF is unchanged. Existing Library source, audio, sessions and Margin offsets are not rewritten. These extraction changes require a new import; a cache reset alone cannot repair old canonical text. No deletion/reset required. Use a separate imported copy for testing, preserving the original with its Margins.

## Diagnostics

User JSON: lastPDFExtractionEngine=pdfkit; lastPDFAnalysisStatus=partial; lastPDFAnalyzedPageCount=0; lastPDFPageCount=70. Developer ring buffer contains 1,200 events: 1,100 samples, 97 scrub display events, one main.delayed event (1,049 ms at 20:06:24.043Z), one item.open.begin and one item.open.end. All sampled Low Power Mode fields are false. Console includes five system gesture gate timeouts. These establish responsiveness symptoms, not the responsible stack. No matching memory termination established by this capture. The developerBuild string is a diagnostic label, not reliable commit identity.

## Remaining limitations

The report's appendix bodies are largely image-only: physical page 20 visibly contains prose and equations while text extraction yields only its page number. Basic extraction cannot recover that content. OCR remains a separate unresolved repair; no eager page rendering or OCR was added to import. Some report/appendix/back-cover typography can still produce extra headings. This is a bounded ToC/front-matter repair, not a claim of complete chapter accuracy or complete PDF narration.

## Owner check (pending)

- Import a separate copy of the NASA report; verify continued ToC and dates are absent from the listening chapters, with real report sections retained. Pass/fail: pending.
- Listen across the ToC-to-introduction boundary; verify no dotted leader narration. Pass/fail: pending.
- Recheck navigation while audio preparation runs on iPhone 14. Pass/fail: pending (earlier performance changes, not established by this extraction check).

Full app/release tests and physical user-flow acceptance remain deferred to the owner. Focused result: six selected PDF regression tests passed, zero failures, zero skips on iOS 18.6; app compiled successfully. See `focused.log` and `focused.xcresult`. Actual NASA source extraction also checked with the macOS PDFKit harness. These are implementation checks, not human flow validation.
