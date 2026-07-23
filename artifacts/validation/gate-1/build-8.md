# Gate 1 human validation — version 0.1 build 8

## Build identity

- Date recorded: July 23, 2026
- Marketing version: `0.1`
- Build number: `8`
- Implementation commit: `bf36447` (`Add batch session Markdown export`)
- Source branch: `codex/supertonic-tts`
- Supported devices: iPhone and iPad
- Minimum OS: iOS/iPadOS 18.0
- App Store Connect state: the product owner confirmed build 8 had never been uploaded as of this record.

## Validation state

- `implemented`: the current app flows and batch Markdown session export are present in the implementation commit above.
- `verified`: the automated release gate below passed on the implementation commit's working tree before commit.
- `human_validated`: **PASS — the product owner reported that they validated everything on their phone and accepted the build.**

## Product-owner evidence

On July 23, 2026, the product owner stated in the release task: “I just validated everything on my phone, so this is now human validated.” No failures or known product issues were reported.

The device model, OS version, and per-flow pass/fail notes were not supplied. This record preserves the scope and wording of the product owner's acceptance without inventing more granular evidence.

## Automated verification

Run on July 23, 2026 from the implementation working tree:

- [x] `python3 scripts/validate-contracts.py` — passed; 22 Supertonic files validated.
- [x] `python3 scripts/validate-surface-contracts.py` — passed.
- [x] `swift test --package-path Packages/SessionKit` — 123 tests passed.
- [x] `xcodebuild -project SpokenMarginsNative.xcodeproj -scheme SpokenMarginsApp -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=18.6' test | xcbeautify` — 117 app tests and 9 UI tests passed.

The Xcode run emitted repeated `DebuggerLLDB.DebuggerVersionStore.StoreError` launch-metadata warnings, but returned exit status 0 and all XCTest suites passed.

## Scope and evidence limits

- In scope: the complete version 0.1 build 8 app as exercised and accepted by the product owner, plus the automated contract, SessionKit, app, and UI routes listed above.
- Out of scope: App Store Connect upload/processing, TestFlight installation by another internal tester, and any device/OS combination not explicitly reported.
- Known issues reported during human validation: none.
- Evidence gap: the product owner did not provide device model, OS version, diagnostics export, or granular checklist notes.

## Reset, samples, and diagnostics

- Reset: delete the TestFlight app and reinstall it; remove any saved API key in Settings first when credential removal must also be verified.
- Seeded sample: `Welcome to Spoken Margins` appears on a fresh empty install.
- Diagnostics: Settings → Support & Privacy → Copy Privacy-Safe Diagnostics.

## Internal TestFlight follow-up

- [ ] Archive version 0.1 build 8 from merged `main` with App Store distribution signing.
- [ ] Upload build 8 to App Store Connect and wait for processing.
- [ ] Confirm all embedded bundles report build 8 and distribution entitlements are valid.
- [ ] Add the processed build to the internal TestFlight group.
- [ ] Confirm at least one internal tester can install and launch it.
