# Native Kickoff Plan

## Purpose

This document defines the recommended first native production spike. The goal is not a full app. The goal is to prove the hardest runtime loop with architecture that can grow into production.

## Repository Strategy

Create a new clean repository for the native app, seeded only with:

- `docs/production-architecture.md`
- `docs/prototype-lessons.md`
- `docs/runtime-capability-model.md`
- `docs/sessionkit-contract.md`
- `docs/media-transcript-model.md`
- `docs/parity-test-plan.md`
- `docs/storage-and-migrations.md`
- `docs/native-kickoff-plan.md`
- `schemas/`
- `fixtures/`
- `traces/`

Keep the current Tauri repo as the prototype lab and behavioral reference. Do not plan a git merge from prototype to native. The production repo should achieve artifact parity, not source-code parity.

## Project Layout

Recommended initial native layout:

```text
SpokenMarginsNative/
  App/
    SpokenMarginsApp/
    SpokenMarginsWatch/
  Packages/
    SessionKit/
      Sources/
        SessionKit/
        SessionKitPersistence/
        SessionKitAudio/
        SessionKitAI/
      Tests/
        SessionKitTests/
        SessionKitTraceTests/
  Contracts/
    schemas/
    fixtures/
    traces/
```

## First Native Spike

Build the smallest native system that can replay `watch-offline-prerendered-session`.

Required capabilities:

- Activate `watch-untethered` runtime profile.
- Load a watch audio package fixture.
- Play local pre-rendered audio.
- Display current chapter and progress.
- Jump to a chapter.
- Begin interjection.
- Record audio to a local file.
- Finish interjection.
- Store anchor metadata with media time and transcript segment.
- Queue a watch sync event.
- Reject unsupported AI, transcription, map generation, and real-time TTS commands for this profile.

This spike can use mock audio playback in tests and real local audio playback in the app target.

## App Targets

### iPhone/iPad App

Initial responsibilities:

- import fixtures for development
- prepare watch package
- receive watch sync events
- transcribe imported watch interjections later
- inspect sessions and exports

### Watch App

Initial responsibilities:

- list downloaded packages
- play package audio
- show current chapter
- back/play-forward/interject controls
- scroll chapter list
- record interjection audio
- queue sync events while disconnected

## Package Boundaries

### SessionKit

Pure session state machine and command handling.

Must not import SwiftUI.

### SessionKitPersistence

SQLite storage, migrations, fixture loading, and sync event import.

### SessionKitAudio

AVFoundation playback, recording, and audio session adapters.

Tests should use mocks.

### SessionKitAI

Provider abstraction, OpenAI-compatible client, Apple Foundation provider adapter, and retryable AI jobs.

Not required for the first offline watch spike.

## Trace Test Harness

SessionKitTraceTests should:

1. Load a trace JSON file.
2. Load referenced fixtures.
3. Execute commands against a mock SessionKit engine.
4. Compare expected snapshot fragments.
5. Verify final persisted records.

The first required trace is:

- `traces/watch-offline-prerendered-session.json`

Next required traces:

- `traces/watch-sync-interjections-after-reconnect.json`
- `traces/mapless-session-export.json` under `phone-tablet-offline`
- `traces/phone-offline-deferred-ai.json`
- `traces/original-playback-five-interjections.json`
- `traces/semantic-navigation-and-rollback.json`
- `traces/tts-link-normalization.json`
- `traces/session-isolated-export.json`
- `traces/watch-chapter-navigation.json`
- `traces/lock-screen-widget-controls.json`

Discussion and AI resilience traces:

- `traces/scoped-interjection-summary.json`
- `traces/ai-malformed-structure-preserves-text.json`
- `traces/ai-provider-failure-retry.json`
- `traces/stable-streaming-speech.json`
- `traces/interjection-representation-lifecycles.json`

Map repair trace:

- `traces/listening-map-ingestion-and-repair.json`

## Definition Of Done For Kickoff

The native kickoff is successful when:

- the native repo builds
- SessionKit tests pass
- the first watch-offline trace passes
- a development watch app can load one prepared package
- local audio playback starts only after AVFoundation confirms it can play
- recording an interjection creates a durable audio file and queued sync event
- commands are gated by the active runtime capability profile
- no AI, transcription, or network is required
