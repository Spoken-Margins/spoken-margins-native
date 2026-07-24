# iOS 16.7 Legacy App Target

## Purpose

`SpokenMarginsLegacy` is an on-demand compatibility build for iPhone 8. It preserves the broad Spoken Margins MVP without changing the deployment target or bundle identity of the active iOS 18 app.

This target is implemented and build-verified. It is not human-validated on an iPhone 8 until the product owner completes the checklist below.

## Target Boundary

Included:

- article, podcast, share-sheet, Safari, file, Obsidian, and text-based PDF intake paths shared with the current app
- podcast and prepared-audio playback with Now Playing controls
- installed system voices
- bundled Supertonic voices using the ONNX runtime
- OpenAI response and listening-map paths shared with the current app
- separate iOS 16.7 share and Safari extensions

Excluded:

- the custom interactive Live Activity; the legacy controller reports `unavailable_legacy` and continues to publish Now Playing state
- Watch integration and the optional Kokoro/MLX device build
- any promise of feature parity with future changes to the iOS 18 app

## Isolation and Signing

The legacy app uses bundle identifier `com.spokenmargins.native.legacy`, URL scheme `spokenmargins-legacy`, and App Group `group.com.spokenmargins.native.legacy`. Its extensions use the same App Group and their own legacy bundle identifiers. This isolates legacy data and handoff queues from the release app and permits both apps to be installed together.

Before installing on a physical device or distributing with TestFlight, register the three legacy bundle identifiers and legacy App Group with the configured Apple Developer team, then associate the App Group with each identifier. An unsigned generic-device build verifies compilation and packaging but not provisioning.

## Build

Regenerate the Xcode project after editing `project.yml`:

```bash
xcodegen generate
```

Debug simulator builds use an iOS 16.4 deployment target because Apple did not
publish an iOS 16.7 simulator runtime. Device builds and Release simulator builds
remain targeted at iOS 16.7. The `SessionKit` package has a 16.4 compile floor so
the Debug app and both embedded extensions can run on the iPhone 8 simulator.

In Xcode, select the `SpokenMarginsLegacy` scheme and the
`iPhone 8 — iOS 16.4` destination, then use the normal Run action to launch with
debug gauges attached.

Build without signing:

```bash
xcodebuild \
  -project SpokenMarginsNative.xcodeproj \
  -scheme SpokenMarginsLegacy \
  -destination 'generic/platform=iOS' \
  build CODE_SIGNING_ALLOWED=NO | xcbeautify
```

For an iPhone 8, select the `SpokenMarginsLegacy` scheme, choose the connected phone, and use the normal Xcode Run action after provisioning is configured.

## Product-Owner Validation Checklist

- Install and launch on an iPhone 8 running iOS 16.7.x.
- Import one article from the share sheet and one page through the Safari extension.
- Play an article with both a system voice and a Supertonic voice; record startup/buffering time separately from playback failures.
- Play a podcast or prepared-audio item and verify lock-screen play/pause and seeking.
- Interrupt playback with a note and verify the response/handoff path used by the current MVP.
- Relaunch the app and confirm the library and playback position recover.
- Confirm both the release and legacy apps can remain installed without sharing library or handoff state.

Record accepted evidence under the applicable `artifacts/validation/` gate before describing this target as human-validated.
