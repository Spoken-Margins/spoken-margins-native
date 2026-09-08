# Device capture: scrubber stuck at 22 percent

Owner supplied capture `0E5F8374-B02B-4521-9E4A-CC0526D86FEE`, build `device-diagnostics-20260908-A`, exported 2026-09-08T12:51:50Z. Source is the owner's pasted JSON; the sequence below is an excerpt, not a new recorded run.

At elapsed 8,971 ms: editing=false; seek requested offset 2027 of 9042 (22.4%). At 9,654 ms another editing=true and a drag value 2026.60479 appear. No matching editing=false follows before leaving playback. Canonical offsets then advance from 2037 through 2530 while every displayed binding value stays at 2026.60479 with editing=true. The prior late-binding-write fix did not cover this subsequent begin callback.

Patch B replaces only the media/text position SwiftUI Slider controls with a UISlider representable. Real accepted beginTracking owns editing; end/cancel closes ownership before the seek callback. Programmatic updates and untracked valueChanged events do not begin a gesture. VoiceOver adjustment explicitly begins/ends a single action. This is a targeted mechanism change awaiting the owner's physical recheck, not a claim of human validation.

`git apply -R artifacts/reviews/2026-09-08-scrubber-B/scrubber-only.patch` reverses only this patch (then regenerate the Xcode project). Do not revert the entire dirty worktree. Retain diagnostic recording A and all earlier work if this targeted patch fails.

The supplied screenshot confirms two identically labeled Follow AI Futures Project buttons. It shows a later playback item with 4/238 generation; it does not show the 22% scrubber. Follow prompts and preparation are intentionally outside this patch. Capture samples show the Inflation Library row at 0/2 while generation for that same item advances to ready 40/40, canPrepare=true, workerActive=false, queueCount=9. Queue policy and readiness reconciliation still need a separate correction; generic CPU contention is not established.

## Verification and candidate

Build label `device-diagnostics-20260908-B`, Debug 0.1 (25). Base SHA 8f5b74c889be28a29b110f8207cda7e207d9a208 plus current uncommitted changes. Device compilation succeeded. One focused hosted XCTest passed in 0.011 seconds: `testPlaybackSliderIgnoresNonTouchValueEventsAndTracksCanonicalUpdates`. Broad regression tests deferred pending owner recheck. Reverse patch applies cleanly in dry-run. Debug dylib SHA-256: `6aa4cd9735df804b86bd6f4cdb1a79efbd19657967967fda563ebdff173a7dd4`.

Owner recheck: enable recording, resume Inflation, scrub to roughly 22%, release and leave the playback screen open for 10 seconds. Pass requires the indicator to follow playback after release, with no view reopening. If it fails, turn recording off/export and revert only this patch before another proposed correction. No Library reset or sample import is needed.

## Failed owner recheck and rollback

Owner rejected B with capture F9E55B23-26B3-4231-9610-77C2479BFA07, exported 2026-09-08T12:59:59Z. On How to Pace the US Frontier (43,332 characters), gesture one begins at 20,940 ms and ends 4 ms later, requesting the unchanged offset 340. Gesture two begins at 26,578 ms and ends 13 ms later, requesting offset 1481 after starting at 449. Canonical playback then advances from the requested location. This implicates premature touch termination, not a renderer rollback after accepting the intended destination. The callback-only XCTest did not exercise an actual drag and was insufficient evidence.

Reversed scrubber-only.patch, regenerated the project, built successfully, and reinstalled/launched diagnostic A on the connected phone in place, preserving Library data. No new fix is claimed. Actual Simulator touch-drag investigation follows before any further candidate.

## Actual Simulator drag comparison

Dedicated iPhone 17 Pro Simulator, iOS 26.5, UUID 4AAAFEBA-6DA8-4166-8347-4106165C38C2. Added testPlaybackScrubberAcceptsPhysicalDrag using XCUI coordinate press/drag/release events through the full app, not accessibility adjustment or synthetic valueChanged. Against restored A, three destinations (70%, 22%, 85%) passed in 26.6 seconds. Against the retained compiled B app using the same compiled test, the first drag to 70% failed at 4% in 24.6 seconds. Results: /tmp/spoken-real-drag-A.xcresult and /tmp/spoken-real-drag-B.xcresult. B was used only as a Simulator negative control; it remains reverted in source and on the phone.
