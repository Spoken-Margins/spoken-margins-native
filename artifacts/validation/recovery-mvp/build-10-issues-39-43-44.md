# Recovery MVP Issues 39, 43, and 44

- Date: 2026-07-28
- Candidate version: 0.1 (build 10)
- Base commit: `45857351e51e87c953cccd0a266707d03e50867d`
- Candidate state: committed, archived, and exported locally on `codex/issue-38-article-shortcut`; not uploaded
- Implementation state: `implemented`
- Automated evidence state: `verified`
- Product-owner state: issues 39 and 44 `human_validated` on 2026-08-03; issue 43 not yet `human_validated`

## In scope

- Issue 39: automatically dismiss the delete Undo toast after five seconds while safely cancelling or replacing its timer.
- Issue 43: use `SessionEngine` as the canonical AI-response playback-state owner; publish that state to in-app, Now Playing, compact-control, and Live Activity surfaces; explicitly clean up Live Activities when the session or application terminates; remove orphaned activities during launch/foreground reconciliation.
- Issue 44: import text-based PDFs without replacing the active playback engine, selected item, playback position, rate, or play/pause state.

## Out of scope

- Toast visual redesign.
- OCR for image-only PDFs.
- Guaranteed server-side Live Activity termination after the process is already unavailable.
- Product-owner acceptance of Lock Screen, Control Center, route-change, interruption, or audible-continuity behavior on physical hardware.

## Supported validation targets

- Project deployment target: iOS 18.0.
- iPhone and iPad are targeted by the app configuration.
- Automated app regressions ran on an iPhone 16 Pro simulator with iOS 18.6.
- The app and embedded extensions built for a generic iOS device.

## Automated verification

Passed:

- `./scripts/bootstrap-python-tools.sh`
- `.venv/bin/python scripts/validate-contracts.py`
- `.venv/bin/python scripts/validate-surface-contracts.py`
- `swift build --build-tests --package-path Packages/SessionKit`
- `swift test --package-path Packages/SessionKit` — 126 tests, 0 failures.
- `xcodebuild` SpokenMarginsApp generic iOS Simulator build.
- `xcodebuild` SpokenMarginsApp generic iOS device build.
- `xcodebuild` SpokenMarginsLegacy Release generic iOS device build.
- Eight focused iOS simulator regressions covering PDF playback preservation, responsive import controls, Undo dismissal/replacement, AI-response cross-surface play/pause, native Now Playing eligibility, termination cleanup routing, and orphan policy — 8 tests, 0 failures.
- Normal and legacy Release archives and non-uploading App Store Connect exports.
- Strict signing verification for both exported main apps and all five embedded extensions.
- Every exported bundle reports version `0.1`, build `10`, the expected bundle identifier and App Group, Apple Distribution signing, `get-task-allow = false`, and `beta-reports-active = true`.

Exact IPA identities and the release checklist are recorded in
[`artifacts/validation/testflight-external/build-10/README.md`](../testflight-external/build-10/README.md).

The repository instructions name a `SpokenMarginsWatch` scheme, but the generated project does not contain that scheme. No Watch build claim is made.

## Known limitations and falsification checks

- iOS does not guarantee that `UIApplication.willTerminateNotification` is delivered when a suspended app is force-quit. The implementation performs best-effort immediate cleanup when termination is delivered and ends orphaned Live Activities on the next launch. Physical-device validation must check both the immediate and next-launch cases.
- Simulator checks prove state propagation and cleanup routing, not audible continuity or actual Lock Screen/Control Center presentation.
- A broader app-test selection exposed pre-existing persistent `UserDefaults`/SQLite test-order pollution. The eight focused regressions pass in isolation; the broad suite is not claimed green.
- To falsify Issue 44, record session id, target id, playback time, rate, and status before PDF selection and compare them immediately after import finishes.
- To falsify Issue 43, pause from each external surface and verify the in-app button changes without navigation; then resume in-app and verify every external surface changes. Repeat after an interruption, route change, background/foreground transition, session close, force-quit, and relaunch.
- To falsify Issue 39, dismiss, undo, and replace the toast before five seconds; an older timer must never dismiss the replacement toast.

## Reset and seeded data

- For a clean product pass, delete the installed build and install build 10.
- The app seeds the “Welcome to Spoken Margins” sample into a new empty library.
- Import one text-based PDF and one playable public podcast or direct-audio URL before testing.
- Privacy-safe diagnostics are available from the app's diagnostics export.

## Product-owner evidence

On 2026-08-03, the product owner reported that issues 39 and 44 had been used and accepted. This direct report advances those two flows from `verified` to `human_validated`. No additional device, OS, or diagnostics details were supplied in the report, so this artifact does not invent them. Issue 43 remains pending.

## Product-owner checklist

- [x] Issue 44: native audio remains audible while a PDF imports.
- [x] Issue 44: PDF import flow accepted by the product owner.
- [ ] Issue 43: AI-response controls appear in Lock Screen and Control Center where supported.
- [ ] Issue 43: external pause immediately changes the in-app control to Play.
- [ ] Issue 43: in-app resume immediately updates external surfaces.
- [ ] Issue 43: interruption, route change, background, and foreground state remain synchronized.
- [ ] Issue 43: closing the session ends its Live Activity.
- [ ] Issue 43: termination does not leave a stale Live Activity, or relaunch removes any orphan that iOS retained.
- [x] Issue 39: Undo disappears after approximately five seconds.
- [x] Issue 39: delete-toast MVP flow accepted by the product owner.

Record device, OS, build, exact pass/fail notes, diagnostics location, and any residual issue before changing any item to `human_validated`.
