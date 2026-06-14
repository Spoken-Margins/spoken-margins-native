# Prototype Lessons

## Purpose

This document separates durable product lessons from prototype implementation details.

The production app should preserve the product behavior that made the prototype useful. It should not copy mechanisms that were only workarounds for a web/Tauri prototype.

## Product Contracts To Preserve

These are user-visible or data-integrity requirements. Losing them would make the production app worse.

### TTS Link Cleanup

Text sent to speech must be a speech-safe rendering.

- Raw URLs and bare domains are not spoken.
- Markdown link labels are spoken without URL targets.
- Source text, transcripts, anchors, Listening Maps, and exports preserve the original content.

### Portable Anchors

Interjections must be anchored to durable source context.

Valid anchors include:

- text character spans and surrounding text
- transcript spans and source media time
- media time with transcript context when available
- assistant/summary turn spans

Local chunk ids, local segment indexes, and UI list positions are useful implementation metadata only. They are not sufficient as portable anchors.

### Mapless Usefulness

Listening Maps are core product infrastructure when available, but they are not required for a useful session.

Without a Listening Map:

- playback still works
- compact surfaces show item or target title
- interjections still preserve portable anchors
- exports remain useful

### AI Failure Recoverability

AI failures and offline provider states must not lose user work.

- Failed or deferred AI jobs preserve provider config, prompt/messages, session id, item id, turn id, playback mode, attempts, and last error.
- Retrying a job updates the existing job and turn rather than duplicating discussion state.
- Offline mode queues AI work instead of pretending it completed.

### AI Text Survives Bad Structure

Malformed AI chapter JSON, malformed Listening Map JSON, or invalid AI-generated anchors must not discard otherwise usable assistant response text.

The response remains playable and exportable. Structured chapters/maps become repairable or empty.

### Session-Isolated Exports

Items can have multiple sessions. Exporting one session must not leak interjections, turns, or AI-response notes from another session on the same item.

### Browser Media Source-Time Anchoring

Browser-owned media must anchor interjections to source media time and transcript spans, not elapsed wall-clock time. Playback rate is observation metadata only.

### Offline Mode Honesty

Every surface exposes only commands supported by its active runtime capability profile.

Examples:

- offline phone/tablet can keep local playback, anchors, persistence, recording, and deferred AI jobs
- untethered watch can play prepared packages and queue audio/anchor events
- browser media can observe source time and package handoff events
- lock screen/widget, tethered watch, and car surfaces delegate commands rather than owning runtime work

## Abstract Outcomes To Preserve

These came from real prototype learning, but production should preserve the outcome rather than the exact implementation.

### Predictable Navigation

Back and forward must feel predictable for the current media type.

Production can use chapters, transcript segments, sentences/paragraphs, semantic sections, or time increments. The requirement is that each command lands on a coherent next or previous unit, behaves safely at boundaries, and can be verified with traces.

### Natural TTS Continuity

Generated speech should start quickly, avoid awkward pauses, and not force the user to hear implementation boundaries.

Production does not need to copy prototype chunk sizes. It should choose the native playback strategy that best balances latency, pause frequency, battery, and interruptibility.

### Reorienting Rollback

After an interjection, playback should resume from enough prior context for the listener to re-enter the flow.

Rollback policy should be configurable and testable. It should not be hardcoded to the prototype's chunk algorithm.

### Listening Map Repair

When a generated or pasted Listening Map is invalid, the app should diagnose what failed and preserve enough context for repair.

Production does not need to copy prototype paste-back wording. It does need to distinguish parse failure, invalid schema, duplicate anchors, missing anchors, and unresolved anchors.

### Robust AI-Formatted JSON Ingestion

The app should tolerate common AI output wrappers when ingesting structured JSON.

Acceptable strategies include tolerant parsing, extraction of fenced JSON, extraction from surrounding assistant text, and careful smart-quote handling. The parser must not corrupt legitimate punctuation inside already-valid JSON strings.

### Scoped Interjection Summaries

The summary target matters.

Source-item interjections, summary-turn interjections, assistant-response interjections, and explicit selected interjection sets must be distinguishable so the AI summarizes the intended notes in the intended context.

### Conversational Interjections

Interjections may contain more than one human speaker.

The system should not assume every interjection is a single-speaker dictation. A recorded interjection can be a short conversation, debate, co-reflection, or assisted thinking session. When speaker diarization or labeling is unavailable, the app should preserve the raw audio and transcript uncertainty rather than forcing a false single-speaker interpretation.

AI summaries should be allowed to interpret conversational interjections carefully, including uncertainty about who said what, while still grounding the summary in the session anchor.

### Stable Streaming Speech

Streaming assistant output should not speak unstable partial fragments.

Production should speak completed units or otherwise use a native streaming strategy that avoids repeating, truncating, or speaking text that may be structurally reinterpreted by later model output.

### Separate Audio, Transcript, And Cleaned Text Lifecycles

Interjection audio, raw transcript, cleaned transcript, and user-visible text are distinct records with separate lifecycle rules.

Destructive actions require explicit intent. Deleting or replacing one representation must not silently destroy the others.

## Prototype Details Not To Freeze

The production app should not encode these as requirements unless later product work intentionally revives them:

- exact text chunk target sizes or hard maximums
- exact Listening Map warning thresholds
- exact repair prompt wording
- exact timeline ordering arithmetic from the React prototype
- localStorage migration shape, unless importing old prototype data becomes a product requirement
- current toast copy
