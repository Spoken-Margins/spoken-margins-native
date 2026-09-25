# Remaining reliability fixes — Sol handoff

September 24, 2026. Branch `codex/co-op`, base HEAD `34837c6055471297ca0b360c591f734bad5c2c82`, with pre-existing uncommitted changes preserved. Status: **implemented, not verified**. The owner requested individual implementation fixes and deferred system testing to a subsequent Sol pass. No build number was advanced and no new binary was produced.

## Individual fixes

1. **Resume recipient searches after restart.** `RecipientTranscriptRecovery.swift` defines private versioned checkpoints with an exact edition digest, duration, planned intervals, completed timelines and suspension state. `SQLiteSessionStore` stores them as an additive private record kind in the existing schema-5 records table, validates bounds/identity, rejects superseded writers, and includes them in ordinary item deletion/reset. No share-package schema, command, snapshot field or transcript export was added. `Gate1AppModel` checkpoints each completed window, resumes jobs at startup/foreground, rejects changed editions, and reuses completed work only after hashing the current file. Temporary window audio is removed after each successful checkpoint; text remains private in SQLite.
2. **Share the speech service fairly.** `SpeechRecognitionQueue.swift` provides a process-wide FIFO lease with cancellation-aware waiting and a 64-waiter cap. Production `SystemSpeechTranscriptionClient` and `SystemSourceTranscriptionClient` entry points use it. Recipient jobs return to the tail after each window; they do not hold a lease across an entire sweep. Existing full-source map and Margin calls hold the lease for their current operation and are not preempted. Queue-full failures retain recipient progress for a later foreground/readiness attempt.
3. **Use a bounded supported recognizer fallback.** Source recognition attempts the preferred analyzer, then the existing on-device legacy path against the same acquired file. The legacy path preserves the source-time offset and existing bounded chunking. A preferred-service failure switches later source work to legacy; legacy-service failure opens a process-wide source circuit. Input/empty-window errors and cancellation are distinguished from service failure. Recipient service/empty-window suspension is durable. Existing user-triggered Retry/Download Again resets the circuit under the same queue lease and resumes suspended work. Ordinary readiness/foreground events cannot reset it.

## Changed source for this pass

- `Packages/SessionKit/Sources/SessionKit/RecipientTranscriptRecovery.swift` (new)
- `Packages/SessionKit/Sources/SessionKitPersistence/SQLiteSessionStore.swift`
- `Packages/SessionKit/Sources/SessionKitAudio/SpeechRecognitionQueue.swift` (new)
- `Packages/SessionKit/Sources/SessionKitAudio/AudioAdapters.swift`
- `App/SpokenMarginsApp/Sources/SpokenMarginsApp/Gate1AppModel.swift`
- `Packages/SessionKit/Tests/SessionKitTests/SQLiteSessionStoreSafetyTests.swift`
- `Packages/SessionKit/Tests/SessionKitTests/SpeechRecognitionQueueTests.swift` (new)
- `App/SpokenMarginsAppTests/SpokenMarginsPackageHandoffTests.swift`
- Release-lane and status/handoff documentation.

The broader working-tree diff also contains earlier podcast fixes and unrelated owner work. Do not discard or attribute all of it to this pass.

## Evidence and next verification

Source and diff review only; `git diff --check` passed. No compiler, tests, simulator, physical device, independent audit, commit, or distribution in this pass. Earlier passing gates do not verify these changes.

Focused regression source covers persistence/reopen, invalid bounds, superseded writers, item deletion, durable suspension, startup skipping completed windows, FIFO fairness, cancellation, sticky fallback, cross-item circuit suspension, explicit retry, and input failures that must not suspend a healthy service. Execute these first and repair any compilation/runtime defects before the required broader gates.

Retain the previous XCTest-runner connection evidence and diagnose that blocker before runtime retries. Preserve the iPad crash restriction. Then verify actual AV export duration/offset behavior, adapter and speech paths, recipient/sharing UI seams, and the held-out #27 gate (zero false-confident placements, p95 error at most 1.5 seconds). Use current `docs/testing.md` for selections. Physical-device capture/resource measurement and the owner handoff remain separate; device installation/distribution still require their existing authorization boundaries.

## Deliberate limits

- The existing 44-request cap, including at most 36 sweep windows, remains. An episode outside that coverage stays unresolved; restart does not reset the budget or claim uniqueness.
- A recognizer operation already running is not preempted by queued work. This pass does not change Apple's underlying task timeout behavior.
- The supported fallback is the existing local recognizer, not a cloud service. Hardware/locale availability must be exercised during verification.
- Complete private checkpoints retain transcript text locally to avoid repeating expensive sweeps for unresolved/new layers. They do not become authored source transcripts or travel in the package; permanent item deletion/reset removes them.
- This finishes the three documented implementation gaps. It does not establish capture coverage, placement accuracy, resource cost, release readiness, or human validation.
