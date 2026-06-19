# Playback Spine Steward Packet

This packet is the frozen coordination baseline for restarting playback-spine parallel tracks.

## Base

- Base branch: `codex/playback-spine-refactor`
- Target branch for all restarted work: `codex/playback-spine-refactor`
- Required coordination docs:
  - `AGENTS.md`
  - `docs/parallel-track-coordination.md`
  - `docs/surface-contract-governance.md`
  - this packet

Gate agents must rebase or branch from the current head before starting. Prior draft PRs may be used as reference material only; do not merge or continue them directly unless the steward explicitly assigns cleanup work.

## Steward-Owned Shared Vocabulary

### Commands

Use only command ids listed in `validation/contracts/command-matrix.json`.

Playback-spine relevant ids:

- `startSession`
- `play`
- `pause`
- `resumePlayback`
- `togglePlayPause`
- `stopPlayback`
- `skipForward`
- `skipBack`
- `jumpToChapter`
- `beginInterjection`
- `finishInterjection`
- `cancelInterjection`
- `generateInterjectionSummary`
- `playTurn`
- `submitFollowup`
- `endSession`
- `loadWatchPackage`
- `importWatchSyncEvent`
- `importBrowserText`
- `attachBrowserMedia`
- `importSourceLink`

`importSourceLink` and `attachBrowserMedia` are backend-request commands. Gate agents may reference them in surface contracts, but must not add replayed trace steps that execute them until steward runtime and harness support exists.

### Snapshot Fields

Use only field ids listed in `validation/contracts/snapshot-fields.json`.

Playback-spine relevant ids:

- `sessionId`
- `itemId`
- `targetType`
- `targetId`
- `status`
- `phase`
- `title`
- `chapterTitle`
- `progressPercent`
- `sourceProgressPercent`
- `currentPlaybackProgressPercent`
- `currentMediaTimeMs`
- `currentPlaybackDurationMs`
- `currentTranscriptSegmentId`
- `currentAnchorConfidence`
- `playbackRate`
- `isRecording`
- `activeInterjectionCount`
- `pendingAiJobCount`
- `pendingAiJobKind`
- `pendingAiJobStatus`
- `lastUserTurnType`
- `availableCommands`
- `timeline`
- `linkResolutionStatus`
- `linkResolutionFailureReason`

Do not use aliases such as `mediaTimeMs`, `durationMs`, or `transcriptSegmentId` in surface snapshot contracts. Use `currentMediaTimeMs`, `currentPlaybackDurationMs`, and `currentTranscriptSegmentId`.

`linkResolutionStatus` and `linkResolutionFailureReason` are backend-request fields. They are accepted vocabulary but not implemented runtime output.

### Delegation Modes

Use only:

- `local`
- `delegated_to_canonical_runtime`
- `queued_offline`
- `unsupported`

## Trace Language

Replayed traces may use only commands, events, args, and expectation keys supported by `Packages/SessionKit/Tests/SessionKitTraceTests/TraceReplayTests.swift`.

Compact trace event currently allowed:

- `sessionSnapshotReceived`

Compact trace commands currently allowed through `CompactControlCommand`:

- `play`
- `pause`
- `togglePlayPause`
- `skipBack`
- `skipForward`
- `jumpToChapter`
- `beginInterjection`
- `finishInterjection`
- `cancelInterjection`
- `generateInterjectionSummary`
- `submitFollowup`

Compact trace expectation keys currently allowed:

- `title`
- `chapterTitle`
- `status`
- `phase`
- `targetType`
- `progressPercent`
- `sourceProgressPercent`
- `currentPlaybackProgressPercent`
- `currentMediaTimeMs`
- `currentPlaybackDurationMs`
- `currentTranscriptSegmentId`
- `currentAnchorConfidence`
- `playbackRate`
- `isRecording`
- `pendingAiJobCount`
- `pendingAiJobKind`
- `pendingAiJobStatus`
- `lastUserTurnType`
- `compactSurfaceReady`
- `delegatedToCanonicalRuntime`
- `noCrash`

Do not assert nested command payloads, app-open side effects, URL dispatch, local recording state, or backend command strings in replayed traces unless the steward first adds harness support.

## Schema-Validated Fixture Families

The validator covers these fixture families:

- `fixtures/capabilities/*.json`
- `fixtures/items/*.json`
- `fixtures/maps/*.json`
- `fixtures/sessions/*.json`
- `fixtures/interjections/*.json`
- `fixtures/turns/*.json`
- `fixtures/exports/*.json`
- `fixtures/watch/offline-package.json`
- `fixtures/watch/sync-*-event.json`
- `fixtures/audio/*.json`
- `fixtures/link-resolution/*.json`
- `fixtures/transcripts/*.json`
- `traces/*.json`

New fixture families are not allowed in gate tracks.

## Model Placement

- Use `Item.mediaType = "text"` for text sources, including text that may later have generated TTS audio.
- Use `Item.mediaType = "transcript_backed_media"` for podcast/audio/video sources with media or transcript timelines.
- Use `AudioRepresentation.sourceType` for playable audio source details, including `generated_tts_realtime`, `generated_tts_prerendered`, `native_media_file`, `browser_owned_media`, and `remote_stream`.
- Use `PlaybackPosition` and snapshot fields for current location.
- Use `Interjection.anchor` for durable captured source location.
- Treat AI context as derived from item, transcript timeline, playback position, and interjection anchor unless the steward explicitly promotes a persisted `AIContext` model.

## Merge Order

Restarted tracks should merge in this order:

1. steward baseline and validator support
2. surface/watch contract updates that use canonical snapshot fields
3. link intake fixtures and surface contract updates using `importSourceLink`
4. AI context docs/backend requests
5. any executable trace expansions, only after the steward updates runtime and harness support

## Required Handoff

Every restarted track must include:

- changed files
- contract deltas
- backend requests
- tests run
- tests not run
- open risks
- shared vocabulary needed but missing from this packet
- whether the PR changes executable traces
