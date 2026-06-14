# Spoken Margins Production Architecture

## Purpose

This document defines the production direction for Spoken Margins after the Tauri desktop/iOS prototype.

The prototype remains valuable as a product lab for interaction design, prompts, state shape, exports, and parity fixtures. It should not be treated as the production mobile runtime. The production app should be Apple-first, native where the product depends on system audio behavior, and contract-driven so future browser, Android, Windows, and desktop clients can interoperate.

Durable lessons from the prototype are classified in `docs/prototype-lessons.md`. Production work should preserve those product contracts and abstract outcomes while avoiding prototype-specific implementation constraints.

## Product Thesis

Spoken Margins is a structured listening workspace.

The durable product loop is:

1. Create or attach to an item with text or transcript-backed media.
2. Generate or provide a Listening Map.
3. Listen through controllable playback.
4. Navigate by chapter or coarse movement controls.
5. Capture spoken interjections anchored to the current text, transcript, media time, or AI turn.
6. Resume from a nearby rollback point.
7. Summarize interjections and continue discussion inside the session.
8. Export or revisit the session later.

Listening Maps are playback infrastructure, not optional decoration. They restore the spatial affordances missing from long linear audio and video.

## Target Architecture

### Apple-First Native App

The first production app should be a Swift/SwiftUI iPhone and iPad app. The iPad app may run on Mac as the initial Mac experience; a native Mac app is not required for v1.

Core platform frameworks:

- AVFoundation for audio session setup, speech synthesis, recording, and app-owned playback.
- MediaPlayer for Now Playing metadata and remote transport commands.
- WatchConnectivity plus a small watchOS app for watch controls and chapter navigation.
- WidgetKit, Live Activities, and AppIntents for lock screen and compact control surfaces.
- SQLite for durable local storage.

### SessionKit

SessionKit is a Swift package that owns the listening runtime. It should be UI-independent and testable through JSON behavior traces.

SessionKit owns:

- playback state
- current item, session, target, and position
- Listening Map navigation
- playback rate
- interjection recording lifecycle
- rollback and resume
- summary, addendum, and discussion phases
- remote command handling
- persistence events

All UI surfaces are SessionKit clients:

- iPhone app
- iPad/Mac app
- lock screen / Now Playing controls
- watch app
- CarPlay
- browser extension bridge

Every client must attach through a runtime capability profile, defined in `docs/runtime-capability-model.md` and represented by fixtures in `fixtures/capabilities/`. Device names are not enough. A phone/tablet can be online or offline; a watch can be tethered remote control or an untethered prepared runtime; a browser can own page text TTS, observe page-owned media, or delegate work back to the app.

SessionKit command availability is computed from the active profile. Unsupported commands are hidden by clients and rejected by SessionKit as `invalid_command_for_capability` if invoked anyway.

### Browser Extension

The browser extension is a session client with its own constrained runtime modes. It is not the canonical durable runtime unless a future standalone browser product explicitly adds canonical persistence.

It should support:

- creating text-backed items from selected text or readable page text
- attaching transcript-backed media sessions when a transcript is available
- anchoring interjections to media timestamps and transcript spans
- sending session packages to the app for later continuation
- offering a compact control surface similar to the lock screen/watch controls

For browser-owned media, anchors must use source media time and transcript spans. They must not use elapsed wall-clock time, because media may be played at 0.75x, 1.5x, 1.75x, 2x, or other rates.

For browser text, the extension may own text capture, TTS, and interjection recording when browser permissions allow. For browser media, the extension primarily observes or controls page-owned playback, captures media time and playback rate, and packages portable session events for handoff.

### AI Providers

AI integration should use a provider abstraction:

- `openai_compatible`
- `apple_foundation`

OpenAI-compatible providers are the primary path for Listening Maps and deeper discussion. A user may point the app at OpenAI, OpenRouter, Ollama, LM Studio, llama-server, or another compatible endpoint.

Apple Foundation Models are optional and should be used only for narrow private tasks where short context is enough:

- cleanup of noisy interjection transcripts
- cleanup of spoken addenda
- short summaries of interjections alone
- lightweight labels or titles

They should not be required for long Listening Maps or deep session discussion.

## Storage Direction

SQLite should be the production source of truth.

The schema should account for:

- multiple sessions per item
- text-backed items
- transcript-backed media
- Listening Maps and resolved chapters
- interjections targeting original items, media, summaries, and AI responses
- conversation turns inside sessions
- AI jobs and retry state
- exportable session records

The JSON Schemas in `schemas/` define the portable data contract. Swift, TypeScript, browser extension code, fixture generation, and parity tests should conform to these schemas.

## Interfaces

The product has two classes of interfaces:

- canonical runtimes that own playback, recording, persistence, and AI jobs when available
- constrained clients that display snapshots and send commands to a canonical or prepared runtime

The canonical phone/tablet app still has multiple modes. Online mode may call configured AI providers, generate maps, summarize interjections, continue discussion, and diagnose providers. Offline mode must still play local/prepared media, record interjections, preserve anchors, persist sessions, and queue deferred AI jobs. Offline mode must not pretend full AI service is available.

The browser extension also has multiple modes. Browser text mode can create text-backed sessions and may perform TTS/interjection capture in-browser. Browser media mode must deal with source media time, captions/transcripts, playback-rate observation, and page-owned playback.

The watch has two modes. Tethered watch is a remote command surface for the phone/tablet runtime. Untethered watch is a prepared local runtime for downloaded packages and records only audio plus anchors until sync.

### Compact Controls

Full controls:

- back
- play/pause
- forward
- interject
- finish/cancel interjection
- chapter list
- jump to chapter
- summarize
- discuss

Watch/widget controls:

- chapter or target identifier
- back
- play/pause
- forward
- interject
- finish/cancel while recording
- scrollable chapter list when screen space allows

Basic car controls:

- play/pause
- skip back
- skip forward

In basic car mode, interjection behavior must be explicit and user-configurable before driving. The recommended default is: long-press or configured external action starts interjection; play/pause finishes an active interjection.

CarPlay controls may expose chapter navigation, interject, finish interjection, and session actions.

The exact visible controls are constrained by the active runtime capability profile, not by the UI layout alone.

## Prototype Lessons To Preserve

Preserve as product contracts:

- Item, Session, Interjection, ListeningMap, ConversationTurn, and export concepts.
- TTS link cleanup without mutating source text.
- Portable anchors for text, transcript/media, and AI turns.
- Mapless playback, interjections, and export.
- AI summary and discussion split, including scoped summaries.
- Interjections against both source playback and AI responses.
- AI failure recoverability through retryable jobs.
- Assistant response text preservation when generated structure is malformed.
- Session-isolated exports.
- Browser media anchoring to source media time and playback-rate observation.
- Runtime capability honesty across phone/tablet, watch, browser, widget, and car modes.
- OpenAI-compatible provider settings and diagnostics.
- Pending AI task model.

Preserve abstractly:

- predictable semantic navigation
- natural TTS continuity
- configurable rollback that reorients the listener
- diagnostic Listening Map repair flow
- robust AI-formatted JSON ingestion
- stable streaming speech over completed units
- separate lifecycles for audio, transcript, cleaned text, and display text

Reject as production runtime patterns:

- WebView-managed audio recording.
- Polling-based remote controls as the primary system control mechanism.
- Browser localStorage as primary durable storage.
- Stale async updates that overwrite newer session state.
- Treating a laptop Gemma endpoint as a first-class product dependency.
- Claiming playback started before native audio actually starts.

## First Production Milestone

Before scaffolding the app, produce and review:

1. SessionKit contract.
2. Runtime capability model.
3. JSON Schemas.
4. Golden fixtures.
5. Behavior traces.
6. Parity test plan.
7. Offline watch package and sync contract.
8. Storage and migration plan.
9. Native kickoff acceptance priority.

The implementation goal for a native app becomes: implement SessionKit and pass the traces.
