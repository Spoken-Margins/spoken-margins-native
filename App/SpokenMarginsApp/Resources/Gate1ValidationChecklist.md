# Gate 1 Validation Checklist

Gate: Phone/Tablet Core Session
Build: TBD
Date: TBD
Devices: iPhone TBD, iPad TBD
Runtime profiles exercised: phone-tablet-online, phone-tablet-offline

## Verification Summary

- `SessionKitCoreTests`: must pass.
- `TraceReplayTests.testGate1TracesReplay`: must pass all Gate 1 traces.
- `Gate1FlowUITests`: must pass on iPhone and iPad simulators through `./scripts/verify-gate1.sh`.
- SQLite migration/persistence smoke test: must pass.
- Device microphone permission allowed and denied: TBD.
- System TTS overview preface before source playback: TBD.
- Prepared source summary auto-plays only after item audio completion: TBD.
- AI-turn interjection summary does not interrupt current AI response playback: TBD.
- Primary timeline AI turn and AI chapter rows are tappable: TBD.
- Airplane mode provider deferral: TBD.
- System speech playback for source, summary, and AI response: TBD.
- Export reviewed for session isolation: TBD.

## Product Owner Flow

1. Install the build.
2. Reset all local data.
3. Load seeded fixtures.
4. Create or import a text item containing a long URL and a Markdown link.
5. Start playback and confirm URLs are not spoken while source text remains intact.
6. Confirm the Listening Map overview is spoken before the article body begins.
7. Jump between Listening Map chapters.
8. Skip back and forward repeatedly.
9. Record at least five interjections during source playback.
10. Confirm playback resumes with enough context after each interjection.
11. Generate an interjection summary while source audio is still playing and confirm it waits until item audio completes.
12. Listen to the summary from the primary timeline.
13. Interject into the summary.
14. Add an addendum or follow-up.
15. Continue discussion with AI and confirm the AI introduction summary is spoken before the full response.
16. Interject into the AI response, summarize that interjection, and confirm the new summary does not interrupt the active AI response.
17. Tap AI turn and AI chapter rows from the primary timeline.
18. Simulate provider failure or offline mode and confirm pending AI work is recoverable.
19. Confirm system speech plays source, generated summaries, and AI responses with the expected progress indicator.
20. Export the session and confirm another session's notes do not leak in.

## Known Issues

- Signed device installation still requires local team/provisioning configuration.
- AVFoundation recording and Speech transcription need attached-device evidence before product-owner validation.

Product-owner result:
- Pass
- Pass with issues
- Fail
