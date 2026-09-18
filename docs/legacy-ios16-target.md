# Retired iOS 16.7 Legacy App

## Decision

The product owner retired `SpokenMarginsLegacy` on 2026-08-10 after the final intended user obtained a device capable of running the normal app.

The legacy application, Share extension, Safari extension, targets, and scheme are no longer part of the generated Xcode project or supported validation matrix. At retirement, the supported app was `SpokenMarginsApp` on iOS 18+. The September 16, 2026 platform decision subsequently raised its minimum to iOS/iPadOS 26; see `release-lanes.md`.

## Consequences

- Do not create or distribute new legacy builds.
- Do not require normal/legacy isolation or iPhone 8 validation for release gates.
- Close the legacy TestFlight validation tracker as intentionally retired, not as human-validated parity.
- Existing installed legacy builds receive no further fixes or compatibility promises.
- Historical source and validation evidence remain available through Git history and existing artifacts.

## Former Identifiers

The retired surfaces used:

- app: `com.spokenmargins.native.legacy`
- Share extension: `com.spokenmargins.native.legacy.share`
- Safari extension: `com.spokenmargins.native.legacy.browsertext`
- URL scheme: `spokenmargins-legacy`
- App Group: `group.com.spokenmargins.native.legacy`
