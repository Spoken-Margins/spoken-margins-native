# Blocking background audio-preparation crash

Owner report: while listening around 22 minutes, tapping the Live Activity microphone opened an app showing about four minutes of progress. Capture and app/Control Center/Lock Screen pause controls did not respond; removing/reconnecting headphones stopped the audio. App subsequently would not open.

## Evidence and limits

Xcode was paused on the connected iPhone 17 Pro with Thread 57 marked as the crashing thread, queue `com.apple.BGTaskScheduler (com.spokenmargins.native.audio-preparation)`, stopped at `_dispatch_assert_queue_fail` / EXC_BREAKPOINT. Before a full live backtrace could be retrieved the debug process ended; the console command therefore did not produce that live trace. No debugger Stop command was issued by this investigation.

The device’s earlier same-day `SpokenMarginsApp-2026-09-12-100221.ips` independently identifies the identical BGTask queue and stack: `_dispatch_assert_queue_fail` → `_swift_task_checkIsolatedSwift` → `closure #1 in AudioPreparationBackgroundController.register()` → BGTaskScheduler launch delivery. Raw device reports are kept locally under `.build/device-investigation/20260912-background-crash` and are not published.

The scheduler registration closure inherits MainActor isolation from the controller, while `using: nil` requests a default background queue. Apple’s installed SDK documents this behavior in BGTaskScheduler.h. The actor check can trap before the inner MainActor Task is created. A debugger-paused app cannot service its UI or remote-command callbacks, which is consistent with the frozen progress/controls. This does not independently prove that the microphone tap caused the background launch or that every observed audio symptom has the same cause. A separate 09:17 report records a scene-update watchdog termination; its relationship is unproven.

## Bounded repair

Register the main-actor launch callback with `.main`. Construct expiration cancellation in a nonisolated helper returning a Sendable closure, so a scheduler expiration callback does not inherit MainActor isolation. A regression invokes expiration from a detached task and proves active preparation cancels and exits its continuation loop. Existing tests cover draining and retry-later behavior.

Distribution remains stopped. The prepared Build 27 archive contains the defect and is blocked. No upload retry, tag, triage advancement or remote push is authorized. Preserve the owner’s Library.

The existing installed app was relaunched through devicectl successfully, without install/reset/autoplay. This is recovery from the stopped process, not installation of the repair or acceptance of the lock-screen route. The owner confirmed “Yes, it responds again.” That validates recovery of responsiveness, not the uninstalled repair.

## Why the previous checks missed it

The existing background-preparation tests exercised the drain loop directly on the main actor. They did not ask iOS to deliver the registered launch callback on BGTaskScheduler’s default queue. The real device report supplies that missing boundary evidence. The cancellation regression now exercises a background caller; explicit main-queue registration fixes the launch boundary. Automated passes do not replace a physical-device background/Live Activity recheck.

Required owner recheck after a corrected development installation: use the existing podcast and headphones, allow background playback to advance beyond the displayed starting position, then invoke the Live Activity microphone. Confirm current position, recording start/stop, and app/Lock Screen pause/resume. Repeat with charging-only preparation enabled while connected to power so the scheduler path can run. Preserve Library data; no reset or map regeneration is required. If failure recurs, retain Xcode’s stopped state/backtrace before terminating the process. Do not resume TestFlight distribution based on recovery alone.

## Verification and candidate

The repair is local and uncommitted on `codex/provisional-next`, based on `79d9357`. Input SHA-256: `ead7d30e89f97d757fa02b19c42fc37185c04e8a9d0149428c452d06718dc476`. Supported deployment remains iPhone/iPad iOS/iPadOS 18+. Simulator checks used iPhone 17 Pro / iOS 26.5; a generic physical iOS Debug build passed.

[Verification manifest](../../test-runs/20260912-background-crash/manifest.json): all 418 app cases independently confirmed Passed from Apple’s structured xcresult, including detached expiration cancellation; all 11 adapter tests passed; fast checks passed; device build passed (94.528s). The original app runner report remains incomplete because console output split one passing result line. `app-cases.json` records the structured reconciliation; no missing test was silently ignored and the app suite was not rerun. No release suite or speech canary was repeated for this callback-boundary repair.

The corrected app is **not installed on the owner’s phone**. Device relaunch/recovery used the existing installed version. The old archive remains blocked; this change is `implemented` and `verified`, while the corrected physical-device background/Live Activity flow is not yet `human_validated`. No commit, upload, tag or remote push was performed for this repair.

## Internal rollout authorized

The owner subsequently asks to include this repair in Build 27 (28 if necessary), commit/push and submit to internal testers. This authorizes a freshly verified corrected binary; it does not authorize uploading the earlier defective archive. Recovery remains owner-confirmed; the fixed physical lock-screen route remains an explicit internal tester check.
