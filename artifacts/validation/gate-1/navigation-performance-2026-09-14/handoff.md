# Navigation performance candidate — September 14, 2026

Source: `codex/provisional-next`, base `ad533d6604dbacf892df85dc06f36d63c2f97a08` plus uncommitted changes. Version 0.1 (27), distinct from internal TestFlight 27 at `adeb923`. No commit, installation, or distribution. Existing Margin/Follow and resource-recovery work preserved.

## Implemented

- Model-directory hashing streams 64 KiB blocks instead of constructing a roughly 138 MB aggregate buffer. Byte ordering/separators and the final render identity are unchanged, preserving existing prepared-audio compatibility. Only immutable installed-bundle model hashes are cached; external/test assets are rehashed. First speech-client identity work is also asynchronous, and its preparation callbacks await the shared task.
- A single-entry exact-source cache reuses the Library chunk plan. Changed text rebuilds it; memory warnings clear it. Speech rendering copies the full generation plan only when the first preparation callback actually needs it.
- Normal chunk completion updates the affected Library row and existing queue rows, including removal/policy/adjacency changes. It does not reload all Library items, sessions and manifests. Completion and exceptional paths retain full reconciliation.
- Runtime diagnostics have their own observable owner and dedicated Settings view. Diagnostic updates no longer notify the whole navigation model. Equal generation-progress/state values avoid redundant publication where possible.
- Home changes screen immediately, reflects known source progress, and reads Library data on a worker after the transition interval. Cancellation, screen checks and a presentation revision prevent stale results from replacing newer Library mutations. Routine persistence remains owned by the existing playback ticker and explicit lifecycle/mutation paths.
- Returning to Now Playing reuses the last active item's detail snapshot. A missing snapshot defers its load until after the navigation transition. Recording-navigation guards remain in place.
- Listening Map episode-file hashing runs on a worker instead of the main actor.

This is the prioritized shared-bottleneck repair from the audit, not a complete storage/observation architecture rewrite. Remaining audit paths include main-actor import/attachment/export projections, shared SQLite lock contention, some full-source startup work, and broad non-diagnostic playback observation. A cache-miss detail refresh still performs synchronous work after the transition. No physical navigation-latency or memory-reduction measurement is claimed.

## Failure found by focused tests

The first run failed: one asynchronous test setup raced unrelated startup work, and the diagnostic test's teardown aborted in `ImportedMarginRemoteControls`' isolated deinitializer on iOS 18.6. The owner supplied the matching simulator report (incident B03D9FB6-7A79-4068-86B7-57856095F6B3; test process 35376). This is SIGABRT/invalid free, not the earlier physical-phone out-of-memory termination.

The stack matches the Swift project's isolated-deinit back-deployment report: https://github.com/swiftlang/swift/issues/85663 . The implementation now owns registrations in a non-actor cleanup holder, removing the isolated-deinit call. Normal transport end still cleans synchronously; fallback destruction removes its registrations on the main queue, with metadata ownership checks preventing it from clearing a newer received-Margin owner's metadata. The stale-navigation regression now controls when its read completes rather than relying on sleep timing.

`focused.log` and `focused.xcresult` remain failed evidence. No passing retry retroactively changes that result.

## Verification

Corrected final-source run: **50 selected tests passed, zero failures/skips**, all expected cases reconciled, on iPhone SE (3rd generation) simulator / iOS 18.6. App/test compilation also passed. Evidence: `focused-final.log`, `focused-final.xcresult`, `test-results.json`. The real bundled-model synthesis canary is intentionally excluded by AppBehavior and was not run. Diff whitespace and test inventory checks passed. Only affected preparation/speech and selected navigation/recording regressions were requested; no full app suite, broad UI suite, release gate or physical-device performance run.

## Owner check

Target the reported iPhone 14 and your local-build phone. Project supports iOS 18+; focused simulator evidence does not establish responsiveness on physical hardware. Record actual device OS and exact installation source, since this candidate still displays build 27.

No reset or new seeded data. Keep the original PDF, Library and Margins. In the new local candidate:

1. Open the PDF Timeline while Supertonic is preparing audio. Tap Back repeatedly across normal chunk progress; verify an immediate response and uninterrupted, correctly positioned audio.
2. Return Home and switch Library/Margins/Now Playing during preparation. Confirm current progress and queue counts remain correct.
3. Repeat at render completion. Note whether any remaining hitch occurs specifically at 100%.
4. Exercise a shared Margin and return to source playback; check remote play/pause ownership.
5. Keep existing recording guards: navigation remains intentionally locked while recording or editing a written Margin.

Pass/fail remains pending for each physical flow. If a freeze persists, capture one Xcode main-thread trace with the exact action/time. Existing Developer diagnostic recording captures progress/worker/power/thermal state and main-loop delays, but not RAM. Avoid repeated full-suite runs; full release verification remains required before a future internal TestFlight push.
