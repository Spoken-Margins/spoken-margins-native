# Gate 1 Readiness Report

Date: 2026-06-14

Result: **DO NOT ASK PRODUCT OWNER TO VALIDATE GATE 1 YET**

This report is the adversarial falsification pass for Gate 1: Phone/Tablet Core Session. It uses the inventory in `validation/gate1-behaviors.json` and the matrix in `docs/gate1-readiness-matrix.md`.

## Commands

Run these commands from the repository root:

```bash
python3 scripts/audit-gate1-readiness.py
python3 scripts/audit-gate1-readiness.py --strict
python3 scripts/validate-contracts.py
cd Packages/SessionKit && swift test
xcodebuild -project SpokenMarginsNative.xcodeproj -scheme SpokenMarginsApp -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY='-' -quiet build
```

Expected readiness-audit result:

```text
ready: 1
partial: 27
not_ready: 1
```

`--strict` is expected to fail until every behavior is ready.

## Falsification Outcome

The codebase has meaningful Gate 1 foundations: SessionKit command traces, SQLite persistence, a SwiftUI shell, AVFoundation adapter boundaries, provider settings, and core tests. Several previously missing runtime paths have now been wired: offset-aware TTS restart for skip/jump/rollback, Speech.framework transcription, summary/AI response playback, interjection Cancel, interjection detail/delete, Home stop, End Session, and runtime profile rebuilding.

Gate 1 still should not be declared fully ready because real phone/tablet evidence remains missing and the Listening Map validation path still lacks structured repair reporting and UI automation. Many newly wired paths also need UI automation and device validation before the strict gate should pass.

## Critical Failures

### 1. Native playback still lacks device evidence and continuous progress

SessionKit now prepares the current target text and asks the audio client to start from `Session.position.charOffset`. `SystemSpeechPlaybackClient` restarts from the requested offset for skip/jump/rollback and continues a paused utterance for ordinary pause/resume.

Impact:

- Device validation is still needed to judge audible quality and route behavior.
- Long-form progress is not continuously tracked through an AVSpeechSynthesizer delegate.

Relevant behavior IDs:

- `G1-APP-OWNED-TTS`
- `G1-CHAPTER-JUMP`
- `G1-SKIP-BACK-FORWARD`
- `G1-ROLLBACK-RESUME`

### 2. Listening Map validation/repair is still incomplete

The prototype spec requires strict JSON validation, anchor resolution, and repair reports. The app now has a product path where a user can paste a `listening-map.v1` JSON object, validate required fields and anchors against the item text, persist the map, and mark the item ready. A UI test covers the valid-map path, and a store regression test verifies the newly applied map becomes active. The remaining gap is malformed-map UI coverage, a structured multi-issue repair report, and a provider-output repair loop.

Impact:

- Bad AI-generated map output can be rejected, but malformed-output behavior is not UI-tested or repaired through a guided product workflow.
- Manual map generation does not prove provider-backed strict JSON behavior.

Relevant behavior IDs:

- `G1-MAP-VALIDATION-REPAIR`
- `G1-MAP-GENERATE-MANUAL`

### 3. Device validation is still absent

The existing artifacts show simulator launch/build and automated tests. Gate 1 requires phone/tablet validation of microphone recording, Speech.framework transcription, saved audio, playback voice quality, provider failure/retry, offline behavior, and practical session flow.

### 4. Many new product paths need UI tests

The following are now implemented and reachable, but not yet proven through UI automation:

- summary playback
- AI response playback
- interjection into summary
- interjection into AI response
- Cancel
- timeline detail/delete
- End Session
- runtime profile change/offline deferral

## Behaviors That Should Not Be Counted As Ready

These behaviors now have implementation but should not be presented as fully validation-ready without UI/device evidence:

- Manual map generation: exists, and manual paste validation has valid-path UI coverage, but malformed-path UI coverage, repair reports, and provider-backed map parsing evidence remain incomplete.
- Chapter navigation: now restarts audio from the chapter offset, but needs device validation.
- Skip back/forward: now restarts audio from the new offset, but repeated-skip UX needs device validation.
- Interjection Done: now triggers Speech.framework transcription, but needs real-audio evidence.
- Multiple interjections: trace coverage exists, not real recording-loop evidence.
- Summary generation/playback: scoped prompt and turn playback exist, but need provider/UI evidence.
- Follow-up and AI discussion: typed path and playback exist, but provider/device evidence remains.
- Session-isolated export: core trace exists, but UI does not prove isolation or expose export options.

## Behaviors With Strong Evidence

Only this behavior currently survives the stricter readiness definition:

- `G1-TTS-URL-CLEANUP`: core normalization is tested and source preservation is asserted.

## Required Exit Criteria Before Human Validation

Gate 1 should not be handed to a product owner until:

1. `python3 scripts/audit-gate1-readiness.py --strict` passes.
2. Structured Listening Map repair reporting exists or Gate 1 scope is amended to exclude the repair loop.
3. UI tests exercise imported mapless item creation, manual map generation, chapter jump, five interjections through a test recording client, transcription success/failure, summary playback, AI-response playback, follow-up, retry, timeline detail/delete, and export isolation.
4. Device evidence exists for microphone permission, saved audio file, Speech.framework transcription, Siri/enhanced voice playback, route/interruption behavior, provider failure, and offline mode.
5. Live playback progress is either implemented through synthesizer delegate updates or explicitly declared out of Gate 1 validation scope.

## Conclusion

Gate 1 is much closer: the most serious "modeled but not executed" failures have been wired into runtime paths. It is still not a strict ready-for-validation gate until repair-report depth, UI automation, and device evidence are complete.
