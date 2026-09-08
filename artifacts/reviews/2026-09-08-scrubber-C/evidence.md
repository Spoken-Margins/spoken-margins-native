# Scrubber correction C: actual Simulator evidence and phone handoff

Diagnostic B failed the owner's phone recheck and was reverted, rebuilt, and reinstalled as A before further work. C was developed against actual touch-drag failures in the Simulator. Only the final passing candidate was installed on the phone.

## Final change

The position control uses one UIKit touch recognizer to map the finger onto the native slider's thumb travel and commit that value on release. Playback updates reposition the control only outside a drag. The back-swipe recognizer is confined to the left 32 points instead of competing with controls across the whole screen. This avoids the original SwiftUI editing callback reopening after a seek and the B control losing its drag to the parent gesture. Range bounds are updated only when changed.

## Verification

Dedicated iPhone 17 Pro Simulator, iOS 26.5, UUID 4AAAFEBA-6DA8-4166-8347-4106165C38C2. `testPlaybackScrubberAcceptsPhysicalDrag` uses actual XCUI touch press/drag/release events through the full app with Supertonic, not direct callback calls or value injection.

- Negative control B: actual drag to 70% stopped at 4%. `/tmp/spoken-real-drag-B.xcresult`; `B-drag-failure.log`.
- Negative control A: seeks landed but display stopped advancing. Recording `../2026-09-08-scrubber-B/simulator-A-failure.json` shows editing=false, seek=6774, then another editing=true without a new touch; displayed remains 6773.825 while canonical advances past 7097. `/tmp/spoken-real-drag-A-recording2.xcresult`; `A-progress-failure.log`.
- Final C: three actual playing drags to 70%, 22%, and 85% reached their targets and resumed advancing after release. A fast paused drag to 40% reached its target without autoplay. Edge-back navigation still worked. The entire final test passed in 81.756 seconds, with no skips. `/tmp/spoken-drag-touch-final.xcresult`; `final-ui-test.log`; `final-screenshots/`.
- Final recording `simulator-final-capture.json`, capture 4C1A7D95-2C0C-4CF9-8833-03C8BFC05205, contains seek offsets 6623, 2041, 8062, and 3761 out of 9430 (70.2%, 21.6%, 85.5%, 39.9%). Schema validation passed, 260 events. Its build marker is C.
- Device build, test inventory, diff-whitespace check, and inverse-patch dry-run passed. Broad regressions remain deferred until the owner's recheck, as requested.

Falsified Simulator-only candidates: deferring the seek did not resolve the extra editing start; restricting edge recognition alone did not fix the SwiftUI slider; the initial native-control combination passed slow playing drags but failed fast/paused precision. Reapplying unchanged bounds was not the full cause. Temporary geometry logging was removed. Final direct touch mapping passed with destinations calculated over the thumb's travel range and a stricter five-percentage-point maximum test tolerance. These failed intermediate candidates were not installed on the phone.

## Phone handoff

- Build: Debug 0.1 (25), `device-diagnostics-20260908-C`.
- Base commit: `8f5b74c889be28a29b110f8207cda7e207d9a208`, branch `codex/provisional-next`, plus uncommitted changes. No new commit or TestFlight upload.
- Device debug dylib SHA-256: `df9f68f4852ed210c93c408d2d603b0c3f7f4e16b6647c6945f3e5bec98954f9`.
- In-place development install on the owner's iPhone 17 Pro, iOS 26.6.1; Library preserved. Installation succeeded (`install.json`). Automatic launch was denied because the phone is locked (`launch.json`); the owner must unlock and open the installed app.
- Verified device/OS coverage is limited to the iPhone 17 Pro Simulator on iOS 26.5 plus physical-device compilation/install on iOS 26.6.1. Other devices/OS versions have not been rechecked.
- In scope: text playback scrubbing, release, continued position updates, paused seeking, and edge-back navigation. The control is also shared by media, but this test does not establish media-seek or iPad behavior.
- Known issues/out of scope: duplicate Follow suggestions, opening-preparation backlog, and other previously unvalidated changes already in this worktree remain unresolved.
- Reset: none. Use the existing Inflation or How to Pace the US Frontier item. The Simulator uses a seeded 9,430-character text; no phone import is required.
- Diagnostics: Settings → Developer → Developer tools → Record Device Diagnostics. Enable, reproduce, turn off, then Copy Privacy-Safe Diagnostics. Recording is opt-in and off after restart.
- Owner checklist, pending: while playing, scrub backward to approximately 22%, release, and watch/listen for 10 seconds. Confirm the audio and indicator continue from the selected location. Try a forward drag and a quick paused drag. Record pass/fail. This candidate is implemented and supported by automated evidence, not human_validated.
- Rollback if rejected: `git apply -R artifacts/reviews/2026-09-08-scrubber-C/scrubber-only.patch`, regenerate the project, rebuild, and reinstall in place. The inverse patch preserves diagnostic A and all earlier unrelated work. Keep the real drag test and evidence.
