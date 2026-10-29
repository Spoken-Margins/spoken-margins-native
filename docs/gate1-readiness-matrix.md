# Gate 1 Readiness Matrix

> Historical evidence: this matrix predates Build 22. Its Kokoro/MLX references are retained only to explain the earlier gate and are not current build guidance.

Date: 2026-06-15

This matrix is an adversarial readiness check for Gate 1: Phone/Tablet Core Session. It is derived from `docs/product-validation-plan.md`, `docs/prototype-spec.md`, and `docs/sessionkit-contract.md`.

Readiness is intentionally stricter than implementation status. A behavior is ready only when it has a product user path, a core API path, durable side effects, targeted verification appropriate to the feature, and runtime evidence appropriate to the feature. Human validation is separate and can only be supplied by the product owner.

Machine-readable inventory: `validation/gate1-behaviors.json`

Audit command:

```bash
python3 scripts/audit-gate1-readiness.py
python3 scripts/audit-gate1-readiness.py --strict
```

`--strict` must fail until every row is ready.

## Status Summary

| Status | Count |
|---|---:|
| Ready | 1 |
| Partial | 32 |
| Not Ready | 1 |

Gate 1 is **not ready for product-owner validation**.

## Matrix

| ID | Behavior | Product Path | Core Path | Status | Primary Falsification Finding |
|---|---|---|---|---|---|
| G1-ITEM-IMPORT | Text item import or creation | Home create form | `importTextItem`, `startSession` | Partial | No UI test creates an imported item and inspects durable item/session state. |
| G1-MAP-LOAD | Load existing Listening Map | Seeded item chapters | `startSession`, `loadListeningMap` | Partial | UI smoke checks timeline existence, not durable map rows. |
| G1-MAP-GENERATE-MANUAL | Manual Listening Map generation | Item -> Generate Listening Map | `generateListeningMap` | Partial | Current implementation is deterministic sentence splitting, not AI/provider strict JSON generation. |
| G1-MAP-VALIDATION-REPAIR | Map validation and repair reports | Item -> Apply Listening Map JSON | `applyListeningMapJSON`, `parseListeningMapJSON` | Partial | Valid-map UI coverage exists; malformed-map UI coverage and multi-issue repair reporting are still missing. |
| G1-MAPLESS-SESSION | Mapless playback/export | Create item without map | `startSession`, `buildExport` | Partial | Covered by traces, not UI/runtime evidence. |
| G1-TTS-URL-CLEANUP | URL cleanup for spoken text | Create/start URL item | `SpeechTextNormalizer` | Ready | Core behavior is tested; runtime audible evidence is still useful but not blocking this narrow behavior. |
| G1-APP-OWNED-TTS | Production app-owned TTS | Playback controls | `SupertonicSpeechPlaybackClient`, durable generated-media attachment, `SystemSpeechPlaybackClient` failure fallback | Partial | Bundled M2/F2 rendering, two-chunk startup, live startup-position persistence, completed/total generation progress, uninterrupted full-item generation, durable audio/timeline promotion, generated chapter navigation, cancellation, fixed-synthesis/variable-transport speed, media reset recovery, render-gap waiting, and genuine-failure fallback are automated-test verified; physical-device performance and listening quality remain pending. |
| G1-PLAY-PAUSE-PRESERVE-POSITION | Play/pause preserves position | Play/pause button | `pause`, `resumePlayback` | Partial | Native TTS now publishes an interpolated presentation offset and conservative chunk recovery offset; pause-during-render and resume reuse are tested, while physical-device/Lock Screen evidence remains pending. |
| G1-CHAPTER-JUMP | Tap chapter jumps to anchor | Chapter/timeline row | `jumpToChapter` | Partial | Session state moves and audio restarts from the offset, but UI/device evidence is still missing. |
| G1-SKIP-BACK-FORWARD | Skip back/forward predictable movement | Back/forward buttons | `skipBack`, `skipForward` | Partial | UI test checks messages only; native TTS movement is unproven. |
| G1-INTERJECTION-BEGIN | Begin interjection | Interject button | `beginInterjection` | Partial | Mock traces cover core behavior; no device microphone evidence. |
| G1-INTERJECTION-DONE | Done saves audio/interjection/transcription pending/resume | Done button | `finishInterjection` | Partial | Scheduler hook exists, but concrete transcription and durable device audio evidence are absent. |
| G1-INTERJECTION-CANCEL | Cancel discards audio/resumes | Recording Cancel button | `cancelInterjection` | Partial | Implemented and core-tested; real recording/device evidence is missing. |
| G1-ROLLBACK-RESUME | Rollback/resume reorients listener | Finish interjection | `finishInterjection` | Partial | Audio is now asked to restart from rollback offset; policy configurability and device evidence remain. |
| G1-MULTIPLE-INTERJECTIONS | Five interjections in one session | Repeat Interject/Done | `beginInterjection`, `finishInterjection` | Partial | Trace-only; no real recording loop evidence. |
| G1-TIMELINE-SORT-DETAIL | Timeline sort/detail/delete transcript/delete interjection | Timeline detail sheet | `deleteRepresentation`, `deleteInterjection` | Partial | Product paths exist; UI tests and chapter description metadata remain. |
| G1-TRANSCRIPTION-LIFECYCLE | Async transcription pending/transcribed/failed | Finish interjection -> Speech.framework | `transcriptionCompleted`, `transcriptionFailed` | Partial | Real Speech.framework path exists; recorded-audio device evidence remains. |
| G1-SUMMARY-GENERATE | Generate interjection summary | Summary button | `generateInterjectionSummary` | Partial | App provider prompt loads all session interjections, bypassing scoped candidate selection. |
| G1-SUMMARY-PLAYBACK | Listen to summary | Conversation play turn / Discuss | `playTurn` | Partial | Product path exists and prepares turn text; UI/device evidence remains. |
| G1-INTERJECT-INTO-SUMMARY | Interject into summary | Play summary -> Interject | `playTurn` + interjection | Partial | Product path exists; UI/device evidence remains. |
| G1-FOLLOWUP | Addendum/follow-up | Conversation Submit | `submitFollowup` | Partial | Typed path exists; transcript/audio addendum inputs and UI proof are missing. |
| G1-AI-DISCUSSION-RESPONSE | AI discussion response | Submit with provider | Provider call + `aiStreamDelta` | Partial | Streaming sentence speech and persisted-turn replay use the canonical routed transport; live-provider and physical-device evidence remain pending. |
| G1-INTERJECT-INTO-AI-RESPONSE | Interject into AI response | Play assistant response -> Interject | `playTurn` + interjection | Partial | Product path exists; UI/device evidence remains. |
| G1-AI-FAILURE-RETRY | Retryable AI failure | Retry AI button | `aiProviderFailed`, `retryAIJob` | Partial | Core trace exists; no UI/provider failure evidence. |
| G1-OFFLINE-DEGRADED | Offline degraded behavior | Settings profile picker | Capability profile | Partial | Profile changes rebuild the engine; deferred-job UI/device evidence remains. |
| G1-SESSION-ISOLATED-EXPORT | Session-isolated export | Export screen | `buildExport` | Partial | Core trace exists; UI test does not prove isolation, options, or Markdown export. |
| G1-HOME-STOPS-SPEECH | Home stops current speech | Home button | `stopPlayback` | Partial | Stop path exists; UI/runtime evidence remains. |
| G1-END-SESSION | End session | Playback End Session | `endSession` | Partial | Command and UI exist; persistence/runtime test evidence remains. |
| G1-OBSIDIAN-BULK-IMPORT | Bulk import Obsidian Markdown clips | Home -> Import Obsidian Files | `ObsidianMarkdownParser`, `importObsidianMarkdownFiles` | Partial | Parser tests cover nasty clip shapes; native document-picker UI/device evidence and raw-source storage remain. |
| G1-AI-MODEL-ROUTING | Separate map/summary/conversation models | Removed in #2845 (no remote provider; on-device only) | `makeEngine`, `AppleFoundationAIProvider` | Partial | The remote provider and its settings were deleted; on-device summary and Listening Map evidence remain. |
| G1-OVERVIEW-PREFACE-PLAYBACK | Listening Map overview plays before source audio | Start item with Listening Map | `startSession`, `playbackText` | Partial | Core test proves prepared text includes overview; device audible evidence remains. |
| G1-PREPARED-SUMMARY-SEQUENCING | Prepared source summaries wait for item completion; AI-turn summaries do not interrupt active AI playback | Prepare/generate summary during playback | `Gate1PlaybackAutoplayQueue`, `autoPlayCompletedTurn`, `playPendingTurnIfReady` | Partial | App unit tests cover FIFO/manual-clear/completion transitions; full provider/audio device evidence remains. |
| G1-AI-TURN-TIMELINE-NAVIGATION | AI turns and AI-turn chapters are playable from primary timeline | Playback timeline AI rows | `playTurn`, `jumpToTurnChapter` | Partial | Core tests and targeted UI automation tap seeded AI timeline rows; device audio evidence remains. |
| G1-DEVICE-EVIDENCE | Phone/tablet runtime evidence | Manual device pass | Verification scripts | Not Ready | Existing artifacts are launch screenshots, not full microphone/TTS/provider/offline validation. |

## Highest-Risk Findings

1. **Device evidence is not sufficient.** Simulator launch/build evidence does not validate microphone, audio route, Speech.framework transcription, provider behavior, offline behavior, or actual audible rollback.
2. **Listening Map validation is still shallow.** A user-facing paste/validate path and valid-map UI test exist, but malformed-map UI coverage, structured multi-issue repair reports, and provider-output repair loops are missing.
3. **Generated playback sequencing needs end-to-end evidence.** Core/app policy now queues generated turns until active audio completion, but provider-driven UI validation and device audio completion evidence remain.
4. **Many newly wired runtime paths still need closeout evidence.** Summary playback, AI-response playback, AI timeline rows, Cancel, interjection detail, End Session, and offline profile changes are reachable but not yet protected by late-gate UI routes or human validation records.
5. **Real ingestion and device/provider evidence remain.** Obsidian clip parsing is covered, but native Files/iCloud import, real provider recovery, and device audio validation remain.

## Minimum Fix Set Before Product Validation

1. Add structured Listening Map repair reporting and UI tests for malformed pasted maps, or explicitly remove the repair loop from Gate 1 scope.
2. Run broad UI routes as late-gate closeout evidence, and add focused regression tests only after the product owner validates the flows worth preserving.
3. Add device validation evidence for microphone recording, Speech.framework transcription, saved audio files, system speech quality, route/interruption behavior, provider failure/retry, and offline deferred jobs.
4. Add or attach evidence for generated source-summary auto-play and AI-turn summary queuing on device.
5. Keep provider payload/model-routing tests green and attach live provider success/failure/retry evidence.

Supertonic 3 INT8 is the production app-owned TTS path. The optional Kokoro/MLX device scheme is retained only as legacy experimental code and is not part of the selectable product catalog or Gate 1 acceptance path.
