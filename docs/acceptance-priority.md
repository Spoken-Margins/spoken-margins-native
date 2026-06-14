# Acceptance Priority

## Purpose

This document defines the order in which production development should buy down risk.

## Priority 0: Contracts Parse

Before native code:

- every JSON Schema parses
- every fixture parses
- every trace parses
- fixture paths in traces resolve
- every runtime capability profile fixture validates
- every trace declares a runtime profile and only requires capabilities that profile provides
- prototype lessons are classified as product contracts, abstract outcomes, or prototype-only details

## Priority 1: Offline Watch Package

First native milestone:

- activate `watch-untethered`
- load `fixtures/watch/offline-package.json`
- play local pre-rendered audio
- show current chapter
- jump to chapter
- record an interjection
- queue `interjection_recorded` sync event
- pass `traces/watch-offline-prerendered-session.json`

Why first:

This proves the most product-specific and least forgiving loop: watch, AirPods, no phone, no network, chapter-aware listening, and spoken interjection capture.

## Priority 2: Watch Reconnect Sync

Second milestone:

- activate `phone-tablet-online` or `phone-tablet-offline` with local import capability
- import watch sync events
- preserve audio before transcription
- create interjection records with transcript/media anchors
- update session position idempotently
- pass `traces/watch-sync-interjections-after-reconnect.json`

## Priority 3: Native Phone SessionKit

Third milestone:

- prove both `phone-tablet-online` and `phone-tablet-offline` command gating
- app-owned TTS playback
- mapless playback
- chapter navigation
- five interjections
- rollback/resume
- pass `traces/original-playback-five-interjections.json`
- pass `traces/semantic-navigation-and-rollback.json`
- pass `traces/tts-link-normalization.json`
- pass `traces/phone-offline-deferred-ai.json`
- pass `traces/watch-chapter-navigation.json`
- pass `traces/lock-screen-widget-controls.json`
- pass `traces/mapless-session-export.json`
- pass `traces/session-isolated-export.json`

## Priority 4: Summary And Discussion

Fourth milestone:

- prove summary and discussion are available online and deferred offline
- generate interjection summary through provider abstraction
- play summary
- interject into summary
- submit addendum/follow-up
- play AI response
- interject into AI response
- preserve assistant text when AI-generated structure is malformed
- recover failed provider work through retryable jobs
- preserve separate interjection audio/transcript/cleaned-text lifecycles
- pass `traces/interject-into-summary-then-discuss.json`
- pass `traces/scoped-interjection-summary.json`
- pass `traces/ai-response-interjection.json`
- pass `traces/ai-malformed-structure-preserves-text.json`
- pass `traces/ai-provider-failure-retry.json`
- pass `traces/stable-streaming-speech.json`
- pass `traces/interjection-representation-lifecycles.json`

## Priority 5: Browser Sessions

Fifth milestone:

- prove `browser-text` and `browser-media` are separate runtime profiles
- browser text creates text-backed item
- browser media creates transcript-backed media session
- sped-up media anchors to source media time
- pass `traces/browser-text-session.json`
- pass `traces/browser-video-1_75x-session.json`

## Priority 6: Listening Map Repair

Sixth milestone:

- tolerate common AI JSON wrappers
- preserve valid punctuation inside JSON strings
- diagnose unresolved and duplicate anchors
- keep invalid maps repairable without corrupting item/session state
- pass `traces/listening-map-ingestion-and-repair.json`

## Priority 7: Car Controls

Seventh milestone:

- prove `car-basic` exposes only transport remote commands
- basic car transport controls
- explicit configured interjection strategy
- safe boundary behavior
- pass `traces/car-basic-controls.json`

## Native Kickoff Done Criteria

The first implementation wave is ready for broader product work when priorities 0 through 2 pass in native tests and the watch app can perform one offline walk session end to end with fixture data.
