# Gate 2 Validation Checklist

Gate: Lock Screen And Widget
Build: a020165 + working tree Gate 2 compact-control updates
Date: 2026-06-15
Devices: iPhone 17 simulator; signed physical iPhone TBD
Runtime profiles exercised: phone-tablet-online, lock-screen-widget

## Verification Summary

- `python3 scripts/validate-contracts.py`: passed.
- `TraceReplayTests.testGate2TracesReplay`: passed `lock-screen-widget-controls`.
- `SessionKitCoreTests`: passed compact-control delegation and capability-honesty tests.
- `Gate2CompactControlTests`: passed app-level compact snapshot and transport delegation tests.
- `Gate1FlowUITests.testGate2CompactValidationControlsDelegateTransportCommands`: passed on iPhone 17 simulator through `PHONE_UDID=25E18745-102A-4C08-9382-E1068F348359 ./scripts/verify-gate2.sh`.
- iOS app plus `SpokenMarginsGate2Widget` extension simulator build: passed.
- Signed real-device install: TBD.
- Now Playing Lock Screen item/chapter/playback display: TBD.
- Now Playing pause/resume/skip back/skip forward while locked: required for both native media and immediate live-speech playback.
- Live Activity item/chapter/status/progress display: TBD.
- Live Activity pause/resume/skip back/skip forward buttons enqueue commands without opening the app: TBD.
- Live Activity interjection mic opens the app and starts interjection recording: TBD.
- Live Activity summary/discuss buttons enqueue app-level handoff commands without opening the app while the app process can drain the shared queue: TBD.
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
7. Pause and resume from the Lock Screen or Live Activity.
8. Skip back and forward from the Lock Screen or Live Activity.
9. Confirm the Live Activity shows the same item, chapter/target, status, recording state, and progress.
10. Tap pause/resume, skip back, and skip forward from the Live Activity, then confirm playback changes without first opening the app.
11. Tap the Live Activity mic and confirm the app opens directly into recording without requiring a second Interject tap.
12. Finish the interjection and confirm the note is attached to the correct session/anchor after unlock.
13. Tap Summary and Discuss from the Live Activity and confirm the app receives the requested handoff when it can drain the shared command queue.
14. Confirm source playback resumes with rollback context after normal in-app interjection.
15. Deny microphone permission and confirm compact interjection is rejected honestly in the app.
16. Repeat with AirPods connected and during an audio interruption.

## Known Issues

- Live Activity command buttons use `LiveActivityIntent`/`AudioPlaybackIntent` plus the shared App Group command queue. A real-device pass still needs to prove that the background audio process drains commands quickly while the phone is locked.
- Native media and immediate live speech have separate Now Playing owners. The device pass must prove that switching routes does not duplicate commands or replace the active owner's handlers; an automated build cannot establish this.
- Real Lock Screen, Live Activity, background audio, route-change, and microphone-permission evidence requires a signed physical-device pass.

Product-owner result:
- Pass
- Pass with issues
- Fail
