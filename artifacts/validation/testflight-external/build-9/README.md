# TestFlight build 9 release handoff

Prepared and uploaded on July 24, 2026.

## Build identity

- Marketing version: `0.1`
- Build number: `9`
- Source baseline: `da04bb9251359fa7df116639c149e1079c005c3f`
- Working-tree release changes: build number `8` to `9` in `project.yml`
  and the generated Xcode project, plus
  `Config/ExportOptions-AppStoreUpload.plist`
- State: `verified` and uploaded; not `human_validated`

The source baseline identifies the implementation content in both builds. The
release-setting changes above were not committed before archiving. The IPA
digests below are the exact artifact identities.

## Uploaded artifacts

### Normal app

- App: `Spoken Margins`
- Main bundle: `com.spokenmargins.native`
- Embedded bundles: `com.spokenmargins.native.gate2widget`,
  `com.spokenmargins.native.share`, and
  `com.spokenmargins.native.browsertext`
- Supported devices: iPhone and iPad
- Minimum OS: iOS/iPadOS 18.0
- IPA: `artifacts/releases/build-9/normal-export/SpokenMarginsApp.ipa`
- SHA-256:
  `d35f2f916ea8a93555a0df59032aa8217fbb7385a31ef180dd081ebe161d162e`
- App Store Connect receipt: upload succeeded at 13:22 EDT; Apple reported
  that the package was processing

### Legacy app

- App: `SpokenMarginsLegacy`
- Main bundle: `com.spokenmargins.native.legacy`
- Embedded bundles: `com.spokenmargins.native.legacy.share` and
  `com.spokenmargins.native.legacy.browsertext`
- App Group: `group.com.spokenmargins.native.legacy`
- Supported devices: iPhone only
- Minimum OS: iOS 16.7
- IPA: `artifacts/releases/build-9/legacy-export/SpokenMarginsLegacy.ipa`
- SHA-256:
  `6fc671bf6f6b9f04cbf0ebaa72048e2693439643c3b607f60172000bef55ad2e`
- App Store Connect receipt: upload succeeded at 13:18 EDT; Apple reported
  that the package was processing

## Verification summary

- `validate-contracts.py`: passed
- `validate-surface-contracts.py`: passed
- `swift build --build-tests --package-path Packages/SessionKit`: passed
- Normal Release archive: succeeded
- Legacy Release archive: succeeded
- Normal App Store Connect export: succeeded
- Legacy App Store Connect export: succeeded
- All seven exported bundles report version `0.1` build `9`
- Normal app and extensions use App Group `group.com.spokenmargins.native`
- Legacy app and extensions use App Group
  `group.com.spokenmargins.native.legacy`
- Every exported bundle contains an App Store provisioning profile,
  `beta-reports-active = true`, and `get-task-allow = false`
- Both uploads passed App Store Connect package and SPI analysis and received
  an upload-success receipt

Automated evidence verifies compilation, packaging, signing, and delivery. It
does not validate the product flows or prove that App Store Connect processing
has completed.

## In scope

- Normal build 9: the current iPhone/iPad app, Widget/Live Activity extension,
  Share extension, and Safari Web Extension
- Legacy build 9: the iOS 16.7 iPhone compatibility app, Share extension, and
  Safari Web Extension
- Separate app identities and App Groups so both apps can be installed without
  sharing library or handoff state

## Out of scope and known limitations

- The legacy app has no custom interactive Live Activity, Watch integration,
  iPad support, or Kokoro/MLX device build
- The legacy target is not feature-parity coverage for future normal-app work
- No product flow in either build was human validated during this release task
- App Store Connect processing, export-compliance prompts, tester-group
  assignment, and external Beta App Review remain Apple/owner-side states
- Issue #28 remains the decision point for reviewer access to optional BYO-key
  AI features if either app is submitted for external Beta App Review

## Reset, sample data, and diagnostics

- Reset either app by deleting that app and reinstalling it from TestFlight.
  Because the apps use separate App Groups, reset and validation must be done
  independently for each app.
- Seeded sample: `Welcome to Spoken Margins` appears on a fresh empty install.
- Diagnostics: Settings → Support & Privacy → Copy Privacy-Safe Diagnostics.
- Never attach API keys, private source text, transcripts, private URLs, or
  personal file paths to validation evidence.

## Product-owner checklist

Record device, OS, pass/fail, notes, and diagnostics for each line.

### App Store Connect

- [ ] Both build 9 uploads finish processing without Apple warnings or errors.
- [ ] The normal build appears under the existing Spoken Margins TestFlight
  app and is assigned to the intended internal tester group.
- [ ] The legacy build appears under the legacy TestFlight app and is assigned
  to the intended internal tester group.
- [ ] Export-compliance and test-information prompts are completed accurately
  for each app.

### Legacy iPhone flow

- [ ] Install and launch on an iPhone 8 running iOS 16.7.x.
- [ ] Import an article through the Share extension.
- [ ] Import a page through the Safari extension.
- [ ] Play an article with an installed system voice.
- [ ] Play an article with a bundled Supertonic voice.
- [ ] Play a podcast or prepared-audio item and verify lock-screen play/pause
  and seeking.
- [ ] Record an interjection and verify the expected response/handoff path.
- [ ] Relaunch and confirm library and playback-position recovery.
- [ ] Install the normal and legacy apps together and confirm their libraries
  and handoff queues remain isolated.

### Normal app regression smoke test

- [ ] Install build 9 on a supported iPhone and launch the seeded sample.
- [ ] Import and play one article and one podcast.
- [ ] Verify Share and Safari extension intake.
- [ ] Verify lock-screen controls and the Live Activity surface.
- [ ] Relaunch and confirm library and playback-position recovery.

Do not mark either build `human_validated` until the product owner records and
accepts the corresponding checklist evidence.
