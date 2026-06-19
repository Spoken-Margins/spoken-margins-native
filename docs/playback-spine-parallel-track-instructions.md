# Playback Spine Parallel Track Instructions

Use these instructions when restarting parallel agents from the current `codex/playback-spine-refactor` head.

Each agent must begin by reading:

- `AGENTS.md`
- `docs/parallel-track-coordination.md`
- `docs/surface-contract-governance.md`
- `docs/playback-spine-steward-packet.md`
- its assigned agent card or section below

Agents must branch from current head. Do not continue the earlier draft PR branches unless the steward explicitly asks for cleanup.

## Common Rules For All Tracks

- Stay inside assigned files.
- Use only command ids, snapshot field ids, delegation modes, trace language, and fixture families listed in `docs/playback-spine-steward-packet.md`.
- Use canonical snapshot field names: `currentMediaTimeMs`, `currentPlaybackDurationMs`, `currentTranscriptSegmentId`, and `currentAnchorConfidence`.
- Do not use the aliases `mediaTimeMs`, `durationMs`, or `transcriptSegmentId` for snapshot fields.
- Do not add executable trace expectations for app-open behavior, nested payloads, backend command strings, or local recording side effects.
- Do not edit shared runtime, Xcode project files, schema files, validator scripts, or shared contract matrices unless the steward explicitly assigns that work.
- Missing shared vocabulary becomes a backend request.
- Run only:

```bash
python3 scripts/validate-contracts.py
python3 scripts/validate-surface-contracts.py
```

## Track A: Widget, Live Activity, And Watch Surface Anchors

### Objective

Update surface contracts for widget/Live Activity and Watch to consume the steward-approved playback-position snapshot vocabulary without inventing payload shapes or trace language.

### Branch

Suggested branch: `codex/restart-surface-playback-position-contracts`

### Allowed Files

- `validation/surface-contracts/gate3-watch-tethered.json`
- `validation/surface-contracts/gate4-watch-untethered.json`
- `validation/agent-cards/gate3-watch-tethered.md`
- `validation/agent-cards/gate4-watch-untethered.md`
- `docs/track-surface-playback-position-notes.md` if extra notes are needed

### Conditional Files

Do not edit `traces/lock-screen-widget-controls.json` or `traces/watch-chapter-navigation.json` unless every new expectation key is in the steward packet. Prefer backend requests over trace changes.

### Required Work

- Add or adjust surface contract language to prefer `currentMediaTimeMs`, `currentPlaybackDurationMs`, `currentTranscriptSegmentId`, `currentAnchorConfidence`, `sourceProgressPercent`, and `currentPlaybackProgressPercent` when present.
- Keep Watch tethered as remote-control-only.
- Keep Watch untethered as local prepared-package playback/recording only.
- Add backend requests for app-open interject URL dispatch, nested command payloads, or any runtime behavior not already implemented.
- Preserve existing trace references unless you are making a supported replay-safe change.

### Do Not Do

- Do not add `mediaTimeMs`, `durationMs`, or `transcriptSegmentId` as snapshot field names.
- Do not assert `openedApp`, `backendCommand`, `localRecordingStarted`, or nested `payload` in traces.
- Do not add widget/watch runtime implementation.

## Track B: Link Intake And Podcast Resolver Contracts

### Objective

Define contract-level share-sheet/paste URL intake for public podcast links using the steward-approved `importSourceLink` command and schema-validated `fixtures/link-resolution/*.json` fixture family.

### Branch

Suggested branch: `codex/restart-link-intake-contracts`

### Allowed Files

- `validation/surface-contracts/track1-link-intake-podcast-resolver.json`
- `fixtures/link-resolution/*.json`
- `fixtures/items/*.json`
- `docs/track-link-intake-notes.md` if extra notes are needed

### Required Work

- Use `importSourceLink` for URL intake contract work.
- Use `linkResolutionStatus` and `linkResolutionFailureReason` only as backend-request snapshot fields.
- Add link-resolution fixtures that validate against `schemas/link-resolution-fixture.schema.json`.
- Use `AudioRepresentation.sourceType = "remote_stream"` for public RSS/audio-backed podcast audio.
- Use `Item.mediaType = "transcript_backed_media"` for acquired podcast/audio items.
- Add backend requests for provider lookup, app share extension/paste routing, queue UI, and runtime persistence.

### Trace Rule

Do not add `traces/link-intake-podcast-resolution.json` yet. Link-resolution events are not replayable runtime trace language until the steward adds harness and runtime support.

### Do Not Do

- Do not add new command ids such as `resolveLink` or `importPodcastURL`.
- Do not add unvalidated fixture directories.
- Do not fabricate playable audio for exclusive/private links.
- Do not implement provider clients.

## Track C: AI Context Anchor Contract Notes

### Objective

Document how AI context should be derived from `PlaybackPosition`, transcript timelines, source text, and `Interjection.anchor` without adding persisted schema fields prematurely.

### Branch

Suggested branch: `codex/restart-ai-context-anchor-contract`

### Allowed Files

- `docs/track-ai-context-anchor-notes.md`
- `docs/sessionkit-contract.md` only if the change is clarifying prose and does not introduce new model vocabulary
- `validation/surface-contracts/*.json` only for backend requests explicitly about AI context availability

### Required Work

- Describe derived AI context for:
  - native text / generated TTS
  - prepared generated audio with text range mapping
  - native audio with transcript segment
  - transcriptless native audio fallback
- Use existing durable fields: `Interjection.anchor`, `PlaybackPosition`, `TranscriptTimeline`, `SourceLink`, and `AudioRepresentation`.
- Add backend requests for any proposed persisted `AIContext` model, export field, or provider prompt assembly API.

### Do Not Do

- Do not edit `schemas/interjection.schema.json`.
- Do not add `aiContext` fixtures under `fixtures/interjections`.
- Do not add `generated_tts` or `native_audio` as `Item.mediaType` values.
- Do not claim runtime prompt context exists unless a steward implementation lands it.

## Track D: Steward Runtime Follow-Up

This is not a gate-agent track. Assign only to the steward.

### Objective

Implement or accept the backend requests generated by Tracks A-C.

### Candidate Work

- App-open widget/Live Activity interject URL dispatch to canonical `beginInterjection`.
- Optional command payload model for compact surface anchor delegation.
- Link intake runtime command and queue persistence for `importSourceLink`.
- Provider-independent RSS lookup contract implementation.
- Derived AI context builder from item, transcript timeline, playback position, and interjection anchor.
- Additional executable trace language only after runtime behavior exists.

### Required Verification

```bash
swift test --package-path Packages/SessionKit
python3 scripts/validate-contracts.py
python3 scripts/validate-surface-contracts.py
xcodegen generate
xcodebuild -project SpokenMarginsNative.xcodeproj -scheme SpokenMarginsAppDevice -destination 'generic/platform=iOS' build | xcbeautify
xcodebuild -project SpokenMarginsNative.xcodeproj -scheme SpokenMarginsApp -destination 'generic/platform=iOS Simulator' build | xcbeautify
xcodebuild -project SpokenMarginsNative.xcodeproj -scheme SpokenMarginsWatch -destination 'generic/platform=watchOS' build | xcbeautify
```
