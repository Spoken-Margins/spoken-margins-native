# TestFlight build 10 release handoff

Prepared locally on July 28, 2026. This candidate has not been uploaded.

## Build identity

- Marketing version: `0.1`
- Build number: `10`
- Source baseline: `45857351e51e87c953cccd0a266707d03e50867d`
- Branch: `codex/issue-38-article-shortcut`
- State: `verified` and exported locally; not uploaded and not
  `human_validated`

## Local release artifacts

The generated archives and exports are intentionally kept under the ignored
`.build/` directory. The SHA-256 digests identify the exact candidate files.

### Normal app

- App: `Spoken Margins`
- Main bundle: `com.spokenmargins.native`
- Embedded bundles: `com.spokenmargins.native.gate2widget`,
  `com.spokenmargins.native.share`, and
  `com.spokenmargins.native.browsertext`
- App Group: `group.com.spokenmargins.native`
- Supported devices: iPhone and iPad
- Minimum OS: iOS/iPadOS 18.0
- Archive:
  `.build/release-artifacts/build-10/SpokenMargins-0.1-10.xcarchive`
- IPA:
  `.build/release-artifacts/build-10/normal-export/SpokenMarginsApp.ipa`
- IPA size: 139,951,464 bytes
- SHA-256:
  `e150a013c41620ad636689f1c6e5027ab086abe96be2d506af46101aa0094958`

### Legacy app

- App: `SpokenMarginsLegacy`
- Main bundle: `com.spokenmargins.native.legacy`
- Embedded bundles: `com.spokenmargins.native.legacy.share` and
  `com.spokenmargins.native.legacy.browsertext`
- App Group: `group.com.spokenmargins.native.legacy`
- Supported devices: iPhone
- Minimum OS: iOS 16.7
- Archive:
  `.build/release-artifacts/build-10/SpokenMarginsLegacy-0.1-10.xcarchive`
- IPA:
  `.build/release-artifacts/build-10/legacy-export/SpokenMarginsLegacy.ipa`
- IPA size: 138,891,755 bytes
- SHA-256:
  `d28eac468f8da3f64c4dbd73096f2793676098243b2853e9acc19c42c60a7757`

## In scope

- Issue 38: Safari article-shortcut import, already `human_validated` by the
  product owner before this build was prepared.
- Issue 39: five-second, cancellable Undo-toast dismissal.
- Issue 43: one canonical `SessionEngine` playback-state owner for streamed
  AI responses, synchronized with in-app controls, Now Playing, compact
  controls, and Live Activities.
- Issue 44: PDF import that preserves the active playback engine, selected
  item, position, rate, and play/pause state.
- Normal and legacy Release packaging and signing.

## Out of scope and known limitations

- Issues 39 and 44 were `human_validated` by the product owner on 2026-08-03. Issue 43 is not yet `human_validated`.
- OCR for image-only PDFs is not implemented.
- iOS does not guarantee delivery of the termination notification after a
  force-quit. Live Activity cleanup is best-effort at termination and is also
  reconciled on the next launch.
- Physical-device audible continuity, route changes, interruptions, Lock
  Screen presentation, and Control Center presentation require product-owner
  testing.
- A broader app-test selection exposed pre-existing persistent
  `UserDefaults`/SQLite test-order pollution. The eight focused regressions for
  these fixes pass in isolation; the broad suite is not claimed green.
- The generated project does not contain the repository-documented
  `SpokenMarginsWatch` scheme, so no Watch build claim is made.
- App Store Connect upload, processing, compliance answers, tester assignment,
  and Beta App Review remain pending.

## Verification summary

Passed against the build-10 source baseline:

- `./scripts/bootstrap-python-tools.sh`
- `.venv/bin/python scripts/validate-contracts.py`
- `.venv/bin/python scripts/validate-surface-contracts.py`
- `swift build --build-tests --package-path Packages/SessionKit`
- `swift test --package-path Packages/SessionKit` — 126 tests, 0 failures
- Eight focused iOS 18.6 simulator regressions — 8 tests, 0 failures
- Normal Release generic-iOS build
- Legacy Release generic-iOS build
- Normal Release archive and non-uploading App Store Connect export
- Legacy Release archive and non-uploading App Store Connect export
- Strict code-signature verification for both main apps and all five embedded
  extensions
- Every exported bundle reports version `0.1`, build `10`, and the expected
  bundle identifier and App Group
- Every exported bundle uses Apple Distribution signing and a Store profile
  with `get-task-allow = false` and `beta-reports-active = true`

Automated evidence verifies implementation, compilation, packaging, and
signing. It does not validate the product flows or App Store delivery.

## Reset, sample data, and diagnostics

- For a clean pass, delete build 9 and install build 10. Reset the normal and
  legacy apps separately because their App Groups are isolated.
- A fresh empty library seeds `Welcome to Spoken Margins`.
- Before testing, import one text-based PDF and one playable public podcast or
  direct-audio URL.
- Diagnostics: Settings → Support & Privacy → Copy Privacy-Safe Diagnostics.
- Do not attach API keys, private source text, transcripts, private URLs, or
  personal file paths to validation evidence.

## Product-owner checklist

Record device, OS, pass/fail, notes, and diagnostics for every attempted line.

### Candidate installation

- [ ] Upload both build-10 IPAs and confirm App Store Connect processing
  completes without warnings or errors.
- [ ] Assign the normal and legacy builds to the intended tester groups.
- [ ] Install the normal candidate on an iOS/iPadOS 18 device.
- [ ] Install the legacy candidate on an iPhone running iOS 16.7.x.

### Issue 38 preservation

- [x] Safari article-shortcut import was accepted by the product owner before
  candidate preparation.
- [ ] Smoke-test Safari article-shortcut import in the distributed build.

### Issue 44

- [x] Native audio remains audible while a text-based PDF imports.
- [x] The product owner accepted the PDF-import MVP flow on 2026-08-03.

### Issue 43

- [ ] AI-response controls appear on the Lock Screen and in Control Center
  where supported.
- [ ] External pause immediately changes the in-app control to Play.
- [ ] In-app resume immediately updates every external surface.
- [ ] Interruption, route-change, background, and foreground state remain
  synchronized.
- [ ] Closing the session ends its Live Activity.
- [ ] Force-quit leaves no stale Live Activity, or relaunch removes any orphan
  retained by iOS.

### Issue 39

- [x] Undo disappears after approximately five seconds.
- [x] The product owner accepted the delete-toast MVP flow on 2026-08-03.

Do not mark issue 43 `human_validated` until the product owner records and
accepts the corresponding evidence.
