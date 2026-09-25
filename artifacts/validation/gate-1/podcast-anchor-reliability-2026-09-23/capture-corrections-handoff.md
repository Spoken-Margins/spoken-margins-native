# Capture corrections handoff — 2026-09-23

Owner's bounded follow-up to `capture-audit.md` findings 1–4 is implemented. The implementation writer lease is returned. No branch, commit, install, or simulator boot was made. Account usage at handoff: 16% used, 84% remaining; the revised floor is 80% remaining.

## Corrections

1. `SessionEngine` validates the producing exact-edition digest and the durable attempt generation for each pre/post role inside its loaded-record mutation before completion or failure can save. `Gate1AppModel` now rejects role callbacks without matching generation and carries separate pre/post attempt generations for exact-local retries. Local capture starts only after the pending attempt has been saved. Reference-window evidence remains independent of pre/post capture-job state.
2. A dropped audio callback records callback and continuity epochs; its queued gap handler clears accumulators only if both still match. The test seam pauses the worker, seeks, rearms the same Margin, then drains the old gap.
3. Buffered pre capture copies only PCM frames inside the requested `[max(0, anchor-duration), anchor]` interval before Shazam signing. Tests include a 20-second chunk trimmed to a 12-second middle window and a 20-second chunk trimmed to a five-second episode-edge window, including post-anchor audio in the source chunk.
4. `PodcastAnchorCaptureWindow.Role` can encode/decode only `pre_interjection` or `post_resume`; `Interjection.updatePodcastAnchorWindow` ignores source-reference roles. The existing strict schema's role set and two-window cap now match the durable model.

Files changed by this bounded slice: `Packages/SessionKit/Sources/SessionKit/{Models,Protocols,SessionEngine}.swift`, `Packages/SessionKit/Sources/SessionKitAudio/PostResumePodcastEvidenceCapture.swift`, `App/SpokenMarginsApp/Sources/SpokenMarginsApp/Gate1AppModel.swift`, and `Packages/SessionKit/Tests/SessionKitTests/{SQLiteSessionStoreSafetyTests,SharingTests}.swift`. Other working-tree changes predate this slice and were preserved.

## Verification

- Four focused counterexample tests passed: `swift test --package-path Packages/SessionKit --filter 'testPodcastCaptureRejectsStaleAttemptAndEditionWithoutOverwritingCommittedFlank|testSourceReferenceEvidenceCannotAddCaptureJobRole|testBufferedPreWindowTrimsOversizedChunkAndEpisodeEdge|testQueuedOldPlaybackGapCannotClearRearmedCaptureAfterSeek'`. Initial result in `capture-corrections-focused.log` (4 passed). A later interim compile failure while making the engine mutation closure throwing was corrected; the final fast gate below reran package compilation and all package tests.
- Final full fast gate passed: `.venv/bin/python scripts/verify-tests.py --plan fast`; evidence `artifacts/test-runs/20260923-123754-483676-fast/manifest.json`, log `capture-corrections-fast.log`. Package count: 322 passed, 0 failed, 1 expected skipped held-out corpus test. Runner, contracts, surfaces, inventory, browser, and package steps all passed.
- Final generic app compile passed without simulator boot: `xcodebuild -project SpokenMarginsNative.xcodeproj -scheme SpokenMarginsApp -destination 'generic/platform=iOS Simulator' build`; log `capture-corrections-app-build.log` (`BUILD SUCCEEDED`). This is compilation evidence, not product-flow validation.
- `git diff --check` passed.

Stable review snapshot: `capture-corrections-working-tree.diff` (193,589 bytes, SHA-256 `cb76291c498b91ffc0792ec9a69df71ad03489cc609a685029600a4d62e1d8fa`). It records the tracked working tree at lease return, including pre-existing dirty edits. Compare with the earlier `baseline.diff` for provenance; this snapshot itself must not be rewritten during independent audit.

Residual limits: no app runtime/UI test was run because the known simulator incident forbids booting it; the owner alone validates product flows. The final app build predates only the last test-fixture adjustment, which does not affect app source. No data migration is provided for hypothetical persisted capture windows with source-reference roles; the existing app flow stored those signatures as evidence, not capture windows, and the audit found no known records of that shape.
