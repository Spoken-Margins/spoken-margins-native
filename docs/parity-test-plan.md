# Parity Test Plan

## Purpose

The production implementation should not try to replicate the current prototype line-for-line. It should replicate the product behaviors that survived prototype learning and reject known-broken implementation patterns.

This plan defines how fixtures and traces should be used to verify parity.

## Test Layers

### Schema Validation

Every file under `fixtures/` and `traces/` must parse as JSON and validate against the relevant JSON Schema in `schemas/`.

Required validations:

- runtime capability fixtures against `runtime-capability-profile.schema.json`
- item fixtures against `item.schema.json`
- map fixtures against `listening-map.schema.json`
- session fixtures against `session.schema.json`
- export fixtures against `session-export.schema.json`
- watch packages against `watch-audio-package.schema.json`
- watch sync events against `watch-sync-event.schema.json`
- trace files against `session-trace.schema.json`

Trace validation must also resolve each trace's `runtimeProfile` to a profile fixture and verify that every `requiresCapabilities` entry is present in that profile. A trace that requires remote AI must fail under `phone-tablet-offline`; a browser media trace must fail if it does not have source media time and playback-rate observation.

### Domain Helper Parity

The current prototype's known-good helper behaviors should be preserved:

- strict Listening Map validation
- smart quote and fenced JSON recovery for maps
- anchor-based chapter resolution
- transcript preview truncation around 240 characters
- mapless export with surrounding anchors
- source interjections sorted before AI turns
- AI-turn interjections scoped to their turn
- provider settings without persisted plaintext API keys
- TTS speech text normalization that removes raw URLs and preserves Markdown link labels

The production test suite should preserve outcomes, not prototype mechanisms, for:

- predictable semantic navigation
- natural TTS continuity with minimal awkward pauses
- configurable rollback that reorients the listener
- diagnostic Listening Map repair
- robust AI-formatted JSON ingestion
- scoped interjection summaries
- stable streaming speech over completed units
- separate audio, raw transcript, cleaned transcript, and display text lifecycles

### SessionKit Trace Replay

Each trace in `traces/` defines:

- active runtime profile
- capabilities required by the scenario
- initial fixture references
- command sequence
- expected snapshots
- expected persisted objects
- expected failure behavior when applicable

The Swift SessionKit test suite should load these traces and replay them against a mock audio, recording, transcription, and AI provider environment.

The test harness should reject unsupported commands before state execution and assert `invalid_command_for_capability` when a command is intentionally invoked from an insufficient profile.

### Browser Extension Parity

Browser extension tests should generate session packages that conform to the same schemas.

Required browser scenarios:

- selected text converted into a text-backed item
- readable page text converted into a text-backed item
- transcript-backed video session anchored to media time and transcript span
- sped-up media interjection anchored to source media time, not wall-clock time

Browser tests must cover browser text and browser media as separate runtime profiles. Text capture/TTS and media-time observation are different capabilities.

### Phone/Tablet Offline Parity

Phone and tablet tests must include an offline profile.

Required offline scenarios:

- playback of local/prepared media
- optional local TTS when enabled by policy
- interjection recording with durable anchors
- deferred Listening Map, summary, and discussion jobs
- no provider diagnostics or remote AI calls while offline

## Required Acceptance Scenarios

### Original Playback With Five Interjections

The user starts original item playback, records five interjections, and playback resumes after rollback every time.

Expected:

- session remains active
- five active interjections exist
- every interjection has audio status
- every interjection has a portable anchor
- playback position advances coherently

### Mapless Playback

The user listens without a Listening Map.

Expected:

- playback starts
- compact surfaces show item title where chapter title would normally appear
- interjections anchor to surrounding text
- export remains useful

### TTS Link Normalization

The user listens to text that contains raw URLs, bare domains, or Markdown links.

Expected:

- raw URLs are not spoken
- bare domains are not spoken
- Markdown link labels are spoken without the URL target
- source text, transcript text, anchors, and exports still preserve the original content
- URL removal does not collapse surrounding prose into unreadable text

### Semantic Navigation And Rollback

The user skips backward, skips forward, jumps to chapters, and resumes after an interjection.

Expected:

- navigation lands on coherent semantic units for the target type
- text playback does not expose local chunk ids as the user-visible contract
- media playback uses transcript/chapter timing or source media time
- boundary movement is idempotent and does not crash
- rollback resumes from enough prior context to reorient the listener
- rollback policy is visible to tests and can vary by runtime/package

### Phone/Tablet Offline

The phone/tablet loses network during normal use.

Expected:

- local/prepared playback remains usable
- recording and durable anchors remain usable
- AI work is queued as deferred jobs
- provider diagnostics and remote AI calls are unavailable
- no command pretends remote AI completed while offline

### Chapter Navigation

The user jumps between Listening Map chapters from a compact surface.

Expected:

- playback target remains original item
- source position moves to chapter anchor
- no chapter is skipped by stale current-position state
- boundary jumps do not crash

### Lock Screen / Widget Controls

The user controls a phone/tablet session through a compact delegated surface.

Expected:

- snapshot displays current item, chapter, playback status, and recording state
- transport and chapter commands are delegated to the canonical runtime
- interjection commands are delegated to the canonical runtime
- unsupported persistence, recording, and AI controls are not exposed locally

### Summary, Addendum, Discussion

The user finishes original playback, generates a summary of interjections, listens to it, interjects into the summary, adds an addendum, and starts discussion.

Expected:

- summary is a conversation turn linked to the session
- summary-targeted interjection targets the summary turn
- addendum becomes a user turn
- assistant response is linked to the same session

### Scoped Interjection Summary

The user asks for a summary while focused on the source item, a summary turn, an assistant response, or an explicit selected set of interjections.

Expected:

- source-item summary includes only active source-item interjections for the session by default
- turn-focused summary includes only interjections anchored to that turn
- explicitly selected interjection ids override the default scope
- scopes never leak interjections from another session unless explicitly requested

### AI Failure And Retry

The AI provider is unreachable, times out, returns no text, or the device is offline.

Expected:

- user work is preserved
- retryable AI job preserves provider config, messages, item/session/turn ids, intended playback mode, attempt count, and last error
- retry updates the existing job and turn
- retry does not duplicate conversation turns unless the user starts a new request

### AI Response Interjection

The user listens to an AI response and interjects.

Expected:

- interjection target is the assistant turn
- anchor uses turn text/span, not original item text
- export places the interjection under the AI response in playback order

### Malformed AI Structure

The assistant returns usable text with malformed chapter JSON, unresolved chapter anchors, or malformed Listening Map JSON.

Expected:

- assistant text remains playable
- assistant text remains exportable
- invalid chapters/maps are empty, failed, or repairable
- invalid structure does not erase the response body

### Browser Video At 1.75x

The user starts a browser video session while media is sped up.

Expected:

- interjection uses source media timestamp
- playback rate is recorded as observation metadata
- transcript span is preserved
- wall-clock elapsed time is not used as the anchor

### Basic Car Controls

The user has only play/pause/back/forward.

Expected:

- back and forward move by configured unit
- play/pause toggles playback
- interjection behavior follows the configured basic-car profile
- no unsupported chapter UI is required

### Session-Isolated Export

The same item has multiple sessions.

Expected:

- exporting one session includes only that session's interjections and turns
- another session's source interjections do not appear
- another session's AI-response interjections do not appear
- cross-session export requires an explicit option

## Known-Broken Behaviors Not To Preserve

- Async map generation overwriting newer session or interjection state.
- Playback advancing after native TTS failure.
- WebView `MediaRecorder` as the production recording path.
- Polling shared defaults as the primary remote-control mechanism.
- Session state stored only in browser localStorage.
- Laptop-local Gemma as a required production provider.

## Current Prototype Checks

Use the current prototype tests as a reference, not as the full production gate:

- `npm test -- --run`
- `npm run build`
- `cargo test` in `src-tauri`

Future production checks should additionally replay every trace against SessionKit.
