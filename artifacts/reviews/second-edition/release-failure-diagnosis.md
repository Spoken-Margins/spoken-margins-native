# Release test interaction failures

The complete release run `20260910-180817-477428-release` executed all 436 selected cases: 434 passed and two UI cases failed. It remains failed evidence.

## Sender preview return

The native system share sheet opened and dismissed successfully. At the last preview attempt the test treated `isHittable` as sufficient. The exported failure hierarchy places `build23.sender.preview.build` at y=830.7, height=56.3 in an 874-point screen; the pinned recipient-test footer starts at y=791. The video frame `release-sender-failure/before-final-preview.png` shows the preview control offscreen. This establishes the invalid test target and does not establish package rebuilding failure. The initial independent runtime hypothesis was withdrawn when asked for activation evidence; no caching or verification-runtime change was made.

The test helper now requires the complete control frame within the viewport and above the footer. It drags within visible content until that condition holds or fails after bounded attempts. The full sender test retains stale-preview invalidation, package verification, actual ActivityListView presentation, dismissal and return assertions. A capture precedes preview activation.

## Pull from playback into Timeline

The test dragged from 78% of a full-screen ScrollView frame: y=681.7. The exported hierarchy places the fixed `playback.controls` at y=532 through 874. The gesture therefore began in the dock, not in content. The test now derives its start from the top of the controls and pulls only the content, with bounded attempts to reach the overscroll threshold. It still requires actual gesture navigation, keyboard editing/dismissal and return to the player; it does not substitute a Timeline button tap.

Only `Gate1FlowUITests.swift` changed in this repair. Per-file before/after digests are in `release-ui-test-amendment.json`. App behavior and the prior device-matrix binary inputs remain unchanged. Focused execution and a complete release rerun are required before final acceptance.

## Focused falsification

`20260910-183436-release-focus` passed the complete sender route after the visibility correction, without a sharing-runtime change. The corrected content drag still failed Timeline navigation. Code inspection identified a separate short-content bug: the maximum resting offset was clamped to zero, ignoring a negative top-inset resting offset. The helper now takes the real top inset and computes `max(-topInset, contentHeight + bottomInset - containerHeight)`. A regression covers rest, 71/72-point activation and long content with the fixed dock. This is an implementation change, so the earlier test-only equivalence applies only to the sender repair. Native gesture execution and the final matrix must be refreshed.

Runtime measurement resolved the remaining pull defect: `pull-geometry-measurements.json` records a 416-point content container,116-point top inset and 342-point dock in an 874-point window. The old calculation treated416 as the whole viewport and counted reserved space twice. The caller now reconstructs the whole viewport before computing the inset-aware end offset. Temporary logging was removed. `20260910-184456-release-focus` passed the real gesture, reflection editing, keyboard dismissal and return sequence in 41.287 seconds. The full matrix is being refreshed on this repaired implementation.

The refreshed iPad run (`20260910-184728-621002-ui`) exposed two test assumptions. Its preview button was visibly inside the form sheet, but the helper applied the phone home-indicator reserve to the sheet edge. The helper now applies that reserve only to the physical window edge. Its long-title swipe correctly navigated to Timeline because the title fitted on iPad; the ordinary-scroll fixture now overflows both device widths and asserts actual content movement while controls stay reachable. The separate pull test retains deliberate navigation. All three relevant iPad routes passed in `20260910-185816-ipad-release-focus`. Captures: `ipad-sender-geometry/end.png` and `ipad-player-overscroll/end.png`. These final adjustments change only test interaction/fixtures, not the repaired runtime.


## iOS 18 navigation-bar tap repair

The final small-phone route reached Timeline, edited the reflection, dismissed the keyboard and refocused successfully, but an ordinary center tap on the native back button did not navigate. The failure's accessibility frame is x=8…52 (center x=30), overlapping the existing 32-point leading-edge swipe overlay. The failure screenshot retains keyboard focus. A diagnostic using the same button's right side (x≈48) passed without changing navigation state or pull geometry (`20260910-191551-small-return-diagnostic`). This supports blocked hit delivery rather than a navigation loop.

The production repair reserves the navigation bar and safe-area region above the edge-swipe surface; its width and horizontal thresholds remain unchanged. The diagnostic tap offset was removed. The complete route with the ordinary center tap passes in `20260910-191946-small-return-repair`. Final matrix verification uses this source. The diagnostic is supporting evidence, not the acceptance test.
