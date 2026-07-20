# Product Validation Plan

> Historical gate plan. The active release boundary and its two validation checks are defined in `Contracts/docs/recovery-mvp.md`. Watch, widgets, Live Activities, and offline Watch packages below are archived context, not active milestones.

## Purpose

This plan defines user validation gates for the full production suite.

Verification answers: did the implementation pass tests?

Validation answers: does the product actually support the intended listening, interjection, navigation, sync, and discussion workflows?

The product owner is the only validator of product flows. Agents and tests verify implementation claims; they do not validate product fit, feel, understandability, or acceptance. Each gate must therefore be production-like enough to reveal shallow or misleading progress.

## Status Language

Use these states for every gate behavior:

- `implemented`: the app has a user path or runtime path.
- `verified`: automated checks, builds, traces, or developer/device evidence support the implementation.
- `human_validated`: the product owner used the flow and accepted it.

A flow moves to `human_validated` only through product-owner use. After that, focused regression tests may be added to preserve the validated behavior.

## Automation Timing

Routine development should use fast verification: contract validators, SessionKit/runtime tests, app unit tests, and targeted builds when integration changed.

Broad UI route automation is late-gate evidence. Run it before asking the product owner to close a gate, or after a human-validated flow is important enough to protect with regression coverage. Avoid making full UI routes the default development loop.

## Validation Rules

Each validation gate must provide:

- build number
- supported device and OS list
- exact in-scope flows
- exact out-of-scope list
- known issues
- reset instructions
- seeded sample items
- diagnostics screen or diagnostics export
- verification summary listing tests/traces passed
- product-owner checklist with pass/fail notes

A gate does not pass because the happy path worked once. A gate passes when the product owner can repeat the core flow with realistic material and failures are understandable, recoverable, and honestly represented by the UI.

Validation gates should feel ambitious. They should not be throwaway demos.

Human validation records should be stored under `artifacts/validation/gate-N/` with the date, build, device, flow, pass/fail result, and notes.

## Gate 0: Validation Harness Readiness

Goal: make sure product validation itself is possible.

### In Scope

- installable iPhone/iPad build
- seeded sample items and reset data command
- visible build number
- visible active runtime profile
- diagnostics for provider status, sync status, prepared packages, pending jobs, and recent failures
- known issues visible in release notes or diagnostics

### Validation Flow

1. Install the build.
2. Reset all local data.
3. Load seeded fixtures.
4. Confirm current runtime profile is visible.
5. Confirm diagnostics show provider, sync, package, and pending job state.
6. Trigger one known unsupported command and confirm it is honestly unavailable or rejected.

### Pass Criteria

- Product owner can install, reset, load fixtures, and identify runtime mode without developer coaching.
- Diagnostics are sufficient to distinguish product failure from setup failure.

### Out Of Scope

- polished UI
- watch app
- browser extension
- car controls

## Gate 1: Phone/Tablet Core Session

Goal: validate the core Spoken Margins interaction loop on the canonical runtime.

### In Scope

- text item import or creation
- Listening Map load/generation
- mapless session
- app-owned TTS
- TTS URL cleanup
- chapter navigation
- skip back/forward
- interjection recording
- rollback/resume
- multiple interjections in one session
- interjection summary
- summary playback
- interjection into summary
- addendum/follow-up
- AI discussion response
- interjection into AI response
- retryable AI failure
- offline degraded behavior
- session-isolated export

### Validation Flow

1. Create or import a text item that contains at least one long URL and one Markdown link.
2. Start playback and confirm URLs are not spoken while source text remains intact.
3. Jump between Listening Map chapters.
4. Skip back and forward repeatedly and judge whether movement feels predictable.
5. Record at least five interjections during source playback.
6. Confirm playback resumes from enough context after each interjection.
7. Generate an interjection summary.
8. Listen to the summary.
9. Interject into the summary.
10. Add an addendum or follow-up.
11. Continue discussion with AI.
12. Interject into the AI response.
13. Simulate provider failure or offline mode and confirm pending AI work is recoverable.
14. Export the session and confirm another session's notes do not leak in.

### Pass Criteria

- The interaction loop feels natural enough for a real article.
- Navigation does not feel erratic.
- Interjections remain anchored and recoverable.
- AI failure does not lose user work.
- Export is useful and session-scoped.

### Out Of Scope

- watch-only playback
- browser capture
- YouTube/media capture
- car controls

## Gate 2: Lock Screen And Widget

Goal: validate compact delegated control from the phone lock screen or widget surface.

### In Scope

- current item/title display
- current chapter or target display
- play/pause
- skip back/forward
- begin interjection
- finish interjection
- return to app with anchored note visible
- background audio continuity

### Validation Flow

1. Start a phone/tablet session.
2. Lock the device.
3. Confirm compact surface shows item, chapter/target, playback state, and recording state.
4. Pause and resume.
5. Skip back and forward.
6. Begin an interjection from the compact surface.
7. Finish the interjection.
8. Unlock the phone and confirm the note is attached to the correct session/anchor.

### Pass Criteria

- Common session actions are possible without reopening the app.
- Compact controls never claim unsupported local capabilities.
- Anchoring remains correct after delegated interjection commands.

### Out Of Scope

- watch app
- offline watch packages
- browser extension
- car controls

## Gate 3: Tethered Watch

Goal: validate the watch as a remote control surface for the phone/tablet runtime.

Status: closed as a tethered remote-control surface. See `docs/gate3-watch-tethered-closeout.md`.

### In Scope

- watch displays current item and chapter/target
- play/pause
- skip back/forward
- scroll chapters
- jump to chapter
- phone app reflects all watch actions
- active profile is `watch-tethered`

### Validation Flow

1. Start a phone/tablet session with the watch nearby.
2. Confirm watch shows the current item and chapter/target.
3. Pause and resume from watch.
4. Skip back and forward from watch.
5. Scroll chapter list and jump to a chapter.
6. Submit Discuss from watch when available and confirm the phone session receives the delegated request.
7. Confirm Watch-started interjection is not exposed in Gate 3.

### Pass Criteria

- Watch feels like a reliable remote for walking with phone nearby.
- Watch does not pretend to own playback, recording, AI, or persistence locally.
- Watch does not expose unsafe delegated recording while the phone is locked.

### Out Of Scope

- watch-owned playback
- watch transcription
- watch AI
- watch-started interjection recording
- phone-free walk

## Gate 4: Untethered Watch

Goal: validate the phone-free watch and AirPods walk.

Gate 4 should start from the Gate 3 Watch lessons in `docs/gate3-watch-tethered-closeout.md`, especially the finding that delegated phone recording from Watch is unsafe while locked.

### In Scope

- prepare watch package on phone/tablet
- transfer package to watch
- play prepared audio on watch
- navigate packaged chapters
- record interjection audio
- preserve source media time/transcript anchor
- queue offline sync events
- reconnect to phone/tablet
- import watch-created audio and anchors
- defer transcription/cleanup until phone/tablet is available

### Validation Flow

1. Prepare a text item or podcast-like item for watch.
2. Confirm package transfer to watch.
3. Leave phone behind or disable tethering.
4. Listen on watch with AirPods.
5. Navigate chapters.
6. Record multiple interjections.
7. Finish the walk/session.
8. Reconnect watch to phone/tablet.
9. Confirm audio and anchors sync back.
10. Confirm phone/tablet can transcribe/process later.

### Pass Criteria

- Product owner can take only watch and AirPods on a walk and return with usable anchored interjections.
- Watch does not attempt TTS generation, transcription, AI, or map generation while untethered.

### Out Of Scope

- browser capture
- car controls
- watch-based AI

## Gate 5: Browser Extension For Text

Goal: validate browser text capture as an intake path into Spoken Margins.

### In Scope

- selected text capture
- readable page text capture
- page title/source URL metadata
- browser text runtime profile
- browser or delegated TTS, depending on active profile
- interjection capture when permissions allow
- handoff to native app
- continuation in phone/tablet app

### Validation Flow

1. Open a normal article page.
2. Capture selected text into a Spoken Margins item.
3. Capture readable page text into a Spoken Margins item.
4. Confirm title and source URL are preserved.
5. Start listening from browser or hand off to app, depending on implemented mode.
6. Record an interjection if browser permissions allow.
7. Continue the session in the app.
8. Generate summary/discussion in app.

### Pass Criteria

- Browser text capture feels like a natural way to start a Spoken Margins session.
- Handoff preserves source, text, anchors, and session identity.

### Out Of Scope

- YouTube/video
- arbitrary website media control
- offline watch

## Gate 6: Browser Extension For YouTube / Media

Goal: validate browser-owned media anchoring, especially sped-up YouTube-like playback.

### In Scope

- detect supported video page
- detect current media time
- observe playback speed
- capture transcript/captions when available
- anchor interjections to source media time
- preserve transcript segment/span when available
- hand off session to native app
- continue summary/discussion in app

### Validation Flow

1. Open a YouTube-like video with transcript/captions.
2. Set playback speed to 1.5x or 1.75x.
3. Start a Spoken Margins browser media session.
4. Confirm transcript/caption capture.
5. Interject during playback.
6. Confirm anchor uses source media time, not wall-clock elapsed time.
7. Hand off to native app.
8. Resume session and generate summary/discussion.

### Pass Criteria

- Interjections land at the correct source moment even when playback is sped up.
- Transcript/caption capture is clear about availability and failure.
- Native app continuation feels coherent.

### Out Of Scope

- every media website
- generated transcript when no transcript exists, unless explicitly included
- browser as canonical durable store

## Gate 7: Basic Car Controls Without CarPlay

Goal: validate safe, predictable use through transport-only car controls.

### In Scope

- session started before driving
- play/pause
- skip back
- skip forward
- preconfigured interjection strategy
- recovery when only transport controls are available

### Validation Flow

1. Configure basic car behavior before driving.
2. Start a session before driving.
3. Use only play/pause/back/forward controls.
4. Confirm skip commands are predictable.
5. Trigger the configured interjection strategy.
6. Finish or recover from interjection using only available controls.
7. Review resulting session afterward.

### Pass Criteria

- Transport-only controls are safe and understandable.
- Interjection behavior is explicit before driving.
- The session remains recoverable after limited-control use.

### Out Of Scope

- chapter browsing
- AI discussion management
- rich display
- CarPlay

## Gate 8: All-Up Suite

Goal: validate that the production suite behaves like one coherent product.

### In Scope

Validate across:

- long article
- short article
- mapless item
- item with URLs
- AI discussion-heavy item
- multi-speaker/conversational interjections
- prepared watch item
- browser text item
- YouTube/media item
- basic car control session

### Validation Flow

1. Run a full phone/tablet session.
2. Run a lock screen/widget session.
3. Run a tethered watch session.
4. Run an untethered watch session.
5. Capture browser text.
6. Capture YouTube/media session.
7. Run basic car control session.
8. Export and inspect the resulting sessions.
9. Confirm diagnostics and pending jobs are understandable.
10. Confirm no surface claims capabilities it does not have.

### Pass Criteria

- The suite feels like one product, not disconnected prototypes.
- Sessions survive interruptions, offline/online transitions, and sync.
- Exports are useful.
- Failure states are honest and recoverable.

## Validation Report Template

Each gate should produce a short report:

```text
Gate:
Build:
Date:
Devices:
Runtime profiles exercised:
Verification summary:
Known issues:

Product-owner result:
- Pass
- Pass with issues
- Fail

Validation notes:

Blocking issues:

Follow-up decisions:
```
