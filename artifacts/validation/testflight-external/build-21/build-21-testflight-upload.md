# Build 21 TestFlight Upload And Product-Owner Handoff

Status: uploaded successfully and processing in App Store Connect; not yet confirmed in an internal group, submitted for Beta App Review, or `human_validated`.

## Candidate

- Upload date: 2026-08-27
- Marketing version/build: 0.1 (21)
- Source commit: `6a96b870715963bf2055e36efdb0dfb93b134067`
- Accepted runtime through: `22788cb96a6763d186a607961ee229c5b01d6156`
- Team: `J8SWC6J3VY`
- Bundle: `com.spokenmargins.native`
- Supported devices: iPhone and iPad on iOS/iPadOS 18.0 or later

## In scope

- Playback starts only after the selected route actually starts.
- Spotify numbered-episode resolution and canonical PDF headings/duration.
- Durable playback position across startup and seeks.
- Playback-rate controls and truthful waiting/transport presentation.
- Audio-interruption recovery without losing canonical playback state.
- Direct-manipulation scrubbing and cancellation of stale generated-speech renders.
- Existing recording/interjection continuity, library, import, export, and playback regression smoke.

## Out of scope

- Sharing package sender/recipient UI, imported commentary cueing/playback, and co-op replies.
- The Build 22 quality-of-life feature set: prepared-audio lifecycle, storage ledger, EPUB/audiobook import, followed sources, onboarding changes, library search/filter/sort, and sleep timers.
- The proposed visual/interaction overhaul.
- New Watch playback, recording, transfer, rendering, or synchronization behavior.

## Verification and upload evidence

- Contract validator: pass.
- Surface-contract validator: pass.
- SessionKit test build: pass.
- Generic iOS device build: pass.
- Release archive: pass.
- Archived identity: version 0.1 (21), arm64, iOS 18.0 minimum.
- App and embedded `onnxruntime.framework` strict signature verification: pass.
- Xcode upload: `Upload succeeded`; uploaded package entered App Store Connect processing.

The known upstream `onnxruntime.framework` dSYM warning remains: UUID `3B3AEB41-DBE1-313C-BB3B-88FAF0A9E45E` has no matching dSYM in the archive. The application upload and export succeeded; crashes inside that framework may have limited symbolication.

## Reset, sample data, and diagnostics

- Clean reset: delete the TestFlight app and reinstall Build 21. For an in-app reset, use Settings > Storage & Testing > Reset Library and Load Sample when that route is present.
- Seeded sample: the bundled Welcome to Spoken Margins item.
- Diagnostics: Settings > Diagnostics > Refresh Diagnostics, then Copy Privacy-Safe Diagnostics.

## Product-owner checklist

Record PASS or FAIL plus device, OS, and brief notes. Only the product owner can mark these flows `human_validated`.

- [ ] Clean-install Build 21 from TestFlight; launch and play the seeded sample.
- [ ] Start, pause, resume, seek, change rate, background, foreground, and use Lock Screen/AirPods controls; confirm one canonical position and state.
- [ ] Drag the scrubber repeatedly while playback updates; confirm the thumb never fights the gesture and the accepted target resumes correctly.
- [ ] Interrupt playback with another audio app/call route; return and confirm position, rate, and transport state are preserved.
- [ ] During generated speech, seek or replace playback and confirm stale rendered audio never begins later.
- [ ] Record and finish multiple interjections; confirm recording continuity and one contextual resume after each.
- [ ] Import a numbered Spotify podcast link and confirm the intended episode resolves.
- [ ] Import a structured PDF and confirm headings, duration, chapter navigation, and resume behavior.
- [ ] Run a short library/import/export regression smoke and export privacy-safe diagnostics after any failure.

Product-owner result: Pending.

Product-owner notes: Pending.
