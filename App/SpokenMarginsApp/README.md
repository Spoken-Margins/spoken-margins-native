# SpokenMarginsApp Gate 1 Scaffold

This directory contains the SwiftUI source scaffold for the Gate 1 phone/tablet app target.

The app target is generated from `project.yml` using XcodeGen and links the local `SessionKit` package. It should:

- link `Packages/SessionKit`
- use `SessionKitPersistence.SQLiteSessionStore` for local state
- use `SessionKitAudio.SystemSpeechPlaybackClient` and `SystemRecordingClient` on device
- use `SessionKitAI.FixtureAIProvider` in tests; the app itself calls no AI provider directly and uses only the on-device model (the opt-in "Help make listening maps" upload goes to the Spoken Margins server, which drafts maps)
- bundle `Contracts/fixtures` as development seed data

Build the simulator app without signing:

```bash
xcodegen generate
xcodebuild -project SpokenMarginsNative.xcodeproj -scheme SpokenMarginsApp -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

Gate 1 cannot be submitted for product-owner validation until this target is signed for an installable iPhone/iPad build and the validation checklist in `Resources/Gate1ValidationChecklist.md` is complete.
