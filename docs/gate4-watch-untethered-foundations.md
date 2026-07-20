# Gate 4 Watch Untethered Foundations

## Purpose

Gate 4 should prove the Watch can be a prepared local listening runtime. It should not try to make WatchConnectivity behave like a reliable remote microphone for the phone.

The foundation should also be reusable for first-party audio such as podcasts. Once an audio source has a timestamped transcript, interjections should be anchored through the same timeline model whether the audio is:

- a podcast or imported audio track owned by the app
- pre-rendered TTS generated on phone, tablet, or laptop
- a prepared Watch package copied from another device

## Core Design Principle

Use a canonical media timeline, not a playback implementation timeline.

An interjection anchor should be expressed in source terms:

- `itemId`
- `sessionId`
- `watchPackageId` or future package id when applicable
- `audioAssetId`
- `mediaTimeMs`
- `playbackRateObserved`
- `chapterId`
- `transcriptSegmentId`
- optional transcript/source character span
- surrounding transcript text when available
- event `createdAt`

This is the common function for both first-party audio and pre-rendered audio. The resolver takes a source media time and returns the best transcript segment, chapter, and optional text span. Playback rate is observed metadata; it must not change the source anchor.

## Shared Timeline Resolver

The steward-owned runtime should expose a resolver with behavior equivalent to:

```text
resolveAnchor(mediaTimeMs, timeline) -> {
  chapterId,
  transcriptSegmentId,
  sourceTextRange?,
  anchorBefore,
  anchorAfter
}
```

Rules:

- Prefer an exact transcript segment where `startMs <= mediaTimeMs < endMs`.
- At segment boundaries, choose the segment whose spoken content is most likely being heard. A small tolerance window should be explicit and tested.
- Choose the last chapter whose `startMs <= mediaTimeMs`.
- Preserve `mediaTimeMs` even when transcript lookup fails.
- Preserve `playbackRateObserved` for diagnostics, never as the primary source position.
- Never store local buffer indexes, TTS chunk ids, or Watch UI row indexes as the only anchor.

For podcast/audio imports, the transcript comes from transcription with timestamps. For pre-rendered TTS, the transcript/timeline can come from the renderer. Both should feed the same resolver.

## Package Model

A prepared package should be a portable, immutable bundle:

- package manifest
- item metadata
- session metadata
- audio asset references and hashes
- transcript segments with timestamps
- chapter timings
- rollback/navigation settings
- renderer metadata
- package schema version

The existing `watch-audio-package.v1` fixture is a good minimum. Future versions should add renderer/device metadata and package integrity fields before multi-device sync.

## Package Library States

The Watch needs a package library before the playback screen. The library should distinguish:

- `loaded_on_watch`: playable now
- `queued_for_transfer`: phone will send package when reachable
- `available_for_transfer`: pre-rendered package exists elsewhere but is not on Watch
- `needs_prerender`: item exists but no package exists
- `rendering`: another device is producing the package
- `failed`: rendering or transfer failed
- `expired`: package exists but should be refreshed

Expected user behavior:

- Tapping `loaded_on_watch` opens local playback.
- Tapping `available_for_transfer` queues Watch transfer.
- Tapping `needs_prerender` queues a durable render-and-transfer request.
- Tapping `failed` shows a compact failure and retry action.

## Multi-Device Rendering

Laptop pre-rendering is a strong future direction. A laptop can run a higher-fidelity TTS model and write a package that phone and Watch only need to play.

Recommended split:

- Mac/laptop: high-fidelity rendering, package manifest creation, audio hash generation.
- iPhone/iPad: canonical session store, package transfer broker, watch sync import, transcription, cleanup, AI.
- Watch: local package playback, local recording, offline event queue.
- iCloud or CloudKit container: user-owned package manifest and asset sync between Mac, iPhone, and iPad.
- WatchConnectivity: explicit phone-mediated transfer to Watch.

Do not make the Watch depend on direct iCloud asset availability for the Gate 4 walking loop. Treat phone-to-Watch transfer as the reliable delivery path, even if the source package arrived on the phone through iCloud.

## Durable Request Events

Watch package requests should be durable, not ephemeral commands.

Useful request types:

- `prerender_requested`: user wants this item rendered for Watch.
- `watch_transfer_requested`: user wants an existing package copied to Watch.
- `package_delete_requested`: user wants local Watch storage freed.

These are different from transport commands such as play/pause/skip. Transport commands are only meaningful against the current live runtime. Package requests are syncable user intent.

The current `watch-sync-event.v1` schema does not include package request event types, so this is a steward backend/schema request.

## Watch Runtime Screens

Gate 4 should have at least two Watch screens:

1. Package library
2. Local package playback

The library screen should be optimized for scanning:

- title
- package status
- transfer/render status
- last listened progress where available
- storage indicator for loaded packages

The playback screen should keep the Gate 3 compact controls, but backed by local package state:

- current title/chapter
- source progress
- play/pause
- skip back/forward
- chapter list/jump
- interject
- recording finish/cancel

Summary and discussion should stay hidden while untethered because the Watch has no AI capability.

## Reconnect Import

Reconnect import should be idempotent by event id.

Import rules:

- Save the audio reference before transcription.
- Create an interjection with transcript/media anchor fields from the event.
- Keep package/session/item ids for diagnostics.
- Schedule phone/tablet transcription after audio is safely available.
- Do not let playback position events overwrite newer interjection records.
- Reject or quarantine events whose package/session ids do not match the canonical store.

## Failure Modes To Design For

- package present but audio asset missing
- package manifest hash mismatch
- user taps not-yet-rendered item while phone is unreachable
- package transfer interrupted
- Watch storage full
- microphone permission denied on Watch
- recording starts but audio save fails
- reconnect imports duplicate events
- phone has a newer session state than the Watch package
- transcript segment is missing for captured media time
- package was rendered from stale item text

Each failure should produce a status that can be shown in the package library and diagnostics. Silent fallback to tethered phone state would mask the failure and invalidate Gate 4.

## Acceptance Bar

Gate 4 is credible when:

- `python3 scripts/validate-contracts.py` passes.
- `python3 scripts/validate-surface-contracts.py` passes.
- A Gate 4 trace harness can replay `watch-offline-prerendered-session`.
- A steward-owned reconnect test can replay `watch-sync-interjections-after-reconnect`.
- Real-device evidence shows the Watch playing a local package and recording an interjection with the phone locked or absent.
- The imported phone interjection lands on the expected transcript segment and chapter.

