# Sender capture durability handoff — September 23, 2026

Status: bounded #27 sender persistence slice implemented and host verified on `codex/co-op`. This is not product validation or a release handoff. No simulator boot, commit, merge, distribution, physical-device installation, or server work occurred. Existing dirty work and voice/anchor data were preserved.

## Changed files

- `Packages/SessionKit/Sources/SessionKitPersistence/SQLiteSessionStore.swift`: adds one transaction for protected owned-offline-asset rows and the Margin's evidence reference. The store validates asset/evidence identity and exposes a test-only failure seam after ledger writes.
- `App/SpokenMarginsApp/Sources/SpokenMarginsApp/Gate1AppModel.swift`: uses the atomic commit in `persistPodcastAnchorEvidence`; startup reconciliation invokes bounded orphan cleanup and reports its count.
- `Packages/SessionKit/Sources/SessionKitPersistence/PodcastAnchorEvidenceOrphanReconciler.swift`: deletes only signatures older than 24 hours with exact app-generated names inside the AnchorEvidence directory for a still-stored Margin, after checking all Margin and offline-ledger references. It skips symlinks, unknown directories, other filenames, young files, and files whose ownership cannot be proved.
- `Packages/SessionKit/Tests/SessionKitTests/SQLiteSessionStoreSafetyTests.swift`: injects failure between the two database writes and checks rollback after reopen, then successful/idempotent commit. An idempotent cleanup test preserves referenced, ledger-owned, young, unrelated, and unknown-Margin files.

## Verification

- Full `fast` plan passed: `artifacts/test-runs/20260923-165401-436184-fast/manifest.json`, 336 package tests passed, one expected corpus skip, zero failures. Log: `sender-durability-fast.log`.
- Generic `SpokenMarginsApp` `build-for-testing` passed and compiled the app test target without running it. Log: `sender-durability-app-test-build.log`.
- `git diff --check` passed.

## Limits

The signature file's atomic filesystem write and the SQLite transaction cannot be one transaction. A crash between them can leave an unreferenced app-owned file, which startup cleanup may reclaim only after the 24-hour age gate. Files for deleted/unknown Margins and uncertain paths remain untouched. The cleanup test is host-side; app startup, live capture, adapters/speech, resource use, and product behavior have not been exercised because simulator execution remains blocked by the XCTest connection stall. No complete #27 gate is claimed.

## Independent audit corrections

- `Packages/SessionKit/Sources/SessionKitPersistence/PodcastAnchorEvidenceIntegrityReconciler.swift` now classifies evidence reads. Confirmed missing files and successfully read corrupt bytes invalidate a committed reference; permission or other indeterminate read failures retain the original reference, provenance, offset, and committed window for a later reconciliation attempt. `Gate1AppModel.swift` uses this policy and records the indeterminate count.
- `SQLiteSessionStore.swift` now checks, inside the same transaction, that every newly installed or changed evidence reference has a matching protected ledger row among that commit's inputs. It permits unchanged legacy references already in SQLite. Store tests reject omitted and mismatched rows, verify rollback/idempotence, and reopen after an injected indeterminate read to confirm that the committed reference survives.
- The corrected full `fast` plan passed: `artifacts/test-runs/20260923-170119-025365-fast/manifest.json`, 337 package tests passed, one expected corpus skip, zero failures. Log: `sender-durability-correction-fast.log`.
- Generic `SpokenMarginsApp` `build-for-testing` passed without running XCTest. Log: `sender-durability-correction-app-test-build.log`. `git diff --check` passed. No simulator was booted.
