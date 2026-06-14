# Gate 1 Validation Checklist

Gate: Phone/Tablet Core Session
Build: TBD
Date: TBD
Devices: iPhone TBD, iPad TBD
Runtime profiles exercised: phone-tablet-online, phone-tablet-offline

## Verification Summary

- `SessionKitCoreTests`: must pass.
- `TraceReplayTests.testGate1TracesReplay`: must pass all Gate 1 traces.
- SQLite migration/persistence smoke test: must pass.
- Device microphone permission allowed and denied: TBD.
- Airplane mode provider deferral: TBD.
- Export reviewed for session isolation: TBD.

## Product Owner Flow

1. Install the build.
2. Reset all local data.
3. Load seeded fixtures.
4. Create or import a text item containing a long URL and a Markdown link.
5. Start playback and confirm URLs are not spoken while source text remains intact.
6. Jump between Listening Map chapters.
7. Skip back and forward repeatedly.
8. Record at least five interjections during source playback.
9. Confirm playback resumes with enough context after each interjection.
10. Generate an interjection summary.
11. Listen to the summary.
12. Interject into the summary.
13. Add an addendum or follow-up.
14. Continue discussion with AI.
15. Interject into the AI response.
16. Simulate provider failure or offline mode and confirm pending AI work is recoverable.
17. Export the session and confirm another session's notes do not leak in.

## Known Issues

- Installable Xcode project and signing are not yet generated in this repository.
- Real AVFoundation recording and microphone permission UI are represented by adapter boundaries and need device wiring before product-owner validation.
- Real OpenAI-compatible provider calls are represented by provider abstraction and deterministic test provider until app settings are wired.

Product-owner result:
- Pass
- Pass with issues
- Fail
