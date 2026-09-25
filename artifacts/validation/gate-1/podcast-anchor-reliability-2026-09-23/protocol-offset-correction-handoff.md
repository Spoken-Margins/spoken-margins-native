# Protocol and offset correction — 2026-09-23

**Implemented and automatically verified; not human validated.** A legacy `SourceTranscriptionClient` whose evidence-returning method produces both a local window and a transcript now carries that transcript in `SourceAudioWindowAcquisition`. The default acquired-window transcription method returns the carried transcript, so the app does not lose available ASR or fetch a potentially changed remote edition. The production Apple adapter still transcribes its one acquired local file and retains the independent original-URL bounded-ASR fallback only when acquisition fails.

The Apple adapter's iOS 26 long-form timestamp projection is now a testable pure boundary used by production. A deterministic SessionKit test projects local 1–2 second speech through a 33-second `sourceStartMs` and asserts absolute 34–35 second timestamps and unchanged full-source duration. This verifies the offset arithmetic without invoking OS speech recognition. Its older chunk-recognizer path still relies on code inspection of `sourceStartMs + range.startMs` followed by one `offsetTimeline`; live speech timing and ShazamKit acoustic quality remain OS/human-validation limits.

Focused SwiftPM tests: **2 passed** (`protocol-offset-focused.log`), covering the long-form projection and a legacy conformer that supplies a transcript and local window through the original protocol method with exactly one call.

Final gates used the same input SHA-256 `8962815a2717f9ad9e395591d5f2b1de32d3f4648e98c522d4061f7e2374ca01`:

- Fast: **verified**, 328 package tests passed, 1 expected corpus skip; 12 browser and 22 runner tests passed, plus contracts, surfaces, and inventory. Manifest `artifacts/test-runs/20260923-135403-169559-fast/manifest.json`; console `protocol-offset-fast.log`.
- App: **verified**, 476 tests passed, 0 failed or skipped on the same iPhone 17 Pro / iOS 26.5 simulator `856FA6EF-5E03-4120-939B-F0EF42A804E8`. Manifest `artifacts/test-runs/20260923-135424-830567-app/manifest.json`; console `protocol-offset-app.log`.
- `git diff --check` passed. Exact tracked working-tree snapshot: `protocol-offset-working-tree.diff`, SHA-256 `19f348a248329ec7cc92f693e90b9573cd41e18ed3a1c897488e4a91ab863271`. This snapshot contains tracked changes only; existing untracked artifacts are preserved separately.

The previous `shared-acquisition-correction-handoff.md` was corrected: its old diff hash came from a transient stream, and no file existed for that earlier state. No simulator system-process crash was reported. The preexisting temporary SQLite test-database unlink diagnostics remain separate from this correction. No recipient-F work, commit, merge, installation, or distribution was performed.
