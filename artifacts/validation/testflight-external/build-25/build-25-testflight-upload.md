# Build 25 internal TestFlight upload and product-owner handoff

Status: authorized for internal-only upload to the existing `Margins` group after the signed archive gate passes. App Store Connect upload, processing, and assignment results are pending.

## Candidate

- Authorization date: 2026-09-02
- Marketing version/build: 0.1 (25)
- Runtime source commit: `3294438ffba790fa281509bc1fa7b51e379a6c71`
- Branch: `codex/build-23-release`
- Team: `J8SWC6J3VY`
- Bundle: `com.spokenmargins.native`
- Supported devices: iPhone and iPad on iOS/iPadOS 18.0 or later
- Intended internal group: `Margins`

## Release scope and boundaries

Build 25 adds redundant private podcast anchoring, episode fingerprint spines, privacy-reduced transcript phrase sketches, recipient-edition alignment, resumable private map preparation, supported-device scene generation, and bounded app/Live Activity Skim controls. Full transcripts, decoded PCM, and sender-rendered bridge audio do not enter shared packages.

The product owner has `human_validated` the bounded streamed-podcast sender share and recipient import/alignment/listening flow. Overnight preparation, resource profiling, local scene generation, and Skim remain pending internal testing. Server AI, public episode catalogs, contribution credits, automatic ad classification, external TestFlight distribution, and Beta App Review are out of scope.

## Verification and upload evidence

- Contract and surface validators: pass.
- SessionKit: 234 passed, 1 expected environment-gated skip, 0 failed.
- Dedicated held-out cross-edition benchmark: 232 anchors; acoustic and fused-monotonic paths each had zero false-confident placements and 4 ms p95 verified-placement error. The timestamp-only falsification baseline had 188 false-confident placements and 65-second p95 error.
- Focused recipient transcript privacy, shared-Margin alignment, and Skim readiness simulator tests: 3 passed, 0 failed.
- Generic iOS Simulator app build: pass.
- Generic signed iOS device app build: pass.
- Release archive, export identity, IPA hash, upload, processing, and internal assignment: pending.

## Known issues and stopping rules

- [Issue #97](https://github.com/uncomposed/spoken-margins-native/issues/97) tracks startup/Add interaction chug and animation stalls. The reported add/interjection/anchor operation completed successfully.
- The validated session emitted nonfatal `AudioFileObject` open failures with error 1685348671. Correlate these events with the performance trace; stop if they cause missing voice audio, missing source audio, or an unresolved anchor regression.
- Physical-device sparse-capture underrun, battery, memory, thermal, and local Foundation Model latency/grounding gates remain pending. If local scene generation fails those gates, retain spine/sketch/imported-map alignment and disable local scene/Skim generation; do not add a server fallback.
- Stop rollout if signing/export validation fails, App Store Connect rejects the binary, Build 25 is assigned externally, or a verified placement becomes false-confident.

## Reset, samples, and diagnostics

- Upgrade first without resetting. Existing library items, prepared media, private Margins, and imported Shared Margins should remain.
- Clean reset: delete the TestFlight app and reinstall Build 25. Where available, Settings > Developer > Developer tools > Reset Library and Load Sample performs an intentional full reset.
- Seeded sample: **Welcome to Spoken Margins**.
- Product-owner podcast sample: **Ajeya Cotra – Inside the OpenAI agent swarm that hacked Hugging Face** ([Apple Podcasts](https://podcasts.apple.com/us/podcast/dwarkesh-podcast/id1516093381?i=1000787211003)).
- Diagnostics: Settings > Copy Privacy-Safe Diagnostics. Export diagnostics after any unmatched placement, preparation failure, Skim interruption, audible underrun, or Add interaction hitch.

## Internal product-owner checklist

- [x] Stream/interject/share/import the example episode and confirm the recipient reconstructs and can listen.
- [x] Confirm provisional unmatched placement can transition to matched after background alignment.
- [ ] Confirm pressing Play before alignment finishes does not move playback already in progress and later navigation adopts the completed projection.
- [ ] Exercise Automatic Episode Map Preparation while charging on previously downloaded, unplayed episodes.
- [ ] Confirm preparation resumes after relaunch and deletes transient transcripts after commit/cancellation.
- [ ] Exercise Skim Forward/Backward, bridge pause/resume, cancellation, and final-scene completion on a supported iOS 26 device.
- [ ] Observe battery, thermal state, memory, playback continuity, and animation responsiveness during sparse capture and preparation.
- [ ] Reproduce or falsify issue #97 with a trace and correlate any `AudioFileObject` errors.

Product-owner result: PASS for sender sharing and recipient import/alignment/listening. Remaining internal checklist items are pending.
