# Gate 1 Readiness Matrix

Date: 2026-06-15

This matrix is an adversarial readiness check for Gate 1: Phone/Tablet Core Session. It is derived from `docs/product-validation-plan.md`, `docs/prototype-spec.md`, and `docs/sessionkit-contract.md`.

Readiness is intentionally stricter than implementation status. A behavior is ready only when it has a product user path, a core API path, durable side effects, automated checks that assert behavior rather than visibility, and runtime evidence appropriate to the feature.

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
| Partial | 33 |
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
| G1-APP-OWNED-TTS | Production app-owned TTS | Playback controls | `SystemSpeechPlaybackClient` | Partial | Offset-aware playback and Siri/enhanced voice selection exist; device start/progress evidence is still missing. |
| G1-PLAY-PAUSE-PRESERVE-POSITION | Play/pause preserves position | Play/pause button | `pause`, `resumePlayback` | Partial | Session state is tested, native TTS position is not observable. |
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
| G1-AI-DISCUSSION-RESPONSE | AI discussion response | Submit with provider | Provider call + `aiStreamDelta` | Partial | Response text can persist; spoken response loop is not reachable/proven. |
| G1-INTERJECT-INTO-AI-RESPONSE | Interject into AI response | Play assistant response -> Interject | `playTurn` + interjection | Partial | Product path exists; UI/device evidence remains. |
| G1-AI-FAILURE-RETRY | Retryable AI failure | Retry AI button | `aiProviderFailed`, `retryAIJob` | Partial | Core trace exists; no UI/provider failure evidence. |
| G1-OFFLINE-DEGRADED | Offline degraded behavior | Settings profile picker | Capability profile | Partial | Profile changes rebuild the engine; deferred-job UI/device evidence remains. |
| G1-SESSION-ISOLATED-EXPORT | Session-isolated export | Export screen | `buildExport` | Partial | Core trace exists; UI test does not prove isolation, options, or Markdown export. |
| G1-HOME-STOPS-SPEECH | Home stops current speech | Home button | `stopPlayback` | Partial | Stop path exists; UI/runtime evidence remains. |
| G1-END-SESSION | End session | Playback End Session | `endSession` | Partial | Command and UI exist; persistence/runtime test evidence remains. |
| G1-OBSIDIAN-BULK-IMPORT | Bulk import Obsidian Markdown clips | Home -> Import Obsidian Files | `ObsidianMarkdownParser`, `importObsidianMarkdownFiles` | Partial | Parser tests cover nasty clip shapes; native document-picker UI/device evidence and raw-source storage remain. |
| G1-AI-MODEL-ROUTING | Separate map/summary/conversation models | Settings provider fields | `modelForAIJob`, provider request builder | Partial | Runtime routing exists; provider-observed payload tests and Listening Map job persistence remain. |
| G1-OVERVIEW-PREFACE-PLAYBACK | Listening Map overview plays before source audio | Start item with Listening Map | `startSession`, `playbackText` | Partial | Core test proves prepared text includes overview; device audible evidence remains. |
| G1-PREPARED-SUMMARY-SEQUENCING | Prepared source summaries wait for item completion; AI-turn summaries do not interrupt active AI playback | Prepare/generate summary during playback | `autoPlayCompletedTurn`, `playPendingTurnIfReady` | Partial | Core/app policy exists, but full provider/audio UI evidence remains. |
| G1-AI-TURN-TIMELINE-NAVIGATION | AI turns and AI-turn chapters are playable from primary timeline | Playback timeline AI rows | `playTurn`, `jumpToTurnChapter` | Partial | Core tests and product controls exist; UI automation should still tap seeded AI timeline rows. |
| G1-KOKORO-SIMULATOR-STUB-DEVICE-EVIDENCE | Kokoro simulator stub plus real device evidence | Settings TTS Mode -> Kokoro | `FakeGeneratedSpeechPlaybackClient`, `KokoroSpeechPlaybackClient` | Partial | Simulator CI is unblocked; real Metal render/playback evidence remains. |
| G1-DEVICE-EVIDENCE | Phone/tablet runtime evidence | Manual device pass | Verification scripts | Not Ready | Existing artifacts are launch screenshots, not full microphone/TTS/provider/offline validation. |

## Highest-Risk Findings

1. **Device evidence is not sufficient.** Simulator launch/build evidence does not validate microphone, audio route, Speech.framework transcription, provider behavior, offline behavior, or actual audible rollback.
2. **Listening Map validation is still shallow.** A user-facing paste/validate path and valid-map UI test exist, but malformed-map UI coverage, structured multi-issue repair reports, and provider-output repair loops are missing.
3. **Generated playback sequencing needs end-to-end evidence.** Core/app policy now queues generated turns until active audio completion, but provider-driven UI validation and device audio completion evidence remain.
4. **Many newly wired runtime paths still need UI tests.** Summary playback, AI-response playback, AI timeline rows, Cancel, interjection detail, End Session, and offline profile changes are reachable but not fully proven through UI automation.
5. **Real ingestion and Kokoro need device/files-provider evidence.** Obsidian clip parsing and simulator Kokoro stubbing are covered, but native Files/iCloud and real Metal playback validation remain.

## Minimum Fix Set Before Product Validation

1. Add structured Listening Map repair reporting and UI tests for malformed pasted maps, or explicitly remove the repair loop from Gate 1 scope.
2. Add product UI tests that assert state/persistence changes, not only visible controls.
3. Add device validation evidence for microphone recording, Speech.framework transcription, saved audio files, Siri/enhanced voice quality, route/interruption behavior, provider failure/retry, and offline deferred jobs.
4. Add UI automation for generated source-summary auto-play, AI-turn summary queuing, and tappable AI turn/chapter timeline rows.
5. Add provider payload tests for per-task model routing and Listening Map parser-informed retry.
