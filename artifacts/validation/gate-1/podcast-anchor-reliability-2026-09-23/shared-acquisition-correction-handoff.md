# Shared source-window acquisition correction — 2026-09-23

**Implemented and automatically verified; not human validated.** The sender now hands one acquired local window to acoustic signature generation and bounded ASR, retaining it until both finish. The ASR adapter recognizes that same file and applies the acquired `sourceStartMs` once to transcript timestamps. An acquisition failure still takes the independent bounded-ASR path against the original source URL; signature failure does not suppress ASR, and ASR failure does not discard derived signatures. Production acquisition uses a request-unique directory; only a directory explicitly marked as owned by that acquisition is cleaned up afterward. Stored transcript behavior and the 90-second-before/120-second-after source bounds remain unchanged.

Boundary coverage added:

- `SourceLinkImportTests.testAcquiredWindowFeedsASRWithAbsoluteSourceTimesWithoutRefetch` injects a nonzero source offset (110 seconds), checks one acquisition, ASR consumption of the exact acquired file while it exists, zero original-URL transcription calls, and absolute-time context around a 123-second anchor.
- `ConversationNavigationTests.testExportRejectsPersistedEvidenceChangeAfterDegradedReview` holds a stale reviewed draft, changes the persisted evidence, and verifies that the old degraded-consent fingerprint cannot authorize export.

Checks, all on the same iPhone 17 Pro / iOS 26.5 simulator `856FA6EF-5E03-4120-939B-F0EF42A804E8` when applicable:

- Focused app rerun: 2 passed, 0 failed — `shared-acquisition-focused-rerun.log`. The first focused run exposed an incorrect test expectation about the anchor-overlapping segment; the expectation was corrected before the passing rerun.
- Fast plan: verified; 326 package passed, 1 expected skip, 12 browser and 22 runner tests passed, with contracts/surfaces/inventory passing. Manifest `artifacts/test-runs/20260923-134316-700058-fast/manifest.json` and `shared-acquisition-fast.log`.
- Full app plan: verified; 476 passed, 0 failed, 0 skipped. Manifest `artifacts/test-runs/20260923-134346-429116-app/manifest.json` and `shared-acquisition-app.log`.
- Both plans recorded input SHA-256 `2db3d5936d9b136a44a5dd98b1a8e95fed0195bb9ecc6ddd0fa20e9c31d5690c`; `git diff --check` passed. The earlier tracked diff SHA-256 `59913db322fc66e2eb330685f18780dc789733ec6514aee8a0a86e9fa2ab9ea0` was computed from a transient stream; no snapshot file was saved for that state.

Remaining limits: The injected boundary test checks shared-file handoff and transcript time coordinates; it does not use live speech recognition or require a nonempty ShazamKit signature from its synthetic sound. The app test log still contains the previously noted temporary SQLite test-database unlink diagnostics, with no reported simulator system-process crash. Recipient recovery/F remains outside this correction. No commit, merge, installation, or distribution occurred.
