# SessionKit Contract

## Purpose

SessionKit is the production runtime contract for Spoken Margins. It is responsible for executing a listening session consistently across iPhone, iPad, Mac-via-iPad, watch, lock screen, CarPlay, and browser-extension clients.

SessionKit must be deterministic enough to test with JSON behavior traces.

SessionKit must also be capability-aware. Every command is evaluated against the active runtime capability profile before state-specific validation runs.

## Core Concepts

### Item

An item is durable content the user wants to listen to or discuss.

For resolved feed-backed content, `externalReference` identifies the imported episode or article while optional `sourceURL` identifies the canonical followable feed. These targets must not be conflated.

Item media types:

- `text`
- `transcript_backed_media`
- `assistant_turn`

### Session

A session is one situated engagement with an item. A session can continue after original item playback into summaries, addenda, follow-up questions, and AI responses.

Session phases:

- `idle`
- `item_playback`
- `recording_interjection`
- `interjection_summary`
- `summary_playback`
- `addendum_capture`
- `ai_response_playback`
- `conversation`
- `finished`
- `abandoned`

### Playback Target

A playback target identifies what is currently being listened to.

Target types:

- `item_text_tts`
- `transcript_backed_media`
- `assistant_turn_tts`
- `summary_turn_tts`
- `browser_owned_media`

### Anchor

Interjections must be portable. They cannot depend only on local chunk indices.

Anchor types:

- `text`: character range plus surrounding text.
- `transcript`: transcript segment/span plus media timestamp.
- `media`: media timestamp plus optional transcript context.
- `turn`: assistant or summary turn segment plus character range.

Playback rate never changes the source anchor. If a video is played at 1.75x, an interjection still anchors to source media time and transcript span.

## Commands

SessionKit exposes these commands. Commands return either a new session snapshot or a structured failure.

```ts
startSession(itemId)
play()
pause()
togglePlayPause()
skipForward(unit)
skipBack(unit)
jumpToChapter(chapterId)
beginInterjection()
finishInterjection(audioRef?)
cancelInterjection()
generateInterjectionSummary(scope?)
playTurn(turnId)
submitFollowup(input)
endSession()
```

Movement units:

- `chapter`
- `segment`
- `sentence`
- `paragraph`
- `time_15s`
- `time_30s`

## Runtime Profile

Every SessionKit instance runs under one active runtime capability profile.

The profile declares:

- playback ownership and playable target types
- timeline anchor types available to the client
- interjection capture mode
- AI availability or deferral
- persistence/sync authority
- remote-control command rights

Standard profiles live in `fixtures/capabilities/` and are described in `docs/runtime-capability-model.md`.

Profile changes are normal session events. Examples include phone/tablet online to offline, tethered watch to untethered watch, browser media handoff to phone, and offline watch reconnect to phone/tablet.

SessionKit must recompute command availability after every profile transition and publish that availability with compact snapshots.

## Command Capability Gates

Baseline command gates:

| Command | Required capability |
| --- | --- |
| `startSession` | `canonical_persistence`, `receive_prepared_packages`, or `browser_session_handoff`, depending on source |
| `play` | a playback capability for the current target, or `send_transport_commands` for remote control profiles |
| `pause` | same as `play` |
| `togglePlayPause` | same as `play` |
| `skipForward` | playback ownership or `send_transport_commands` |
| `skipBack` | playback ownership or `send_transport_commands` |
| `jumpToChapter` | `chapter_timing` plus playback ownership or `send_chapter_jump` |
| `beginInterjection` | `record_audio` or `delegate_interjection_to_canonical_runtime` |
| `finishInterjection` | active local or delegated recording |
| `cancelInterjection` | active local or delegated recording |
| `generateInterjectionSummary` | `summarize_interjections` or `defer_ai_jobs` |
| `playTurn` | `summary_turn_tts` or `assistant_turn_tts` for the target |
| `submitFollowup` | `continue_discussion` or `defer_ai_jobs` |
| `endSession` | local session ownership or remote command authority |

Capability denial returns `invalid_command_for_capability`. State denial returns `invalid_command_for_state`.

Rollback units:

- `previous_segment`
- `previous_sentence`
- `previous_paragraph`
- `time_15s`
- `none`

## Command Behavior

### Start Session

`startSession(itemId)` creates a new session or activates an existing unfinished session, prepares the first playback target, and publishes a snapshot for all compact control surfaces.

If a Listening Map exists, the initial snapshot includes current chapter data. If no map exists, playback remains valid and uses item title as the primary label.

### Playback

`play()` starts or resumes the current playback target. It must not report `playing` until native playback has actually started or browser-owned media has confirmed playback.

`pause()` pauses playback and preserves source position.

`togglePlayPause()` is a convenience command for compact control surfaces.

`endSession()` synchronizes the last confirmed playback position, stops audio, and detaches the active runtime snapshot. An unfinished session remains `in_progress` and resumable; only a session that genuinely reached completion is `finished`. Relaunch may inspect the most recently updated unfinished session as paused, but must never autoplay it.

### TTS Text Normalization

Before any text is sent to a speech engine, SessionKit must produce a speech-safe rendering of the source text.

Required normalization:

- Markdown links preserve readable label text and remove the URL: `[reference](https://example.com/essay)` becomes `reference`.
- Raw `http://`, `https://`, and `www.` URLs are removed from spoken output.
- Bare domains with optional paths are removed from spoken output.
- Surrounding readable prose is preserved.
- Whitespace is collapsed after URL removal.

This normalization affects only the text sent to TTS. It must not mutate source item text, transcript text, anchors, exports, or Listening Map references.

### Navigation

`skipForward(unit)` and `skipBack(unit)` move within the current playback target. They must be idempotent at boundaries and must not crash when playback is paused, loading, recording, or finished.

Navigation must be predictable for the active target type. For text, movement should land on coherent semantic units such as chapters, sections, paragraphs, or sentences. For transcript-backed media, movement should use chapter or transcript timing when available and time increments otherwise. For browser-owned media, movement commands must be expressed in source media time and delegated when the browser owns playback.

SessionKit should not expose local chunk ids as the production navigation contract. Chunking, buffering, sentence grouping, or synthesis segmentation are implementation details used to achieve low-latency, natural playback.

`jumpToChapter(chapterId)` moves to the resolved chapter anchor. For transcript-backed media, this means jumping to the chapter's source media timestamp. For text TTS, this means moving to the chapter's text span.

### Interjection

`beginInterjection()` pauses current playback, captures the current target and source position, enters `recording_interjection`, and starts native recording.

`finishInterjection(audioRef?)` stops recording, saves audio, creates interjection metadata, schedules transcription/cleanup, rolls back according to settings, and resumes playback unless the prior state was finished.

Rollback must reorient the listener rather than simply rewind by an implementation artifact. The policy may be previous semantic unit, previous transcript segment, previous chapter boundary, time window, or none. The active policy must be stored with the session or package and be testable through traces.

`cancelInterjection()` stops recording, discards unsaved audio, rolls back, and resumes playback.

Interjection failures must not end the session. Audio save failure creates an active interjection only if a durable audio reference exists.

A private Interjection may persist optional local share-later curation: a star and a private note capped at 500 characters. This metadata is owner-only selection assistance. It must not enter an immutable reviewed revision, `.spokenmargins` manifest or artifact, imported commentary layer, session export, or recipient display. A star may determine the sender review's initial shortlist, but the explicit per-export Include decision remains authoritative.

### Summary And Discussion

`generateInterjectionSummary(scope?)` creates an AI job over scoped interjections. The default scope is active interjections against the original item in the current session.

Summary scope is part of the command contract. Valid scopes include:

- source-item interjections for the active session
- interjections targeting one summary or assistant turn
- an explicit set of interjection ids

SessionKit must not mix source-item interjections with AI-turn interjections unless the user or calling workflow explicitly requests that broader scope.

`playTurn(turnId)` plays a summary or assistant response as a playback target. Interjections during turn playback target that turn.

`submitFollowup(input)` creates a user turn and starts an assistant response job. Input may be typed text, a cleaned transcript, or a saved audio addendum after transcription.

### AI Output Structure

AI responses may include structured chapter/map data in addition to spoken text. Malformed chapter JSON, unresolved chapter anchors, or malformed Listening Map JSON must not discard otherwise usable assistant text.

Rules:

- assistant response text remains playable and exportable even if generated chapters are invalid
- invalid AI-generated structure becomes empty, failed, or repairable structure
- Listening Map parse and anchor failures preserve diagnostics for repair
- streaming speech should speak stable completed units, not unstable partial fragments

### AI Job Recovery

Failed, timed-out, or offline AI work creates or updates retryable jobs.

Retryable jobs preserve:

- job kind
- item id
- session id
- turn id when applicable
- playback mode or intended continuation mode
- provider type, base URL, model, and API key reference
- request messages or prompt payload
- attempt count
- last error

Retrying a job updates the existing job and related turn state. It must not duplicate conversation turns unless the user intentionally starts a new request.

### Export Boundaries

Exports are session-scoped by default. When one item has multiple sessions, exporting one session must not include interjections, turns, or AI-response notes from another session unless the user explicitly selects a cross-session export.

### Representation Lifecycles

Interjection audio, raw transcript, cleaned transcript, and user-visible display text have separate lifecycles.

Destructive actions require explicit intent. Removing or replacing one representation must not silently delete the others.

### Reviewed Sharing Foundation

Sharing uses immutable reviewed revisions rather than modifying a private `Interjection`. A revision records the sender-approved transcript, optional cleaned-audio reference, deterministic cleanup decisions, and at most 500 characters of context on either side of the anchor. Draft and review-pending revisions cannot be packaged.

`spoken-margins.package.v1` is the unpublished format's final data-minimized, integrity-checked envelope. The manifest declares source identity, required capabilities, typed artifacts, typed assets, content hashes, and redaction assertions. `spoken-margins.commentary-layer.v1` carries bounded durable anchors and explicitly selected reviewed representations. `spoken-margins.listening-map-proposal.v2` can carry portable scene proposals without treating sender timestamps as recipient-local truth. Raw private captures, unselected representations, complete source text or audio, diagnostics, filesystem paths, and unrelated turns are not package fields. Voice assets use `assets/audio/*.m4a`; acoustic evidence uses `assets/evidence/*.shazamsignature`; local source paths are never serialized.

The content digest covers the canonical sorted-key manifest with its digest omitted, the generated `preview.md`, and each sorted audio path, byte digest, and byte count. Digest success means **integrity checked, unsigned sender**; it is not identity authentication. Only a successful archive read can create the verified-package value accepted by the importer. Malformed archives or JSON, unknown fields, unsafe entries, non-HTTPS source URLs, unsupported schema versions, missing privacy assertions, attachment mismatches, unreadable audio, and digest or preview mismatches are rejected before import. Export replacement and audio extraction use staged same-directory items so failure preserves an existing destination.

Recipient imports persist `ImportedCommentaryLayer` and `ImportedCommentaryInterjection` records separately from local captures. Package and package-scoped IDs are provenance only; recipient-local IDs are the primary keys. The verified package digest is the idempotency key, and a repeated import returns a stable duplicate result without adding records. Sender reveal-mode suggestions remain evidence only: a new layer is disabled and has no active recipient reveal mode. Source resolution is persisted per note and the layer status is derived from those results.

Article resolution distinguishes resolved, ambiguous, wrong-source, and context-only outcomes. Raw character offsets are accepted only when the recipient text has the exact-edition hash captured over the original UTF-8 source and any supplied exact quote matches that range. Normalized hashes identify similar content but never authorize offset reuse. A unique exact quote or unique normalized quote can still resolve cross-edition text. Presentation, playback ownership, co-op replies, accounts, transport, and external enablement are separate work; v1 deliberately contains no reply/conversation fields.

Contract fixture registration:

| Fixture family | Schema | Expected result |
| --- | --- | --- |
| `fixtures/interjection-packages/*.json` | `spoken-margins-package.schema.json` | valid |
| `fixtures/sharing/cleanup-revision.json` | `interjection-share-revision.schema.json` | valid |
| `fixtures/sharing/commentary-layer.json` | `shared-commentary-layer.schema.json` | valid |
| `fixtures/sharing/listening-map-proposal.json` | `portable-listening-map-proposal.schema.json` | valid |
| `fixtures/invalid/interjection-packages/*.json` | `spoken-margins-package.schema.json` | invalid; the validator fails if one passes |

## Snapshot

Every command publishes a snapshot for compact surfaces.

```json
{
  "sessionId": "session-001",
  "itemId": "item-001",
  "targetType": "item_text_tts",
  "status": "playing",
  "phase": "item_playback",
  "title": "You Can't Inspect the Pill",
  "chapterTitle": "Anecdotes mislead",
  "progressPercent": 27,
  "playbackRate": 1.25,
  "isRecording": false,
  "pendingInterjectionCount": 2,
  "pendingAiJobCount": 0
}
```

## Failure Model

Failures are structured and exportable to diagnostics.

Required failure categories:

- `playback_start_failed`
- `playback_interrupted`
- `recording_permission_denied`
- `recording_failed`
- `audio_save_failed`
- `transcription_failed`
- `ai_provider_unreachable`
- `ai_response_invalid`
- `persistence_failed`
- `invalid_command_for_capability`
- `invalid_command_for_state`

Failure handling rules:

- Unsupported commands must not mutate session state.
- TTS start failure must not advance playback.
- Recording failure must not kill the session.
- Transcription failure preserves audio and keeps the interjection exportable.
- AI failure creates or updates a retryable AI job.
- Persistence failure keeps in-memory state and reports the failure.

## Invariants

- Sessions belong to one item.
- Interjections belong to one session.
- Interjections always have a target and a portable anchor.
- Local chunk ids and local segment indexes are never sufficient as the only anchor.
- Listening Map chapter positions are computed from anchors or transcript timestamps, not model-provided percentages.
- Playback rate never mutates source anchors.
- Async AI or transcription completion must merge into current state without overwriting newer session/interjection changes.
- All user-facing exports can be generated without a Listening Map.
- Exporting one session must not leak data from another session on the same item.
- Assistant text remains durable even when generated maps or chapters are malformed.
