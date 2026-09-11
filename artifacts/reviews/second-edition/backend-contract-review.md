# M2/M3 backend contract review

## Recommended runtime-packet allowlist

- `Packages/SessionKit/Sources/SessionKit/Models.swift`
- `Packages/SessionKit/Sources/SessionKit/SessionEngine.swift`
- `App/SpokenMarginsApp/Sources/SpokenMarginsApp/Gate1AppModel.swift`
- `Packages/SessionKit/Tests/SessionKitTests/SessionKitCoreTests.swift`
- `Packages/SessionKit/Tests/SessionKitTests/PriorBuildPersistenceTests.swift`
- `App/SpokenMarginsAppTests/Gate1AppModelWorkflowTests.swift`

This excludes the store/protocol implementations: `saveInterjection` already overwrites the record keyed by its existing `id` and persists its `sessionId` (`SQLiteSessionStore.swift:144`; `Protocols.swift:35`). It also excludes presentation files, which can call the app-model interfaces below. Do not add command IDs, snapshot fields, or a separate note store. If the implementation expands the persisted public/package contract beyond the optional `Interjection` field below, add the matching schema/validator and inventory files in the same change.

## M2: global Margin identity, star, and explicit playback

`MarginRow.id` is session-qualified, but the existing star writer is not: `setInterjectionStarredForSharing(_ interjectionID:)` searches only `selectedItem.interjections` (`Gate1AppModel.swift:6596`). That will either fail or mutate an identically named Margin from the selected session when a global row belongs to another session.

**Recommended app interface:** `setMarginStarred(_ row: MarginRow, starred: Bool)`. Resolve the record through `store.loadInterjections(sessionId: row.interjection.sessionId)`, require the matching `id`, `sessionId`, and `itemId`, mutate only that record, save it, then refresh global rows. Keep the existing selected-item helper as a compatibility wrapper if current sharing UI needs it. The existing persistence/reconstruction curation test at `Gate1AppModelWorkflowTests.swift:333` is the closest base; extend it with two sessions containing the same interjection id.

**Recommended canonical playback interface:** `SessionEngine.playInterjectionAnchor(_ interjection: Interjection) throws -> SessionSnapshot`, wrapped by `Gate1AppModel.playMarginMoment(_ row: MarginRow)`. The app-model wrapper must first load the session named by the row, reject a missing or mismatched item/session, inspect that exact session, prepare that item’s source-media bridge, then invoke the engine once and move to Playback. It is the explicit action that may replace item A; passive detail/timeline browsing must keep using the current `openMarginInTimeline` guard (`Gate1AppModel.swift:1943`).

The engine method must validate that its current session equals `interjection.sessionId` and that the interjection belongs to that session/item before changing transport. It must select the original target and anchor before playback: media anchors use media time; text anchors use the saved character range/start; generated-turn anchors use the saved target id and character offset. It must call playback only after the selected target/position is persisted. Do not compose `playSourceFromBeginning()` with `seekMedia`/`seekText`: the former immediately starts at zero (`SessionEngine.swift:1085`), while the latter can seek only the already-current compatible target (`SessionEngine.swift:560`, `588`). `seekMedia` is also navigation that preserves the current status, so it cannot by itself implement explicit playback.

The existing target/anchor machinery is usable: `Interjection` already carries item/session/target identity and both media/text anchor values (`Models.swift:1214`), and `SessionEngine` already has source target selection, media/text seek, and generated-turn playback. The new engine method is needed to make their ordering atomic and avoid brief wrong-item/zero playback.

Required tests: cross-session colliding IDs star only the addressed record after store reconstruction; reading foreign Margin leaves active item/session/rate/position unchanged; explicit play switches only to the row's session/item and starts at its media/text/generated anchor; an unavailable/mismatched target yields recoverable failure with no source replacement. Reuse media/text/generated anchor tests in `SessionKitCoreTests` around the existing recording and seek coverage rather than inventing fixtures.

## M3: written capture transaction

`beginInterjection`/`finishInterjection` cannot be repurposed. They start the recorder, allocate audio-oriented state, schedule transcription, and resume playback (`SessionEngine.swift:1149`, `1182`). `cancelInterjection` also always calls `playCurrentTarget` (`1274`). Those behaviors violate zero microphone/transcriber use and prior-paused preservation.

**Recommended model field:** add optional `captureKind: InterjectionCaptureKind?` to `Interjection`, with `.audio` and `.written`. Decode absent legacy values as audio/missing-recording semantics, never written. A written record uses `captureKind == .written`, `audioPath == nil`, nonempty exact `displayText`/`transcript`, and a completed/non-retryable transcription state. A legacy or audio-kind record with `audioPath == nil` remains a missing/failed recording, so UI must not use `audioPath == nil` alone to infer a written note. This optional Codable field needs a prior-build decode/reconstruction test; the existing store uses Codable payloads, so no SQLite table migration is required.

**Recommended engine transaction:**

`beginWrittenInterjection() throws -> WrittenInterjectionCapture`  
`saveWrittenInterjection(captureID: String, text: String) throws -> SessionSnapshot`  
`cancelWrittenInterjection(captureID: String) throws -> SessionSnapshot`

The opaque capture contains the immutable session/item/target/anchor and an original transport-state flag for display only; the engine retains the authoritative pending capture. Begin must require a current session and navigation permission, synchronously freeze/sync its current target exactly as recording does, save the pre-pause active/paused state, and pause without requesting microphone permission or calling the recorder/transcriber. Save trims only to test emptiness, retains the original interior text, and writes exactly one record from the stored lock; only clear the pending capture after a successful store save. A store failure keeps the same capture, anchor, text supplied by the view, and transport paused for retry. Cancel clears the pending capture and restores playing only when it was playing at begin; a previously paused source stays paused. Reject stale/double save/cancel and all navigation/session mutation while a written capture is pending, so an interruption or later item selection cannot attach a note to another session.

**Recommended app interface/state:** `beginWrittenMargin()`, `saveWrittenMargin(text:)`, and `cancelWrittenMargin()`, plus one observable draft/presentation state that owns the capture ID and unsaved text. It should participate in the existing recording-navigation exclusion rather than pretending `snapshot.isRecording` is true. The existing `ExperienceRecordingView` and `recordingPresentationContext` are presentation references only; the runtime should not fabricate an audio recording state for written capture.

Required tests: active and pre-paused source restoration; no recorder/transcriber calls; exact whitespace-preserving text and anchor after reconstruction; cancel writes nothing; injected save failure then retry writes once; late save after cancel/session switch fails without a new record; generated-turn target remains generated. `SessionKitCoreTests` already covers exact anchor freeze, recording navigation lock, cancellation, and generated-turn interjections; `Gate1AppModelWorkflowTests` is the right seam for app-level permission denial and recovery routing.

## Review limits

This was a read-only API feasibility review. No build, tests, simulator, or layout verification was run. The exact UI lease should follow after these runtime interfaces are frozen; it must not duplicate session lookup, anchoring, or pause/resume decisions.
