# Gate 2 Validation Checklist

Gate: Lock Screen And Widget
Build: TBD
Date: TBD
Devices: iPhone TBD
Runtime profiles exercised: phone-tablet-online, lock-screen-widget

## Verification Summary

- `python3 scripts/validate-contracts.py`: must pass.
- `TraceReplayTests.testGate2TracesReplay`: must pass `lock-screen-widget-controls`.
- `SessionKitCoreTests`: must pass compact-control delegation and capability-honesty tests.
- `Gate2CompactControlTests`: must pass app-level compact snapshot and transport delegation tests.
- `Gate1FlowUITests.testGate2CompactValidationControlsDelegateTransportCommands`: must pass on an iPhone simulator through `./scripts/verify-gate2.sh`.
- iOS app plus `SpokenMarginsGate2Widget` extension simulator build: must pass.
- Signed real-device install: TBD.
- Now Playing Lock Screen item/chapter/playback display: TBD.
- Now Playing pause/resume/skip back/skip forward while locked: TBD.
- Live Activity item/chapter/status/progress display: TBD.
- Live Activity pause/resume/skip back/skip forward buttons enqueue commands without opening the app: TBD.
- App Group entitlement is present in both app and widget provisioning profiles: TBD.
- Begin/finish compact interjection with correct session/anchor visible after unlock: TBD.
- Background audio continuity while locked and after interjection rollback: TBD.
- Microphone-denied compact interjection failure is understandable and recoverable: TBD.
- AirPods route change and audio interruption recovery: TBD.

## Product Owner Flow

1. Install the signed build on iPhone.
2. Reset all local data.
3. Load seeded fixtures.
4. Start the seeded phone/tablet session.
5. Lock the device.
6. Confirm Now Playing shows the item title, chapter/target, playback state, and progress.
7. Pause and resume from the Lock Screen or Control Center.
8. Skip back and forward from the Lock Screen or Control Center.
9. Confirm the Live Activity shows the same item, chapter/target, status, recording state, and progress.
10. Tap pause/resume, skip back, and skip forward from the Live Activity, then confirm playback changes without first opening the app.
11. Unlock the phone and confirm the active app session is still attached to the correct session and nearby anchor after Control Center and Live Activity transport commands.
12. Confirm source playback resumes with rollback context after normal in-app interjection.
13. Deny microphone permission and confirm compact interjection is rejected honestly in the app.
14. Repeat with AirPods connected and during an audio interruption.

## Known Issues

- Live Activity command buttons use `LiveActivityIntent`/`AudioPlaybackIntent` plus the shared App Group command queue. A real-device pass still needs to prove that the background audio process drains commands quickly while the phone is locked.
- Real Lock Screen, Live Activity, background audio, route-change, and microphone-permission evidence requires a signed physical-device pass.

Product-owner result:
- Pass
- Pass with issues
- Fail
