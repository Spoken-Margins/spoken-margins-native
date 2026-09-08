# September 7 physical-feedback remediation

Base commit: `8f5b74c889be28a29b110f8207cda7e207d9a208` on `codex/provisional-next`. Changes remain local and uncommitted. The connected device reports developer-installed 0.1 (25), but its exact source revision is unknown. No new candidate has been installed on it by this task.

## Handoff status

**September 8 owner retest:** scrubber dislocation and zero-chunk preparation persist; opening another Library item during playback causes sluggishness relieved by closing the mini-player. Import animation smoothness is accepted. See [the updated device evidence](../../validation/gate-1/2026-09-08-device-feedback.md). Prior automated passes do not clear these failures.

Requested changes are implemented locally, not installed or distributed. Release verification remains incomplete: the composite run retains an unexplained intermittent SQLite failure, and final iPad UI clearance did not complete within XCTest's deadline. Physical-device rechecks remain pending. The newly supplied crash report is a simulator loader watchdog event, not evidence identifying the phone's voice fallback.

| Evidence | Outcome |
| --- | --- |
| Final fast plan, `20260907-183544-770237-fast` | verified: runner, contracts, surfaces, inventory, browser and package suites |
| Final app plan, `20260907-183410-634283-app` | verified: 388 passed, zero failed/skipped, 66.226 seconds |
| iPhone UI, `20260907-174953-275609-ui` | verified: 7 passed on the same app runtime; final subsequent edit only changes the seeded test's Library selector |
| Generic iOS device build | BUILD SUCCEEDED; see `device-build-feedback.log` |
| Audio adapters / speech canary | 8 adapters passed; 243-second canary passed in the retained composite release run |
| Final iPad UI, `20260907-182311-299917-ui` | failed/incomplete: five completed passes, two timed-out routes |
| Composite release, `20260907-172354-614607-release` | failed: 418 passes, two failures; UI identifier defect repaired, SQLite cause unresolved |

The SQLite case passed in the final 388-test app run, but no persistence repair was made, so the earlier failure remains open. Test destinations were iPhone 17 Pro and iPad Pro 11-inch (M4), iOS Simulator 26.5; device compilation used the generic iOS destination. These are verification destinations, not a new supported-OS declaration. The connected iPhone reports iOS 26.6.1, build 25 with unidentified source. The existing phone Library and installed app were preserved. No candidate is ready for a new human-validation handoff yet.

## Decision model

Immediate playback demand, speculative live render-ahead, bounded Library opening windows, and full offline rendering share a serial inference resource but have different readiness requirements. A playing snapshot is not proof that inference is needed. The scheduling rule permits Library work while paused, during media/fully prepared replay, or when Supertonic has two contiguous committed chunks ahead. It checks again between Library chunks, and live progress wakes a previously blocked queue. Thermal, Low Power Mode, storage, and cancellation safeguards remain.

Default ordering keeps opening windows ahead of full preparation and uses newest request first within a class; automatic opening requests use the item's creation date when available. Explicit Prioritize pins only the selected Library job above every queued class; newer ordinary imports still sort ahead of older ordinary jobs. Actual immediate speech demand remains protected separately by the speech-client readiness check. It does not discard committed chunks or interrupt the chunk currently executing. Durable opening-window jobs resume across launches even with overnight full rendering off; eligible older Library items without a job also regain an opening-window request in recency order.

## Changes and evidence boundaries

- The source-list native-text import now uses the existing playback-independent importer. Previously it called `makeEngine`, whose audio-client setup calls `streamingSpeechQueue.configureSpeechClient`, which calls `stopAndClear`. That provides a concrete mechanism for audible playback stopping without an engine snapshot transition. The fixed path also schedules the normal opening buffer. Physical animation smoothness still needs a trace/recheck.
- Slider binding writes no longer claim gesture ownership. Only editing callbacks do so; late writes after release therefore cannot latch the displayed position. A regression drives that exact callback order and checks successive canonical ticks.
- The render timeout waits for actual listener demand instead of treating every slow speculative render as a reason to switch voices. The regression delays the second render beyond the timeout while AVPlayer plays the first chunk; the existing genuinely stalled-start fallback/Retry test remains enabled. The user's exact fallback cause is not proven because the export preceded it.
- Prepared-ready generation no longer offers Stop Rendering.
- Each tab's content now owns its mini-player safe-area inset, above the system tab bar. The inset no longer wraps TabView with an assumed home-tab height. UI checks include the showcased card's scroll clearance.
- Continue Listening excludes canonical completed items even if a historical session retains partial progress. The hero no longer nests playback buttons inside a whole-card navigation button; its details have a distinct navigation action so a completion swipe is not a detail tap.

## Audit and stopping criteria

The prior slider code fails the late-write regression; the prior timeout forces an inverted fallback expectation to fire; the prior Continue Listening selector returns the marked-complete active item. Queue tests separately cover recency, explicit priority, immediate playback, and bounded two-chunk work. These are developer verification claims, not substitutes for the owner's failed physical flows. Do not close the combined scrubber gate merely because a seek reaches the right offset: its indicator must continue advancing in the same view.

The first release attempt `20260907-170641-882552-release` was stopped after the new slow-render test's fixture incorrectly expected playing from a no-op AVPlayer starter. The no-fallback assertion passed; the fixture now starts real AVPlayer. That run remains failed/incomplete, with its original evidence retained. Adapter plan `20260907-171007-542985-adapters` verified all 8 selected tests. Intermediate run `20260907-171302-290685-release` passed the new regressions and 211-second speech canary but was stopped to close queue-order/recovery omissions. Run `20260907-172022-215519-release` was stopped before any completed hosted test to fix the future-import ordering case. Neither counts as a passing release. The completed composite run is `20260907-172354-614607-release`; all new regressions and the 243-second speech canary passed, but the pre-existing intermittent podcast-import test failed with `persistence_failed:step_save:6922:disk I/O error`. Overall release verification therefore has not passed, regardless of subsequent UI outcomes.

## Owner handoff

Keep the populated phone Library intact. No reset is needed. Recheck: one-item Library selection; right-swipe Complete without detail navigation; native-text source import during another text playback; both prepared and live text scrubber tracking without leaving the screen; long native-text voice continuity; two recent imports becoming playable during prepared replay; Prioritize moving an older queued item above newer queued work; and absence of Stop after preparation finishes. Capture diagnostics immediately after any unexpected fallback. The 30-second import trace awaits the owner's ready signal.

Successful earlier observations and exact limitations are recorded in [the owner feedback](../../validation/gate-1/2026-09-07-device-feedback.md). App Store Connect reconciliation is complete: latest uploaded build 25; externally available build 21 is preserved from the existing upload record. No uploads or distribution changes were made.

## Persistence blocker investigation

The failure is `SpokenMarginsPackageHandoffTests/testImportedPodcastRequestsTranscriptFallbackAndResolvesFuzzyContext`, the same case retained as intermittent in the earlier handoff. The extended code now identifies `SQLITE_IOERR_VNODE` (6922). [SQLite documentation](https://sqlite.org/rescode.html#ioerr_vnode) reserves this code for extensions; [Apple WWDC16 session 242, slides 180–183](https://devstreaming-cdn.apple.com/videos/wwdc/2016/242vdhuk4hmwrxnb465/242/242_whats_new_in_core_data.pdf?dl=1) explains Apple's tracking of unsafe file operations against open SQLite files. The test suite deletes temporary database directories while model/background work can retain connections, making file lifecycle a concrete hypothesis; the exact offending operation is not yet identified. Do not replace this error with a generic busy retry or call a later passing repetition a repair. Next useful evidence is the failing save's database identity and call stack, paired with file-operation tracking. No persistence workaround was added in this remediation.

## Final layout correction and scoped evidence

The completed composite release run recorded 418 passed and 2 failed tests, with no skips: the persistence case above and `testExportPreviewRemainsReachableAfterStartingAnotherSession`. The latter exposed a duplicate accessibility identifier inherited by both buttons from the hero's outer Group. The identifier now belongs only to its details-navigation button. The queue's explanatory copy also now reflects the manual-priority policy. The scoped UI plan includes both export navigation and the single-card clearance route (7 cases total), preventing this omission from recurring in routine layout checks.

All 7 scoped iPhone cases passed in `artifacts/test-runs/20260907-174953-275609-ui/manifest.json`. This repairs the identified UI test failure; it does not erase the failed composite release run or establish physical owner acceptance. The final iPad, app, and device-build outcomes will be recorded below.

Input before the iPad-only test-selector correction: `8107babe60f1f9fa0140d7326e8d9585ece5d49e87ec62d2cbc24ab4cfd10a1b`. Final input, including that correction: `70c4b9ee946fa402f150e3530ef71bcafaf4044e6fe1d9a95b05385b85497794`. App runtime code is identical between these two inputs.

## Simulator launch interruption reported by the owner

The supplied report (incident `1D7C02F5-4946-4FC8-BD69-2C3B8F49CF95`, September 7 at 18:10:02 EDT) identifies verification simulator `4AAAFEBA-6DA8-4166-8347-4106165C38C2`, not the connected physical phone. FRONTBOARD terminated launch with `0x8BADF00D`; the sole thread was in `dyld_sim` shared-cache mapping before app startup, with zero recorded application CPU time. This establishes a simulator launch interruption, not an app-code crash or evidence explaining the physical mid-playback fallback. App-plan run `20260907-180747-847944-app` is affected; do not count it as verified without a completed manifest and complete test inventory. Two earlier iPad UI attempts (`20260907-175632-973276-ui`, `20260907-180208-962292-ui`) also completed zero tests while simulator launch was blocked. A separate fresh iPad simulator was prepared without resetting the owner's phone.

Final-input fast plan `20260907-180558-936305-fast` is verified. The generic iOS device build completed successfully (`device-build-feedback.log`); it was not installed or uploaded.

The final app-plan attempt was stopped after the reported loader crash and 459.537 seconds without a completed test. Its manifest correctly records failure (388 missing tests), not a passing app gate. The crash report contains no additional prose request beyond the supplied report.

Fresh-iPad run `20260907-181712-412708-ui` completed 6 passing cases and one failure: the newly included seeded route expected a static text element named Library. On iPad the Library tab is a button; the screen was visibly present. The test now asserts the existing `library.screen` identifier instead, retaining the required Library-screen condition without assuming the platform tab's accessibility type. The route had not yet reached its new mini-player assertion in that failed run.

The corrected iPad retry exceeded XCTest's two-minute limit in the accessibility route, which had passed in 90.473 seconds on the immediately preceding fresh-iPad run. Preserve this as a timeout, not a passed suite; do not expand the deadline merely to obtain a green result. Its remaining route results are recorded after completion.

Corrected iPad run `20260907-182311-299917-ui` ended failed/incomplete after 471.357 seconds: five completed cases passed, while the accessibility and seeded routes both exceeded their two-minute XCTest allowance and were missing from the completed-test inventory. The seeded route reached the hero scroll action, but its clearance assertion did not complete. Thus final iPad clearance remains inconclusive. No timeout was raised and no required case was excluded.

App run `20260907-183154-878304-app` was stopped after 102.54 seconds with zero completed tests. A one-second process sample showed the host in the ordinary UIKit event loop with XCTest bootstrap loaded but no executing XCTest cases. This differs from the earlier dyld launch crash. A simulator restart precedes the final app attempt. The proposed SQLite file-assertion diagnostic was not executed; no diagnostic flags were applied to the physical phone or production code.
