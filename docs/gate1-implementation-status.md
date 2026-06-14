# Gate 1 Implementation Status

## Completed In This Repository

- Added `Packages/SessionKit` as a Swift package with separate core, persistence, audio, and AI targets.
- Implemented deterministic `SessionKit` command/state behavior for the Gate 1 trace surface:
  source playback, TTS URL cleanup, semantic movement, rollback/resume, interjections, summary/discussion flow, AI response interjection, offline AI deferral, provider failure/retry, malformed AI text preservation, stable streaming speech, representation lifecycle separation, and session-scoped export.
- Added runtime capability gating for command availability and structured failure behavior.
- Added a SQLite-backed repository target with migrations and idempotent JSON record storage for items, sessions, interjections, turns, AI jobs, and Listening Maps.
- Added AVFoundation/AI provider adapter boundaries while keeping tests deterministic through mock clients.
- Added real AVFoundation speech playback and `.m4a` interjection recording adapters behind `SessionKitAudio` protocols, including explicit microphone permission prompting before interjection recording. The trace tests still use deterministic mocks.
- Added Gate 1 trace replay tests over the repository's actual trace and fixture files.
- Added a SwiftUI app shaped around the reference prototype's product flow: home/create/listening queue, item detail, active playback, discussion, OpenAI-compatible provider configuration, export, diagnostics, reset/seed, release notes, and known issues. Home and playback now use adaptive phone/tablet layouts.
- Added stable accessibility identifiers and an XCUITest smoke path for reset/seed feedback, seeded session start, playback navigation, export generation, and provider/API-key affordance.
- Added `project.yml` and generated `SpokenMarginsNative.xcodeproj` with an iOS app target linked against the local `SessionKit` package.
- Copied docs, schemas, fixtures, and traces into `Contracts/` as a native-app contract snapshot.
- Added `scripts/verify-gate1.sh` as the repeatable local verification entrypoint.
- Added `scripts/validate-contracts.py` for JSON Schema validation, trace fixture path checks, and trace capability/profile checks.

## Verification

Run:

```bash
./scripts/verify-gate1.sh
```

Current expected result:

- `SessionKitCoreTests`: 4 passing tests.
- `TraceReplayTests.testGate1TracesReplay`: replays 13 Gate 1 traces.
- Contract validation: all schemas, fixtures, traces, fixture references, and trace capability requirements pass.
- iOS simulator build: `SpokenMarginsApp` builds with local ad-hoc simulator signing.
- iOS simulator UI test: `Gate1FlowUITests.testSeededGate1FlowHasVisibleFeedbackPlaybackExportAndSettings` passes against iPhone and iPad simulators.
- iOS simulator smoke: app installs and launches on iOS 26.5 iPhone 17 and iPad Pro 13-inch (M5) simulators via `scripts/smoke-simulator.sh`.
- Current launch screenshots are written to `artifacts/gate1/iphone-launch.png` and `artifacts/gate1/ipad-launch.png`.
- The script uses `swift build --build-tests` plus `xcrun xctest` because this Xcode 26.5 SwiftPM environment builds the XCTest bundle but `swift test` reports no discovered tests.

## Not Yet Ready For Product-Owner Validation

- The app builds for iOS Simulator, but a signed installable iPhone/iPad build still requires local team/provisioning configuration.
- Bluetooth route validation, interruption recovery, Now Playing metadata, and remote commands still need device implementation and evidence. Microphone permission prompting and durable `.m4a` audio writing exist, but have not been validated on hardware.
- OpenAI-compatible settings UI now saves API keys in Keychain, probes `/models`, and uses `/chat/completions` for summary/follow-up generation in the app. It still needs real-device provider validation and richer structured-output handling.
- Real-device validation has not been run on iPhone/iPad with AirPods, airplane mode, app restart, and provider-unreachable cases.

## Packaging Note

Do not copy a top-level `Resources/` directory into the iOS app bundle. Simulator install reports `IXErrorDomain Code=13` / `Missing bundle ID` even when `CFBundleIdentifier` is present. Keep validation documents in the repo or copy individual resource files under non-reserved folders.

## Next Production Step

Implement audio route/interruption handling, Now Playing/remote commands, real provider-device validation, and iPhone/iPad hardware validation evidence while keeping `./scripts/verify-gate1.sh` green.
