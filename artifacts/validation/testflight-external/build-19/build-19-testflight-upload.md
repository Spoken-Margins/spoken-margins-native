# Build 19 TestFlight Upload Receipt

- Upload date: 2026-08-21
- Marketing version/build: 0.1 (19)
- Commit: `738c743e202f5e700f4d6975adee52862f63c69f`
- Team: `J8SWC6J3VY`
- Bundle: Spoken Margins
- Minimum OS: iOS/iPadOS 18.0
- Non-exempt encryption: false
- Internal-only upload restriction: false
- IPA: `.build/release-artifacts/build-19/export/SpokenMarginsApp.ipa`
- IPA SHA-256: `3b1f3eae0aa142656d6e25dded2d8b8824d29f73362e696cb26d51e2a9b195b2`

## Result

Xcode reported `Upload succeeded` and `EXPORT SUCCEEDED`. App Store Connect
reported the Build 19 upload as `Complete`, then added it automatically to the
internal **Margins** group. The group page reports Build 0.1 (19) as `Testing`
with six internal testers.

## Warning

Symbol upload reported the known missing dSYM for `onnxruntime.framework`
(UUID `E4C434BC-7E2F-3F1B-AA6C-8E5458F874DD`). The application upload and Apple
processing still completed successfully. Treat any later crash-symbolication
problem involving that framework as a known diagnostics limitation.

## Remaining Evidence

An internal tester should install Build 19 from TestFlight and record device,
OS, launch result, and the focused release smoke. Only the product owner may
mark those product flows `human_validated`.
