# Podcast anchor reliability verification — September 24, 2026

Branch `codex/co-op`; HEAD `34837c6055471297ca0b360c591f734bad5c2c82`. The candidate is uncommitted and includes pre-existing dirty work. The owner requested full testing after the individual implementation fixes. This is engineering verification, not product-owner validation or a release handoff.

## Passed evidence

- [Fast manifest](../../../test-runs/20260924-092051-223385-fast/manifest.json): 345 package tests passed, one expected held-out-corpus skip; runner, contracts, surfaces, inventory, and browser checks passed. Input `3bcbd963bd55417dda27fd8786476bc63a48bd4de41e46c913d3e6f53a28e23d`.
- [App manifest](../../../test-runs/20260924-092152-872232-app/manifest.json): 482/482 app tests passed on iPhone 17 Pro, iOS 26.5, UDID `856FA6EF-5E03-4120-939B-F0EF42A804E8`, on that same input.
- [Adapters manifest](../../../test-runs/20260924-092515-837470-adapters/manifest.json): 11/11 passed. [Speech-canary manifest](../../../test-runs/20260924-092549-502088-speech-canary/manifest.json): 1/1 passed, including real playback.
- [UI manifest](../../../test-runs/20260924-094738-361900-ui/manifest.json): 16/16 passed after a test-only correction to scroll “Copy with Context” into view and assert it is above the fixed playback action before tapping. The initial run failed 1/16 because it tapped the covered action; the focused corrected route and full rerun passed. UI input `21b62273f932814b04fa9c54f28e33602985fb29b5247e798e395c31cf412a65`.
- [Held-out benchmark result](../../sharing-next/podcast-anchor-benchmark-result.json), [test log](held-out-benchmark-test.log): 232 anchors, 226 eligible and 6 absent. Acoustic and fused-monotonic each had zero false-confident placements and 4 ms p95 error, satisfying the recorded zero / ≤1.5-second gate. The benchmark test passed.
- [Real export host test](real-export-host-test.log): `SharingTests/testRealRecipientWindowExportKeepsMeasuredSourceBoundsAtMiddleAndEpisodeEnd` passed on macOS, exercising actual AVFoundation export bytes and measured source bounds for middle and episode-end windows. The parallel iOS app test compiled but has not executed.
- Generic iOS Simulator and generic iOS device builds passed: [simulator build log](generic-simulator-build.log.gz), [device build log](generic-device-build.log.gz). `git diff --check` passed.

## Incomplete evidence and disposition

After adding the iOS real-export regression, the [latest app manifest](../../../test-runs/20260924-101738-901394-app/manifest.json) built the 483-test bundle but completed **0/483** tests. The [result-bundle summary](app-runner-stall-summary.json) reports “The test runner hung before establishing connection.” This is a test-startup failure, not an app assertion failure. The earlier 482/482 app pass supports the implementation before that test was added; the newest app test has only compiled. A repeat without an evidence-backed host/simulator repair would violate the recorded [execution readiness boundary](test-execution-readiness.md), so no unchanged retry, simulator reboot, or device switch was made.

The earlier iPad SpringBoard crash and iOS 27 AppIntents system assertion still block those platform variants. Physical-device capture/resource measurements and product-owner flow validation remain outstanding. The repository's monolithic `release` plan was not run because it would repeat the individual passing plans while the app startup blocker remains. The project has no Watch scheme/target, so the documented generic Watch build cannot run. No commit, merge, device installation, or distribution occurred.

The next engineering step is an evidence-backed repair of the XCTest startup environment on the recorded phone, followed by the single pending iOS real-export test and a current-input app plan. Then obtain physical-device/resource and owner-validation evidence before any release-readiness claim.
