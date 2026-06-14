# Gate 1 Implementation Status

## Completed In This Repository

- Added `Packages/SessionKit` as a Swift package with separate core, persistence, audio, and AI targets.
- Implemented deterministic `SessionKit` command/state behavior for the Gate 1 trace surface:
  source playback, TTS URL cleanup, semantic movement, rollback/resume, interjections, summary/discussion flow, AI response interjection, offline AI deferral, provider failure/retry, malformed AI text preservation, stable streaming speech, representation lifecycle separation, and session-scoped export.
- Added runtime capability gating for command availability and structured failure behavior.
- Added a SQLite-backed repository target with migrations and idempotent JSON record storage for items, sessions, interjections, turns, AI jobs, and Listening Maps.
- Added AVFoundation/AI provider adapter boundaries while keeping tests deterministic through mock clients.
- Added Gate 1 trace replay tests over the repository's actual trace and fixture files.
- Added a SwiftUI app source scaffold for library/import, session controls, discussion, export, diagnostics, reset/seed, release notes, and known issues.
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

- `SessionKitCoreTests`: 3 passing tests.
- `TraceReplayTests.testGate1TracesReplay`: replays 13 Gate 1 traces.
- Contract validation: all schemas, fixtures, traces, fixture references, and trace capability requirements pass.
- iOS simulator build: `SpokenMarginsApp` builds with local ad-hoc simulator signing.
- iOS simulator smoke: app installs and launches on an iOS 26.5 iPhone 17 simulator via `scripts/smoke-simulator.sh`.
- The script uses `swift build --build-tests` plus `xcrun xctest` because this Xcode 26.5 SwiftPM environment builds the XCTest bundle but `swift test` reports no discovered tests.

## Not Yet Ready For Product-Owner Validation

- The app builds for iOS Simulator, but a signed installable iPhone/iPad build still requires local team/provisioning configuration.
- Real microphone permission handling, durable audio file writing, AVAudioSession category/route/interruption handling, Now Playing metadata, and remote commands still need device implementation.
- OpenAI-compatible settings UI, secure API-key storage, and real network provider execution are adapter boundaries only.
- Real-device validation has not been run on iPhone/iPad with AirPods, airplane mode, app restart, and provider-unreachable cases.

## Packaging Note

Do not copy a top-level `Resources/` directory into the iOS app bundle. Simulator install reports `IXErrorDomain Code=13` / `Missing bundle ID` even when `CFBundleIdentifier` is present. Keep validation documents in the repo or copy individual resource files under non-reserved folders.

## Next Production Step

Wire the app to `SQLiteSessionStore`, implement device audio/recording permissions, and keep `./scripts/verify-gate1.sh` green while adding UI tests and device validation evidence.
