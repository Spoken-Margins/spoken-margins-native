# Gate 4 Watch Untethered Closeout

Gate 4 now has an end-to-end app foundation for untethered Watch playback:

- iPhone publishes a package library over WatchConnectivity.
- Watch stores package manifests under Application Support and merges remote rows with loaded local packages.
- iPhone transfers package manifests, and transfers package audio assets when files matching manifest asset names exist locally.
- iPhone can render system-speech offline audio into a Watch package from an item detail screen or a Watch `prerender_requested` event.
- Watch runs a local `SessionEngine` with `PreparedAudioPlaybackClient` and `SystemRecordingClient`.
- Watch interjections are queued as `WatchSyncEvent` payloads and sent durably back to iPhone.
- iPhone persists package requests, stores returned Watch audio files, and imports sync events idempotently through `SessionEngine.importWatchSyncEvent`.

The fixture package still has a manifest and audio metadata but no `.m4a` bytes. It remains useful for contract validation. Real offline audio now comes from the phone-side system-speech renderer, which writes `.m4a` assets into `Application Support/SpokenMargins/watch-audio`, saves the matching `WatchAudioPackage`, and lets the existing broker transfer manifest plus audio to Watch.

## Offline Audio Rendering

The first concrete renderer uses Apple system speech:

- split item text by Listening Map chapters, falling back to sentence segments
- render each segment with `AVSpeechSynthesizer.write`
- measure exact segment durations from rendered audio files
- concatenate segments and export an `.m4a`
- create a `WatchAudioPackage` with cumulative media times, chapter timings, duration, and SHA-256

Kokoro or laptop rendering should reuse the same package writer and manifest shape after rendering segment audio. The Watch does not need to know which renderer produced the package.

## Package Manifest Handoff

The `WatchAudioPackage` manifest remains the stable handoff shape for future first-party rendering:

- laptop or phone rendering creates the manifest and audio assets
- iCloud can sync the manifest and assets across the user's larger devices
- the phone remains the Watch transfer broker for Gate 4
- Watch playback and interjection anchoring use the same media timeline model planned for first-party podcast transcript timestamps

## Remaining Future Work

Direct iCloud package discovery and high-fidelity laptop rendering are intentionally outside Gate 4 closeout. They should build on the existing manifest, request event, render segment, and package transfer model rather than introduce a second Watch-specific sync shape.
