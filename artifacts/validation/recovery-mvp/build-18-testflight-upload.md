# Build 18 Internal TestFlight Upload Receipt

- Date: 2026-08-20
- Version/build: 0.1 (18)
- Candidate commit SHA: `a867fbb`
- Product-owner validation: native-text locked playback and related build-17 fixes reported validated on 2026-08-20

## Release Scope

Build 18 preserves continuous full-item Supertonic generation and cached prepared audio while pacing ONNX inference only when the app is inactive or backgrounded. The pacing addresses the iOS sustained-CPU termination observed in build 17 without introducing system-voice fallback or stopping generation.

## Verification And Distribution Evidence

- Contract and surface-contract validators: pass
- `SessionKit` package tests: 149 pass, 0 failures
- Focused app workflow and Supertonic tests: 79 pass, 0 failures
- Generic iOS device build: pass
- Release archive: pass
- Archived identity: `com.spokenmargins.native`, version 0.1 (18), arm64, iOS 18.0 minimum
- App and embedded `onnxruntime.framework` strict signature verification: pass
- App and embedded-framework minimum OS metadata: iOS 18.0
- Xcode upload: succeeded
- App Store Connect processing: complete
- Internal group: **Margins**
- Internal testers with access shown by App Store Connect: 6
- Build expiration shown by App Store Connect: 90 days
- Distribution confirmation: App Store Connect reported an internal tester had already installed version 0.1 (18)

Xcode emitted the known non-blocking symbol-upload warning because the upstream `onnxruntime.framework` package does not include a matching dSYM for Xcode's injected stub binary. App Store Connect accepted and completed processing for the build despite that warning.

Apple continues to display an updated Developer Program License Agreement requiring Account Holder review. It did not block this internal TestFlight upload or distribution, but may block a later App Store submission until accepted.
