# Sender B–E lifecycle handoff — 2026-09-23

Writer lease returned. This checkpoint covers the sender capture lifecycle and share transport, not recipient packet F. No branch, commit, install, or simulator boot was made by this agent. Account usage last checked at 17% used / 83% remaining, above the owner's 80% floor.

## Implemented

- Generation-bearing pre/post callbacks fail closed if the durable role row is absent; completed/interrupted rows no longer accept a late same-generation callback. A newer attempt can replace a pending tap accumulator for the same session/Margin without crossing another session.
- Startup and foreground scan persisted podcast capture jobs. A missing, empty, malformed, byte-count-mismatched, or digest-mismatched signature is removed from the exportable evidence list and its committed flank becomes retryable or unavailable; valid sibling evidence and a known exact-edition digest remain. Interrupted jobs become retryable, and bounded reattachment is attempted when the active source returns to playback. Per-role diagnostics retain attempt, state, and first failure category without paths.
- Newly committed signature references carry byte count and SHA-256. The app registers each as a non-reproducible, interjection-protected owned offline asset. This preserves the evidence against routine cache eviction. The pre-existing source-window acquisition path derives reference fingerprints independently of its `try?` ASR result.
- The tap converts unsupported decoded PCM to mono Float32 on its worker, outside the playback callback. An interleaved Int16 fixture now produces a post signature. Native supported Float32 mono stays on the direct path.
- Share export refreshes included Margins from storage, binds degraded consent to item, anchor, edition, reviewed content, window state, and evidence digests, and pins selected machine-evidence bytes to temporary immutable files before archive assembly. Missing/changed selected evidence either enters the reviewed degraded disposition or fails export; it cannot silently disappear during archive assembly. Each podcast Margin carries an optional versioned, privacy-reduced outcome summary (included roles/provenance, disposition, safe reason category). Legacy packages decode the absent summary as unknown.

Files changed in this slice: `App/SpokenMarginsApp/Sources/SpokenMarginsApp/Gate1AppModel.swift`, `App/SpokenMarginsAppTests/ConversationNavigationTests.swift`, `Packages/SessionKit/Sources/SessionKit/{Models,SessionEngine,SharingModels}.swift`, `Packages/SessionKit/Sources/SessionKitAudio/PostResumePodcastEvidenceCapture.swift`, `Packages/SessionKit/Sources/SessionKitSharing/SharingFoundation.swift`, `Packages/SessionKit/Tests/SessionKitTests/{SQLiteSessionStoreSafetyTests,SharingTests}.swift`, `Contracts/schemas/{interjection,shared-commentary-layer}.schema.json`, and `Contracts/fixtures/sharing/commentary-layer.json`. Other tracked changes in the frozen diff predate this slice and were preserved.

## Verification

- Final `.venv/bin/python scripts/verify-tests.py --plan fast` passed runner, contracts, surfaces, inventory, browser, and package steps. Evidence: `artifacts/test-runs/20260923-125920-219245-fast/manifest.json`; log `sender-fast.log`. Package count: 325 passed, 0 failed, 1 expected held-out-corpus skip.
- Final `xcodebuild -project SpokenMarginsNative.xcodeproj -scheme SpokenMarginsApp -destination 'generic/platform=iOS Simulator' build-for-testing` passed (`TEST BUILD SUCCEEDED`), log `sender-app-test-build.log`. It compiles the new app reconciliation/summary tests but does not execute them.
- Focused host tests passed for outcome roundtrip/legacy decode, worker Int16 conversion, unchanged Float32 pre capture, and same-key rearm. `git diff --check` passed.
- An intermediate fast run found a pre-window duration regression from unnecessary Float32 resampling. The worker now preserves already-supported Float32 mono and the original plus new conversion tests pass; the final fast gate passed.

Frozen tracked-tree snapshot: `sender-lifecycle-working-tree.diff`, 234,916 bytes, SHA-256 `83ef297f92a95efbd860e7be7011eb19600e93851b79f2e4fb30ee38d42ba04d`. Compare with the previous `capture-corrections-working-tree.diff` to isolate this slice. Do not rewrite the snapshot during audit.

## Remaining proof and limits

- The app reconciliation/export tests are compiled but await the parent's one authorized app-plan run on the already-booted, unlocked simulator. A passing build does not establish a runtime user flow. No physical streamed-podcast or crash-injection run was performed.
- The owned-asset ledger save and Interjection save are sequential rather than a single database transaction. A crash between them can leave an orphan ledger entry; startup reconciliation protects correctness of referenced evidence but does not reclaim all unreferenced files/ledger entries. A file written just before a crash without a committed record is treated as an interrupted job, not promoted to verified evidence.
- Older hypothetical capture-window records containing source-reference role values still require a decode migration if found; no known app path created such records. Recipient matching/recovery remains packet F.
- Review state and evidence are refreshed before export and machine evidence is pinned; voice files and source metadata still rely on existing archive validation rather than a single cross-table database snapshot. Any race detected after the reviewed degraded decision fails the export; it does not silently omit evidence.
