# Runtime candidate review

Reviewed `artifacts/reviews/second-edition/runtime-review/candidate.diff` against the frozen input set. The initial SHA-256 check matched every identity in `inputs.json`. The final check still matches eight files; `Gate1AppModel.swift` and `Gate1AppModelWorkflowTests.swift` now differ. The steward reported that this is the in-progress compile repair replacing an invalid `snapshot.status == .finished` check with `snapshot.phase == .finished`; this review does not treat that known repair as an additional finding.

## Findings

### P1 — Global Margin deletion can mutate a same-ID Margin in the active session

`Gate1AppModel.deleteTranscript` and `deleteInterjection` pass only `interjection.id` to the engine ([`Gate1AppModel.swift:6778`](../../../../App/SpokenMarginsApp/Sources/SpokenMarginsApp/Gate1AppModel.swift:6778), [`Gate1AppModel.swift:6787`](../../../../App/SpokenMarginsApp/Sources/SpokenMarginsApp/Gate1AppModel.swift:6787)). Their engine endpoints also accept only that ID ([`SessionEngine.swift:2151`](../../../../Packages/SessionKit/Sources/SessionKit/SessionEngine.swift:2151), [`SessionEngine.swift:2167`](../../../../Packages/SessionKit/Sources/SessionKit/SessionEngine.swift:2167)). The new scoped overload is bypassed: without `sessionId`, `updateInterjection` first mutates the in-memory dictionary entry keyed solely by ID, or the matching ID in `currentSession` ([`SessionEngine.swift:3519`](../../../../Packages/SessionKit/Sources/SessionKit/SessionEngine.swift:3519)).

Counterexample: session A is currently playing and has interjection ID `ij-1`; the global Library opens a Margin from session B that also has ID `ij-1`. Deleting B's transcript or Margin mutates A, so B remains and A loses data. This violates the candidate's exact session identity guarantee even though playback and transcription callbacks were made session-qualified.

Make cleanup, representation deletion, and interjection deletion accept a required `sessionId`, route the app calls using `interjection.sessionId`, and add a duplicate-ID/two-session regression for each destructive action. The normal current-session convenience path should not be used by a global-row action.

### P1 — Written capture becomes indistinguishable from an audio Margin with no recording in exports

The new persisted model records `captureKind: .written` ([`SessionEngine.swift:1281`](../../../../Packages/SessionKit/Sources/SessionKit/SessionEngine.swift:1281)), but the export DTO has no capture-kind field ([`SessionExport.swift:40`](../../../../Packages/SessionKit/Sources/SessionKit/SessionExport.swift:40)); the export mapper drops it and emits `audioPath: nil` for every interjection ([`SessionEngine.swift:2327`](../../../../Packages/SessionKit/Sources/SessionKit/SessionEngine.swift:2327)); and the session-export schema cannot carry it ([`session-export.schema.json:45`](../../../../Contracts/schemas/session-export.schema.json:45)).

Counterexample: a written Margin with text `“Check source”` and an audio Margin whose recording is absent can both export as `transcriptionStatus`, transcript, and `audioPath: null`, with no representation kind. An importer or consumer cannot preserve the required written-versus-missing-recording distinction, despite the store retaining it.

Add an optional backward-compatible `captureKind` to `ExportInterjection`, the export schema, and the mapper; retain `null`/missing as legacy audio semantics. Add a written-export fixture/contract test that asserts the exact text and `written`, plus a legacy/missing-audio case that does not become `written`.

## Coverage and limits

The candidate's engine transaction validates an anchor before it changes the canonical session and restores the original persisted/runtime session on engine-level anchor playback failure. Written save keeps its draft pending when repository persistence fails, and written paths do not schedule source-window context. I found no code-level counterexample to streamed generated-turn queue handoff or the pre-paused written-save/cancel restoration in this pass.

No builds, tests, simulator runs, screenshots, or human product-flow validation were performed. The pending rerun reported by the steward is not evidence for this review.
