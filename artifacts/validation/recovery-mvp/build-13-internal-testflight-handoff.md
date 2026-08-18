# Build 13 Internal TestFlight Handoff

- Version/build: 0.1 (13)
- Source state: uncommitted working tree based on `0508e5e`; replace this line with the candidate commit SHA before upload
- Supported devices: iPhone and iPad on iOS/iPadOS 18.0 or later
- Automated test runtime: iPhone 16 Pro Simulator, iOS 18.6

## In Scope

- truthful, non-scrubbable Apple Now Playing metadata for live native-text narration
- Play/Pause and 15-second native-text Lock Screen interval controls
- immediate **Choose Episode** presentation for ambiguous podcast imports
- the previously human-validated native-text background-start and Spotify seek checks

## Out of Scope

- arbitrary Lock Screen scrubbing for live native text; tracked post-MVP in GitHub issue #64
- closure of the intermittent Spotify seek investigation in GitHub issue #63
- watchOS; this generated project contains no Watch target or scheme

## Known Issues

- Live native text intentionally has no Apple Now Playing duration/scrubber until prepared-audio work lands.
- The Spotify seek symptom remains unreplicated rather than proven impossible.

## Reset and Seed

- For a clean TestFlight run, delete Spoken Margins and reinstall build 13. A clean library loads the bundled **Welcome to Spoken Margins** sample.
- Add a native-text item longer than five minutes by pasting repeated prose through **Add Source**.
- Use a known ambiguous Spotify episode URL for the candidate-picker check.

## Diagnostics

- In the app: **Settings → Copy Privacy-Safe Diagnostics**.
- Attach the copied diagnostics and exact device/OS to any failed checklist item.

## Verification Summary

- 210 `SpokenMarginsAppTests`: pass
- focused iOS 18.6 system playback-control UI test: pass
- focused iOS 18.6 immediate candidate-picker UI test: pass
- contract and surface-contract validators: pass
- `SessionKit` test build: pass
- generic iOS Simulator build: pass
- signed generic iOS device build: pass
- Release archive and local App Store Connect export: pass; Apple Distribution signing, Store provisioning, and `beta-reports-active` confirmed
- generated app reports `CFBundleVersion` 13

## Product-Owner Checklist

1. Native text >5 minutes: Lock Screen has no false short timeline or unusable scrubber; Play/Pause and ±15-second controls remain visible. Pass / Fail: ___
2. Use each Lock Screen transport control and unlock: app state remains synchronized. Pass / Fail: ___
3. Ambiguous Spotify URL: **Choose Episode** appears immediately on the first attempt. Pass / Fail: ___
4. Select a candidate: the selected episode imports and starts without beginning another import. Pass / Fail: ___

Record the completed checklist and device details beside this file after validation.
