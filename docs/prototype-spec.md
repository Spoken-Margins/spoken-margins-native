# Spoken Margins Prototype Spec

## Goal

Build a local-first macOS prototype for listening to pasted text through Apple-quality text-to-speech, optionally navigating with AI-generated structure, and capturing spoken interjections as anchored session notes.

The prototype should prove the core loop:

1. Create a listening item from clean text.
2. Optionally add and validate a Listening Map.
3. Listen through chunked Apple TTS.
4. Interject with audio-first spoken notes.
5. Resume from nearby context.
6. Export a useful session note.

## Product Shape

Spoken Margins is not a read-it-later app, a podcast app, or a chat app. It is a structured listening workspace.

Reading has spatial affordances: headings, scrolling, skimming, margin notes, and easy jumping. Listening removes many of those affordances. Spoken Margins restores the most important ones through chapter markers, rough progress, anchored interjections, and post-session export.

## Terminology

Use `Item` as the durable product term.

An item is the content the user wants to listen to. In the prototype, an item is pasted text. Later, an item may originate from Obsidian, RSS, a share sheet, or transcript-backed audio.

Reserved future term:

```ts
mediaType: "text" | "transcript_backed_audio"
```

Avoid `Source` in new code and documentation. Older notes may use `Source`; read it as `Item`.

Recommended names:

- `ListeningItem`: original content and item-level metadata.
- `itemId`: item identifier.
- `text`: full clean text used for TTS and anchoring.
- `externalReference`: optional user-facing reference such as an Obsidian link or URL.
- `externalReferenceType`: `obsidian`, `url`, `plain`, or `none`.
- `ListeningMap`: optional AI-generated item structure.
- `Session`: one listening pass over an item.
- `Interjection`: a spoken note captured during a session.

## Prototype Scope

In scope:

- Local macOS desktop app.
- React/Vite/TypeScript web UI in a native shell.
- Pasted text items.
- Listening queue.
- Optional strict JSON Listening Map paste.
- Listening Map validation and repair reports.
- Chunked Apple-quality TTS.
- Watch-constrained playback surface.
- Chapter timeline when a map exists.
- Mapless playback when no map exists.
- Audio-first interjection recording.
- Async transcription when local transcription dependencies are available.
- Interjections displayed in the timeline.
- Basic Markdown and JSON session export.
- Home-only settings.

Out of scope:

- PDF ingestion.
- RSS ingestion.
- Obsidian sync.
- Apple Shortcuts ingestion.
- Share sheet.
- Web article extraction.
- AI API integration.
- Post-listening AI reflection.
- Final export preset system.
- Apple Watch app.
- Pre-generated item audio.
- Untranscribed audio-only ingestion.
- Live dictation.
- Transcript editing during capture.

## Architecture

Preferred prototype architecture:

- Tauri desktop app.
- React/Vite/TypeScript frontend.
- Native macOS speech via Apple speech tooling or APIs.
- App-local durable storage.
- Audio files stored on disk and referenced from session data.

The architectural rule is:

Web UI for fast iteration. Apple-native speech for listening quality.

## Core Objects

### ListeningItem

An item owns the content and optional item-level structure.

```json
{
  "id": "item-001",
  "title": "You Can't Inspect the Pill",
  "text": "Full pasted item text...",
  "externalReference": "[[You Can't Inspect the Pill]]",
  "externalReferenceType": "obsidian",
  "createdAt": "2026-06-11T12:00:00Z",
  "updatedAt": "2026-06-11T12:00:00Z",
  "status": "ready",
  "listeningMap": null,
  "resolvedChapters": [],
  "chunks": []
}
```

Valid item statuses:

- `needs_listening_map`: item has no valid Listening Map yet. Playback is still allowed.
- `ready`: item has enough content to play, and may have a valid Listening Map.
- `in_progress`: at least one session is active or recently active.
- `finished`: latest session reached the end.

The name `needs_listening_map` is historical and should not block playback. It means only that map-assisted navigation is unavailable.

### ListeningMap

A Listening Map is optional item-level structure created before listening.

It contains:

- brief overview
- claim roadmap
- chapter markers
- text anchors

The app computes chapter position from anchors. Model-provided percentages are optional compatibility metadata and should not be trusted as source of truth.

```json
{
  "schemaVersion": "listening-map.v1",
  "itemTitle": "string",
  "overview": "string",
  "claims": [
    {
      "id": "claim-1",
      "text": "string"
    }
  ],
  "chapters": [
    {
      "id": "ch-1",
      "title": "string",
      "description": "string",
      "anchor": "string"
    }
  ]
}
```

Compatibility:

- Accept legacy `sourceTitle`.
- Accept optional `percent`, but recompute it from the resolved anchor.
- Do not require `percent`.

### Chunk

A chunk is a local playback unit derived from item text.

```json
{
  "id": "item-001-chunk-18",
  "itemId": "item-001",
  "index": 18,
  "text": "Maybe their diet changed. Maybe their sleep changed.",
  "startChar": 4820,
  "endChar": 4910,
  "roughPercent": 27,
  "paragraphIndex": 9,
  "sentenceStartIndex": 31,
  "sentenceEndIndex": 32
}
```

Chunk IDs and indices are useful for local playback and debugging. They are not durable enough for chatbot handoff because external tools do not know the app's chunking algorithm. Exports should include surrounding text anchors for interjections.

### Session

A session is one listening pass over an item.

```json
{
  "id": "session-001",
  "itemId": "item-001",
  "createdAt": "2026-06-11T12:15:00Z",
  "updatedAt": "2026-06-11T12:45:00Z",
  "completedAt": null,
  "currentChunkIndex": 18,
  "completionPercent": 27,
  "status": "in_progress"
}
```

Valid session statuses:

- `in_progress`
- `finished`
- `abandoned`

The larger product model should treat sessions as first-class records, not incidental item fields. The current prototype may store sessions under an item for simplicity, but exports and future storage should preserve session identity.

### Interjection

An interjection is a spoken note made during a session.

```json
{
  "id": "ij-001",
  "itemId": "item-001",
  "sessionId": "session-001",
  "chapterId": "ch-003",
  "createdAt": "2026-06-11T12:17:00Z",
  "roughPercent": 27,
  "chunkIndex": 18,
  "anchorBefore": "Maybe their diet changed. Maybe their sleep changed.",
  "anchorAfter": "Maybe their symptoms were about to improve anyway.",
  "audioPath": "interjections/ij-001.m4a",
  "transcriptionStatus": "pending",
  "transcript": null,
  "status": "active"
}
```

Interjections belong to sessions. They also anchor back into item text.

When no chapter exists, `chapterId` is `null`. This is valid. The interjection remains useful because it includes surrounding item context through `anchorBefore` and `anchorAfter`.

Transcription statuses:

- `pending`
- `transcribed`
- `failed`

Interjection statuses:

- `active`
- `deleted`

## Chunking

Chunking controls playback, navigation, rollback, and interjection anchoring.

Rules:

1. Split item text into paragraphs.
2. Split paragraphs into sentences.
3. Assemble chunks from whole sentences.
4. Avoid mid-sentence splits.
5. Split mid-sentence only when a single sentence exceeds a hard maximum.

Settings:

- Chunk target: short, medium, long, paragraph-oriented.
- Back/forward unit: chunk, sentence, paragraph.
- Rollback after interjection: previous chunk, previous sentence, previous paragraph.

Defaults:

- Chunk target: medium.
- Back/forward unit: chunk.
- Rollback: previous chunk.

## Listening Map Validation

Hard failures:

- invalid JSON
- missing or unsupported `schemaVersion`
- missing `overview`
- no chapters
- chapter missing `id`
- duplicate chapter `id`
- chapter missing `title`
- chapter missing `description`
- chapter missing `anchor`
- anchor cannot be resolved

Warnings:

- no claim roadmap
- title longer than 32 characters
- description longer than 160 characters
- invalid optional `percent`
- uneven chapter spacing
- first chapter starts far after beginning
- final chapter starts very close to end

Matching process:

1. normalize whitespace
2. normalize curly quotes and apostrophes
3. try exact match
4. try case-insensitive match
5. try punctuation-light match
6. classify as `resolved`, `not_found`, or `duplicate`

Weak fuzzy matching can wait. In the prototype, weak matches should be treated as errors with useful repair text.

## Listening Map Prompt

The app should provide a prompt users can copy into a chatbot:

```text
Create a Listening Map for the item content below.
The user will listen to this content through text-to-speech. The interface may eventually be as small as an Apple Watch, so the map must support quick navigation and situational awareness.
Return only strict JSON. Do not include Markdown. Do not include commentary.
Use this schema:
{
  "schemaVersion": "listening-map.v1",
  "itemTitle": "string",
  "overview": "string",
  "claims": [
    {
      "id": "claim-1",
      "text": "string"
    }
  ],
  "chapters": [
    {
      "id": "ch-1",
      "title": "string",
      "description": "string",
      "anchor": "string"
    }
  ]
}
Requirements:
- The overview should be brief.
- Optimize the overview to reduce premature interjections the listener may regret after hearing later context.
- Include the argument's main trajectory, especially important caveats, concessions, reversals, or places where an apparent objection is answered later.
- Do not make the overview comprehensive; prefer the few warnings most likely to prevent wasteful interruptions during listening.
- Claims should describe the main claims, moves, or argument structure.
- Chapters should be useful for navigation, not literary analysis.
- Chapter titles should be short, ideally 2-5 words.
- Chapter descriptions should be one sentence.
- Anchor must be an exact phrase copied from the item text near the start of that chapter.
- Anchor should be long enough to be unique.
- Do not estimate or include percent. The app computes chapter position from the anchor.
- Prefer 5-12 chapters for medium-length content.
- Use more chapters if the content is long.
- Use fewer chapters if the content is short.
- Do not invent anchors.
- Do not summarize content that is not present.
ITEM CONTENT:
<<<
[PASTE ITEM CONTENT]
>>>
```

## Playback

The playback screen should be watch-constrained in spirit.

It should show:

- Home
- current chapter title when available, otherwise item title
- progress indicator
- Back, Play/Pause, Forward
- Interject
- timeline

It should not show the current item excerpt on the main playback screen.

Mapless playback behavior:

- Start playback from item chunks.
- Show item title where chapter title would normally appear.
- Timeline may contain interjections only.
- Interjections still capture anchors before and after the current location.
- Export should still produce useful session notes.

Home behavior:

- For the prototype, Home stops current speech and exits playback.

## Interjection Flow

When the user taps Interject:

1. Pause playback.
2. Start recording.
3. Capture current `sessionId`, `itemId`, `chunkIndex`, rough percent, current `chapterId` if any, `anchorBefore`, and `anchorAfter`.
4. Wait for Done or Cancel.

Done:

1. Stop recording.
2. Save audio.
3. Create interjection.
4. Resume from rollback point.
5. Run transcription asynchronously.

Cancel:

1. Stop recording.
2. Discard audio.
3. Resume from rollback point.

If transcription fails:

- Preserve audio.
- Mark transcription as failed.
- Show "Audio saved. Transcript failed."
- Keep the interjection exportable.

## Timeline

Timeline entries:

- chapters, when a Listening Map exists
- interjections, whether or not a Listening Map exists

Sort order:

1. rough percent
2. chapter before interjection at same percent
3. creation time for entries of the same type

Chapter row:

- percent
- title
- one-line description

Interjection row:

- percent
- status
- transcript preview when available, capped around 240 characters
- audio-only or failed-transcript state when unavailable

Actions:

- Tap chapter: jump to chapter chunk.
- Tap interjection: show detail with the full transcript, audio path, session id, and surrounding anchors.
- Delete transcript from detail: clear the transcript text while preserving the interjection and audio.
- Close detail: return to the timeline.
- Delete interjection: mark deleted.

Interjection detail can be basic in the prototype: transcript status, full transcript if present, audio path if saved, anchors before and after, session id, delete transcript, close, and delete interjection.

## Storage

All data is local.

Store:

- items
- Listening Maps
- resolved chapter anchors
- chunks
- sessions
- interjection metadata
- interjection audio files
- transcripts
- settings

Preferred long-term storage:

- SQLite, because the data is relational.

Acceptable prototype storage:

- app-local JSON files for item/session/settings metadata
- audio files stored separately in app data

Avoid relying only on browser `localStorage` for durable product data. `localStorage` can remain a development fallback and migration source.

## Export

The exported object is a session note. It references an item.

Export options:

- include full item text
- include external reference
- include Listening Map
- include interjections

If an item has an external reference, default to using it instead of full text.

Markdown export should remain useful without chapters:

```md
# Listening Session: You Can't Inspect the Pill
Item: [[You Can't Inspect the Pill]]

## Timeline

### 27% - Interjection
Anchor before:
"Maybe their diet changed. Maybe their sleep changed."
Anchor after:
"Maybe their symptoms were about to improve anyway."
Transcript:
"This list works, but it feels repetitive."
Audio:
interjections/ij-001.m4a
```

When chapters exist and Listening Map is included, interjections can appear near chapter rows, but they should not depend on chapter linkage to be exported.

JSON export:

```json
{
  "schemaVersion": "spoken-margins.export.v1",
  "item": {
    "id": "item-001",
    "title": "You Can't Inspect the Pill",
    "externalReference": "[[You Can't Inspect the Pill]]",
    "includedFullText": false
  },
  "session": {
    "id": "session-001",
    "status": "finished",
    "completionPercent": 100
  },
  "listeningMap": {
    "schemaVersion": "listening-map.v1"
  },
  "interjections": [
    {
      "id": "ij-001",
      "sessionId": "session-001",
      "roughPercent": 27,
      "chunkIndex": 18,
      "chapterTitle": null,
      "anchorBefore": "Maybe their diet changed. Maybe their sleep changed.",
      "anchorAfter": "Maybe their symptoms were about to improve anyway.",
      "transcriptionStatus": "transcribed",
      "transcript": "This list works, but it feels repetitive.",
      "audioPath": "interjections/ij-001.m4a"
    }
  ]
}
```

Chunk indices are allowed in JSON as local metadata, but anchors are the portable context for chatbot handoff.

## Error Handling

Errors should be constructive. They should explain:

- what failed
- where it failed
- why it failed
- what the user should do next
- what text can be pasted back into a chatbot when relevant

Important cases:

- malformed Listening Map JSON
- missing required map fields
- unresolved anchors
- duplicate anchors
- TTS failure
- transcription failure
- app-data persistence failure

TTS failure:

- pause playback
- show chunk index
- preserve session state
- allow the user to skip or resume

Transcription failure:

- preserve audio
- mark interjection as failed
- keep it visible and exportable

Persistence failure:

- keep in-memory state
- keep localStorage fallback if available
- tell the user app-data save failed

## Success Criteria

Primary:

- User can listen to pasted text without looking at the screen.
- User can listen without a Listening Map.
- User can add at least five interjections without losing playback context.
- User can navigate by chapter when a valid map exists.
- User can export a useful session note.

Secondary:

- Map validation catches bad AI output.
- Repair reports are useful enough to fix a map in the next chatbot turn.
- Apple TTS quality is good enough for long-form listening.
- Async transcription does not interrupt listening.
- Audio is preserved even when transcription fails.

## Roadmap

### Phase 1: Local Item And Playback Baseline

Build:

- app shell
- Home/listening queue
- create item from pasted text
- optional title
- optional external reference
- chunk item text
- Apple TTS chunk playback
- playback screen
- play/pause
- back/forward
- progress indicator
- Home navigation

Exit criteria:

- User can paste an item and listen through it with Apple TTS.
- Playback is chunked.
- Back/forward work.
- Progress is visible.

### Phase 2: Optional Listening Map And Chapter Navigation

Build:

- copyable Listening Map prompt
- paste map JSON
- validate schema
- validate anchors
- resolve chapters to chunks
- verbose repair errors
- chapter timeline
- current chapter display
- tap chapter to jump

Exit criteria:

- User can add a valid map when useful.
- User can ignore maps when they are not worth generating.
- Chapter navigation works when chapters exist.

### Phase 3: Interjection Capture

Build:

- Interject button
- pause playback
- record audio
- Done
- Cancel
- automatic resume from rollback point
- interjection metadata
- interjections in timeline
- delete interjection

Exit criteria:

- User can make five interjections during playback and continue listening without losing context.
- Interjections work with and without chapters.

### Phase 4: Async Transcription

Build:

- transcribe recorded interjection audio asynchronously
- pending/transcribed/failed states
- timeline update when transcript arrives
- local transcript storage

Exit criteria:

- Audio is preserved.
- Transcripts appear when local transcription succeeds.
- Failures do not interrupt listening.

### Phase 5: Basic Session Export

Build:

- Markdown export
- JSON export
- include/exclude full item text
- include/exclude external reference
- include/exclude Listening Map
- include/exclude interjections
- mapless interjection export
- session identity in export

Exit criteria:

- User can export a useful session note for a chatbot or note system.

### Phase 6: Model Configuration And Generation Controls

Goal:

Move AI-assisted work into the app while keeping the user in control.

Build:

- Local model provider settings.
- User API key storage in app-local secure storage when feasible.
- Provider type:
  - frontier lab hosted model
  - neocloud/OpenAI-compatible endpoint
  - self-hosted local or LAN endpoint
- Base URL for compatible providers.
- Model selection string.
- Optional separate models for:
  - Listening Map generation
  - interjection summarization
  - continued conversation
- Generation mode settings:
  - Listening Map: manual or automatic after item ingestion
  - interjection summary: manual by default, optional automatic after session completion
  - continued conversation: always manual submit

Exit criteria:

- User can configure an AI provider.
- User can manually generate a Listening Map in-app.
- Optional automatic Listening Map generation can run after item creation or bulk ingest.
- User can manually generate a session/interjection summary after listening.

### Phase 7: Session Continuation And Spoken Conversation

Goal:

Let the listening session continue after the original item ends.

Important model shift:

An item is the content. A session is the user's situated engagement with the item. After item playback ends, the session may continue into summaries, corrections, follow-up questions, and back-and-forth conversation.

New session phases:

- `item_playback`: user is listening to the original item.
- `interjection_summary`: model summarizes the user's interjections.
- `ai_response_playback`: user is listening to a generated model response.
- `user_followup_capture`: user is recording or editing a response to the model.
- `conversation`: user and model continue turns.
- `finished`: user ends the session.

New object:

```json
{
  "id": "turn-001",
  "sessionId": "session-001",
  "role": "assistant",
  "turnType": "interjection_summary",
  "createdAt": "2026-06-12T14:00:00Z",
  "text": "The user's interjections focused on...",
  "audioPlaybackStatus": "not_started",
  "sourceInterjectionIds": ["ij-001", "ij-002"]
}
```

Conversation turn roles:

- `user`
- `assistant`
- `system`

Turn types:

- `interjection_summary`
- `followup_question`
- `user_response`
- `assistant_response`
- `correction`
- `session_note`

The interjection pattern should continue during AI response playback:

1. App streams or plays model response with TTS.
2. User taps Interject.
3. AI response playback pauses.
4. User records spoken correction, clarification, or reaction.
5. Audio is saved and transcribed asynchronously.
6. Playback resumes from a rollback point in the AI response.
7. Before the next user submit, the app summarizes these response-level interjections into the conversation context.

Exit criteria:

- After item playback, user can generate a summary of interjections.
- User can listen to that summary.
- User can interject into the summary or later AI responses.
- User can submit a follow-up to continue the conversation.
- Session export includes item, original interjections, AI turns, response-level interjections, and follow-up turns.

### Phase 8: Streaming AI Response TTS

Goal:

Start speaking model responses before the full response has completed.

This is a major advantage over copying a finished chat response into system TTS.

Behavior:

- Stream model text into a response buffer.
- Segment the buffer into speakable units, preferably sentence or short paragraph boundaries.
- Start Apple TTS as soon as the first stable speakable unit is available.
- Continue queuing additional units as the model streams.
- Keep playback controls available:
  - pause
  - resume
  - back
  - forward
  - interject
  - stop
- If the model stream fails, preserve the partial response and mark the turn as interrupted.

Implementation notes:

- Do not speak unstable partial words.
- Prefer waiting for sentence punctuation or a short timeout after a clause boundary.
- Store the final response text exactly as received after the stream completes.
- Track spoken segment indices separately from original item chunks.
- Response-level anchors can be generated from the assistant response text the same way item interjections use anchors from item text.

Exit criteria:

- User hears the first part of a model response while the rest is still streaming.
- User can interject during streamed AI response playback.
- Partial response failures are recoverable and exportable.

### Phase 9: Bulk Ingestion

Goal:

Reduce friction for preparing a listening queue.

Desktop targets:

- Select multiple plain text or Markdown files from Finder.
- Drag-and-drop multiple files into the app.
- Create one item per file.
- Infer titles from filenames or first heading.
- Optional automatic Listening Map generation per item.

Mobile/iOS future targets:

- Select multiple files from Files.
- Share text into Spoken Margins.
- Add selected files to a listening queue.
- Start or sync sessions for phone/watch playback.

Accepted initial file types:

- `.txt`
- `.md`
- `.markdown`

Explicitly still out of scope:

- PDF parsing
- raw web scraping
- untranscribed audio-only files

Exit criteria:

- User can ingest multiple clean text files in one action.
- Items appear in queue with usable titles.
- Optional automatic map generation can run per item when enabled.

### Phase 10: Mobile And Watch-Controlled Sessions

Goal:

Make structured listening work while walking.

The desired mobile/watch loop:

1. User prepares items on desktop or phone.
2. User starts a session from phone or watch.
3. User listens through item or AI turn.
4. User navigates chapters/turns.
5. User taps Interject.
6. User taps Done.
7. Playback resumes.
8. Session continues across original item, summary, and conversation.

Phone lock screen or widget should prioritize:

- play/pause
- back/forward
- interject/done
- current item/session/turn title
- rough progress

Watch should prioritize:

- current chapter or current AI turn
- progress ring
- back
- play/pause
- forward
- interject/done
- compact timeline

Settings and complex editing should stay off-watch.

Exit criteria:

- User can run the core listening/interjection loop without opening the desktop app.
- Session state remains coherent across item playback, AI summary, and continued conversation.

## Larger Product Vector

The broader product is a local-first listening workspace for turning text and transcript-backed media into navigable, interruptible audio.

Do not collapse the three AI moments:

1. Before listening: AI structures the item.
2. During listening: the user captures situated reactions.
3. After listening: AI summarizes the user's engagement.

Future input routes:

- Obsidian note text
- Obsidian Web Clipper output
- share-sheet copied text
- Apple Shortcuts
- RSS item text
- multiple selected text/Markdown files from Finder or Files
- transcript-backed audio

Delayed or rejected inputs:

- PDFs
- raw web scraping
- untranscribed audio-only files

Audio source rule:

Audio can be supported only when there is a transcript. Chapter markers, interjections, and reflection need text anchors.

Future export destinations:

- Markdown
- Obsidian
- Apple Notes
- clipboard
- chatbot handoff

Future AI interaction surfaces:

- in-app Listening Map generation
- in-app interjection summary
- spoken follow-up questions
- continued back-and-forth conversation inside the session
- streaming TTS for AI responses before completion

Strategic risk areas:

- Speech API integration.
- Transcription reliability.
- Anchor reliability.
- Provider/API-key security.
- Streaming response segmentation.
- Session model drift between original item playback and follow-up conversation.
- Scope creep.
- Building Watch too early.

The vector worth protecting:

Structured audio navigation plus situated spoken margin notes.
