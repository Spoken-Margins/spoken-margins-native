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
- Live Activity opens the canonical app runtime for custom delegated commands: TBD.
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
10. Begin an interjection from the compact surface and confirm the app records through the canonical phone runtime.
11. Finish the interjection from the compact surface.
12. Unlock the phone and confirm the note is attached to the correct session and nearby anchor.
13. Confirm source playback resumes with rollback context.
14. Deny microphone permission and confirm compact interjection is rejected honestly.
15. Repeat with AirPods connected and during an audio interruption.

## Known Issues

- Custom Live Activity buttons currently open the app for canonical handling; the widget extension does not own playback, recording, persistence, or AI.
- Real Lock Screen, Live Activity, background audio, route-change, and microphone-permission evidence requires a signed physical-device pass.

Product-owner result:
- Pass
- Pass with issues
- Fail
