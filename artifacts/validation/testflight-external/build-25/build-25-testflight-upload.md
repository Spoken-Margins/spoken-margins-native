# Build 25 internal TestFlight upload and product-owner handoff

Status: uploaded successfully, processed by App Store Connect, and available to the internal `Margins` group with six testers. It was not added to `External Beta` or submitted for Beta App Review.

## Candidate

- Authorization date: 2026-09-02
- Marketing version/build: 0.1 (25)
- Runtime source commit: `3294438ffba790fa281509bc1fa7b51e379a6c71`
- Branch: `codex/build-23-release`
- Team: `J8SWC6J3VY`
- Bundle: `com.spokenmargins.native`
- Supported devices: iPhone and iPad on iOS/iPadOS 18.0 or later
- Intended internal group: `Margins`
- App Store Connect build ID: `9ed3ce56-4aa9-4ff3-92fe-6f81d8e57671`

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
- Clean Release archive: pass; archived identity is version 0.1 (25), arm64, iOS 18.0 minimum.
- Archived app and all three embedded extensions passed strict signature verification.
- Non-uploading App Store Connect export: pass.
- Exported IPA SHA-256: `5e1fddae62f8b3b1892602e0f7b7e7810092e534785aecca5eafeaf7829ed6e0`.
- Exported app identity: Apple Distribution, Store provisioning, `beta-reports-active = true`, `get-task-allow = false`, and shared application group `group.com.spokenmargins.native`.
- Xcode package and SPI analysis: pass; upload completed with `Upload succeeded`.
- App Store Connect processing: complete for Build 25, created Sep 2, 2026 at 11:41 PM Central.
- Internal distribution: Build 25 is assigned to `Margins` as an Internal group with six testers.
- External distribution: Build 25 has no external group and was not submitted for Beta App Review.

Apple emitted the known non-blocking symbol-upload warning because the upstream `onnxruntime.framework` archive has no matching dSYM for UUID `EB36D931-A0CD-32E2-93E6-6B5B31DCFE36`. Application upload and processing succeeded; crashes inside that framework may have limited symbolication.

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
