# Build 14 TestFlight Upload Receipt

- Date: 2026-08-18
- Version/build: 0.1 (14)
- Candidate commit SHA: `3f8eb5e`
- Product behavior source: build 13 commit `596bdce`
- Product-owner validation: all build 13 handoff checks reported pass on 2026-08-18

## Packaging Replacement

Build 13 uploaded successfully but failed App Store Connect processing with `90208: Invalid Bundle` because the embedded `onnxruntime.framework` Info.plist declared iOS 15.1 while Xcode's injected framework binary required iOS 18.0.

Build 14 changes only distribution packaging metadata and the build number. Its archive and exported IPA declare iOS 18.0 for both the app and `onnxruntime.framework`, matching the framework binary's `LC_BUILD_VERSION` minimum.

## Verification and Distribution Evidence

- Release archive: pass
- App Store Connect export: pass
- Apple Distribution certificate and Store provisioning: confirmed
- Exported app build number: 14
- App, embedded-framework plist, and framework binary minimum OS: 18.0
- Xcode upload: succeeded
- App Store Connect build processing: completed; build detail available
- Internal group: **Margins**
- Group type: **Internal**
- Testers with access shown by App Store Connect: 6
- Expiration shown by App Store Connect: 90 days

Xcode emitted a non-blocking symbol-upload warning because the upstream `onnxruntime.framework` package does not include a matching dSYM for Xcode's injected stub binary. App Store Connect accepted the build despite that warning.

Apple also displayed an updated Developer Program License Agreement requiring Account Holder review. It did not block this TestFlight upload or internal group assignment, but may block later app updates or submissions until accepted.
