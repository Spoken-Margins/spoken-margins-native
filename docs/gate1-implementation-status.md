# Gate 1 Implementation Status

> Historical evidence: this document records the earlier Gate 1 state. References to Kokoro/MLX describe retired experimental code and do not describe an available runtime after Build 22.

## Completed In This Repository

- Added `Packages/SessionKit` as a Swift package with separate core, persistence, audio, and AI targets.
- Implemented deterministic `SessionKit` command/state behavior for the Gate 1 trace surface:
  source playback, TTS URL cleanup, semantic movement, rollback/resume, interjections, summary/discussion flow, AI response interjection, offline AI deferral, provider failure/retry, malformed AI text preservation, stable streaming speech, representation lifecycle separation, and session-scoped export.
- Restored prototype-parity playback semantics for Gate 1: Listening Map overview prefaces source playback, assistant summaries are spoken before full responses, generated turns are queued until active audio completes, source/overview/generated turns are visible in the primary timeline, and AI turns/AI-turn chapters are playable from that surface.
- Stabilized repeated validation runs by creating unique sessions for repeated starts and unique assistant response turns/jobs for repeated follow-ups.
- Added runtime capability gating for command availability and structured failure behavior.
- Added a SQLite-backed repository target with migrations and idempotent JSON record storage for items, sessions, interjections, turns, AI jobs, and Listening Maps.
- Added AVFoundation/AI provider adapter boundaries while keeping tests deterministic through mock clients.
- Added bundled Supertonic 3 INT8 playback through the official Swift/ONNX Runtime path, with reusable sessions, two-chunk startup, continuous full-item rendering, completed/total chunk progress and delayed-chunk signaling, durable generated audio and transcript timing, a user stop action that continues through system speech, and James (M2) as the default. Normal render gaps wait for Supertonic instead of changing voices; AVFoundation system speech remains selectable and is reserved as the automatic route for genuine render or playback failure. Completed Supertonic audio is promoted to transcript-backed media for podcast-style restart, seek, system-control behavior, and tappable generated chapter rows in the Timeline. Synthesis remains fixed at model speed while pitch-preserving AVPlayer transport applies the listener's rate without rerendering.
- Unified live TTS, streamed assistant speech, compact controls, and Lock Screen commands on one routed audio client. The route owns remote-command registration exclusively, and publishes separate interpolated presentation and conservative recovery anchors so future transport surfaces can share one source of truth.
- Preserved the separate `SpokenMarginsAppDevice` scheme as legacy Kokoro/MLX experimental code; it is not exposed in the production voice catalog.
- Added Gate 1 trace replay tests over the repository's actual trace and fixture files.
- Added a SwiftUI app shaped around the reference prototype's product flow: home/create/listening queue, item detail, active playback, discussion, OpenAI-compatible provider configuration, export, diagnostics, reset/seed, release notes, and known issues. Home and playback now use adaptive phone/tablet layouts.
- Added stable accessibility identifiers and XCUITest paths for reset/seed feedback, seeded session start, playback navigation, export generation, provider/API-key affordance, and manual Listening Map JSON application.
- Added `project.yml` and generated `SpokenMarginsNative.xcodeproj` with an iOS app target linked against the local `SessionKit` package.
- Copied docs, schemas, fixtures, and traces into `Contracts/` as a native-app contract snapshot.
- Added `scripts/verify-gate1.sh` as the repeatable local verification entrypoint.
- Added `scripts/validate-contracts.py` for JSON Schema validation, trace fixture path checks, and trace capability/profile checks.

## Verification

For routine development verification, run:

```bash
./scripts/verify-gate1-routine.sh
```

For late-gate/pre-validation closeout evidence, run:

```bash
./scripts/verify-gate1-closeout.sh
```

Current expected result:

- Routine verification: contract validation, surface-contract validation, and the SessionKit package test bundle pass via `scripts/verify-gate1-routine.sh`.
- SessionKit trace replay remains package-level evidence; `TraceReplayTests.testGate1TracesReplay` replays the Gate 1 traces.
- App integration verification: regenerate the project, build `SpokenMarginsApp`, and run `SpokenMarginsAppTests` before claiming app-level behavior is verified.
- Closeout verification: run the full `Gate1FlowUITests` routes on iPhone and iPad simulators before asking the product owner to close Gate 1.
- Simulator smoke evidence and launch screenshots belong in closeout evidence, not the routine development loop.
- The SessionKit test runner uses `swift build --build-tests` plus dynamic XCTest bundle discovery because this Xcode 26.5 SwiftPM environment builds the XCTest bundle but `swift test` reports no discovered tests.

## Not Yet Ready For Product-Owner Validation

- The app builds for iOS Simulator from regenerated `project.yml`, but a signed installable iPhone/iPad build still requires local team/provisioning configuration.
- Bluetooth route validation and interruption recovery still need device evidence. Microphone permission prompting and durable `.m4a` audio writing exist; Speech transcription may be accepted with attached user/device evidence for Gate 1.
- OpenAI-compatible settings UI now saves API keys in Keychain, probes `/models`, and uses `/chat/completions` for Listening Map, summary, and follow-up generation in the app. It still needs real-device provider validation and richer structured-output evidence.
- Supertonic renderer correctness, session reuse, fixed-synthesis/variable-transport rate behavior, pending-render pause, media-services reset recovery, command ownership, and source-anchor propagation are simulator verified. Cold/warm latency, sustained real-time factor, memory, thermal, background narration, physical Lock Screen behavior, interruption routing, and listening quality still require the product-owner physical-device pass.
- Real-device validation has not been run on iPhone/iPad with AirPods, airplane mode, app restart, and provider-unreachable cases.

## Packaging Note

Do not copy a top-level `Resources/` directory into the iOS app bundle. Simulator install reports `IXErrorDomain Code=13` / `Missing bundle ID` even when `CFBundleIdentifier` is present. Keep validation documents in the repo or copy individual resource files under non-reserved folders.

## Next Production Step

Add Gate 1 validation evidence for microphone/Speech transcription, Supertonic and system-fallback playback, provider success/failure, offline deferral, export isolation, and audio route/interruption behavior while keeping routine verification green. Run closeout UI routes before asking the product owner to close the gate.
