# Track C: AI Context Anchor Contract Notes

## Scope

AI prompt context for playback-spine work is a derived runtime concern. This track does **not** add persisted `AIContext` fields, interjection fixtures, trace expectations, media types, or command ids. A provider prompt may use derived context only after the steward lands an implementation that assembles it from accepted durable models.

Accepted durable inputs are:

- `Interjection.anchor` for the captured source location at the moment the user interjects.
- `PlaybackPosition` for the current playback location and confidence at capture or prompt time.
- `TranscriptTimeline` for transcript segment, span, and media-time lookup when transcript-backed media is available.
- `SourceLink` for source provenance such as an original URL, title, publisher, or canonical page/media identity.
- `AudioRepresentation` for playback rendering details such as generated TTS, prepared generated audio, native media files, browser-owned media, or remote streams.

## Derived Context Principles

- The durable anchor remains the source of truth. Prompt assembly may expand around the anchor, but it must not replace or mutate `Interjection.anchor`.
- `PlaybackPosition` is a location signal, not a new persisted AI model. It can help choose nearby text, transcript, media time, chapter, and confidence windows.
- `TranscriptTimeline` bridges media time to source words or segments when the item has transcript-backed media.
- `SourceLink` and `AudioRepresentation` explain where content came from and how it was played, but they do not create new item media types.
- Generated TTS over source text remains `Item.mediaType = "text"`; native podcast/audio/video remains `Item.mediaType = "transcript_backed_media"` when transcript or media timelines are present.
- Transcriptless audio can provide provenance and media-time context, but any semantic context beyond title/chapter/time requires a transcript, user-provided notes, or a future steward-approved extraction path.

## Surface-Specific Derivation

### Native text / generated TTS

For source text read with generated TTS, AI context should be derived from the text item and the current or captured text anchor:

1. Use `Interjection.anchor` when an interjection exists. For text anchors, include the anchored character range plus bounded surrounding text already represented by the durable anchor shape.
2. Use `PlaybackPosition` to resolve the current text offset, chapter, paragraph, or sentence when the prompt is not tied to a saved interjection yet.
3. Use `AudioRepresentation` only to describe the rendering path, for example realtime or prerendered generated TTS. The generated audio timing is not a separate source identity.
4. Use `SourceLink` as provenance when the text came from a URL, browser capture, or import flow.

Backend request: implement a derived text-context builder that accepts item text, `PlaybackPosition`, and optional `Interjection.anchor`, then returns bounded prompt context without persisting an `AIContext` field.

### Prepared generated audio with text range mapping

Prepared generated audio is still a rendering of source text. AI context should resolve through the prepared audio map back to text ranges:

1. Use `PlaybackPosition.currentMediaTimeMs` or the stored media timestamp inside `Interjection.anchor` to locate the prepared audio frame.
2. Resolve the frame through the prepared audio text range mapping owned by `AudioRepresentation` or its associated timeline metadata.
3. Expand the resulting source text range with a bounded before/after window from the original item text.
4. Preserve the original `Interjection.anchor`; the resolved text window is derived prompt input, not a durable replacement.

Backend request: define and implement the prepared-audio-to-text resolver used by prompt assembly. If the resolver needs serialized map fields beyond accepted `AudioRepresentation` metadata, the steward must add schema, validator, and fixture coverage first.

### Native audio with transcript segment

For podcast/audio/video with a transcript timeline, AI context should be transcript-first and media-time-aware:

1. Use a transcript anchor from `Interjection.anchor` when present, including segment/span and media timestamp.
2. Use `PlaybackPosition.currentTranscriptSegmentId`, `currentMediaTimeMs`, and `currentAnchorConfidence` to resolve or verify the active transcript segment.
3. Use `TranscriptTimeline` to include adjacent transcript segments within a bounded window around the anchor or playback position.
4. Include `SourceLink` provenance and `AudioRepresentation.sourceType` so the provider prompt can distinguish remote streams, native media files, and browser-owned media without changing `Item.mediaType`.
5. If anchor confidence is low or transcript mapping is ambiguous, mark that uncertainty in derived prompt metadata rather than inventing new persisted fields.

Backend request: implement a transcript-context builder that resolves `PlaybackPosition` plus `Interjection.anchor` against `TranscriptTimeline`, including confidence handling and bounded adjacent segment selection.

### Transcriptless native audio fallback

For native audio without a transcript timeline, AI context is intentionally limited:

1. Use media-time anchors from `Interjection.anchor` and `PlaybackPosition.currentMediaTimeMs` as location context.
2. Include available chapter/title metadata, source provenance from `SourceLink`, and playback details from `AudioRepresentation`.
3. Do not fabricate transcript text, source text, or semantic summaries.
4. Provider prompt assembly may say that no transcript is available and ask the user to clarify, defer until transcription exists, or use only coarse media-time/chapter context.

Backend request: implement an explicit transcriptless-audio context fallback that produces provenance, media time, and uncertainty metadata without claiming transcript-derived semantic context.

## Backend Requests To Steward

1. **Derived AI context builder**: add a runtime service that derives bounded prompt context from item data, `PlaybackPosition`, `TranscriptTimeline`, `SourceLink`, `AudioRepresentation`, and optional `Interjection.anchor`.
2. **Provider prompt assembly API**: define an internal API that consumes the derived context builder output and assembles provider prompts for summaries, follow-ups, and interjection discussion. This API should not require a persisted `AIContext` model unless the steward accepts one later.
3. **Export shape decision**: decide whether exports should include only durable anchors and source metadata, or whether they also need a separately versioned derived-context snapshot. If the latter is needed, add schema and validator support before any fixtures reference it.
4. **Prepared audio text mapping**: confirm the durable location of prepared generated audio text range maps and expose a resolver for prompt assembly.
5. **Transcriptless fallback policy**: land runtime behavior for transcriptless media prompts that clearly reports limited context instead of fabricating transcript semantics.

## Explicit Non-Goals

- No edits to `schemas/interjection.schema.json`.
- No `aiContext` fixtures under `fixtures/interjections`.
- No `generated_tts` or `native_audio` `Item.mediaType` values.
- No executable trace changes.
- No claim that runtime prompt context exists before steward implementation lands.
