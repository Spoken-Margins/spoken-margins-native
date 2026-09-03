# Build 25 Implementation Handoff

Date: 2026-09-02

Status: `implemented` and automated evidence `verified`; not `human_validated`.

## Build and source

- Build: 25 (`0.1 (25)`)
- Branch: `codex/build-23-release`
- Starting commit: `6f61718`
- The Build 25 implementation is currently an uncommitted working-tree delta. Record the final commit SHA here before distribution or product-owner validation.

## Supported runtime

- iPhone and iPad, iOS 18 or later: fingerprint spine, phrase sketches, imported-map alignment, and imported summary text.
- iOS 26 with an available Apple Foundation Model: local scene labels and summaries are implemented.
- Skim requires a committed recipient projection, eligible summary text, and locally rendered recipient-voice bridge audio.
- No headphones, CarPlay, Now Playing, Watch, or ordinary time-skip remapping is in scope.

## In-scope flows

1. Memory-only decoded playback ring, exact pre-Margin evidence, seek-debounced post-resume evidence, and sparse playback landmarks.
2. Explicit or separately opted-in charging preparation of downloaded episodes, with resumable fingerprint units and a protected transient transcript checkpoint.
3. Private spine, phrase-sketch, scene-proposal, bridge, and recipient-projection persistence with storage reservations, eviction classes, and cleanup.
4. Non-blocking share preview/export and immediate provisional recipient playback followed by atomic future-position alignment.
5. App and Live Activity Skim Forward/Backward commands with bridge cancellation, source-origin restoration, and accessibility labels.

## Explicitly out of scope

- Server AI or server transcription.
- Public or reusable global episode-map catalogs.
- Contribution credits or crowdsourced publishing.
- Automatic advertisement classification.
- Export of full transcripts, decoded PCM, or rendered summary audio.
- External sharing before issue #14 is accepted.

## Verification

- Contract and surface validators: passed.
- SessionKit: 234 tests passed; the environment-gated held-out test is skipped in the ordinary suite and was run separately.
- Held-out cross-edition corpus: 232 anchors; acoustic and fused-monotonic paths each produced zero false-confident placements and 4 ms p95 error. Evidence: `artifacts/validation/sharing-next/podcast-anchor-benchmark-result.json`.
- Focused iOS simulator tests: three Skim/Shared-Margin/Live Activity tests passed.
- Generic iOS Simulator app build: passed.
- Generic iOS device app build with code signing disabled: passed.
- Simulator test-bundle build: passed.
- The documented `SpokenMarginsWatch` build command could not run because the generated Xcode project has no Watch scheme. Build 25 does not change Watch runtime code.

## Known issues and release stopping rules

- Physical-device playback, Shazam capture continuity, preparation latency, memory, thermal, battery, and audible-underrun profiling remain unverified.
- Local Foundation Model summary latency and grounding must pass the physical-device gate before local scene generation and generated Skim are released. If they fail, ship spine, sketches, imported-map alignment, and imported summaries without local AI scene generation or generated Skim.
- Playback, sharing, and Skim are not `human_validated`; only the product owner can change that state.
- A final commit SHA and signed build must be recorded before distribution.

## Reset and diagnostics

- Set **Automatic Episode Map Preparation** to **Off** to stop new charging-only jobs.
- Cancel the visible preparation job to purge its transient transcript and temporary audio. Deleting the episode removes its private map directory, jobs, projections, bridges, and evidence assets.
- For a complete clean-room retest, delete and reinstall the app, then download or import the test episode again.
- Export the app diagnostics for evidence outcomes and job status. Retain the held-out benchmark JSON above with the validation record.
- No new app-seeded podcast was added. Use a downloaded podcast with publisher chapters plus a `.spokenmargins` package made from a differently ad-inserted edition.

## Product-owner checklist

- [ ] Exact pre-Margin capture after at least 17 seconds of uninterrupted listening.
- [ ] Seek during post-resume capture discards the partial capture and restarts after five seek-free seconds.
- [ ] Sharing remains non-blocking and accurately reports map included versus still preparing.
- [ ] Recipient can start immediately at provisional positions; completed alignment affects future navigation without moving current playback.
- [ ] Repeated audio, removed passages, and changed-offset intervals remain approximate or unresolved instead of falsely verified.
- [ ] Skim Forward and Backward speak the expected summary, seek once, and restore prior play/pause state.
- [ ] Pause/resume controls the bridge; ordinary seek cancels it, restores the origin, and applies the requested transport.
- [ ] Interjection recording is unavailable during a bridge with an accessible explanation.
- [ ] Relaunch or unrecoverable interruption restores the source origin paused.
- [ ] Sparse capture causes no audible underruns, unacceptable battery drain, main-thread stalls, thermal regression, or unbounded memory growth.
- [ ] Product owner records pass/fail notes and, only after acceptance, marks applicable flows `human_validated`.
