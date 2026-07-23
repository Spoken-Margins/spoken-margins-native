# Supertonic 3 automated verification

Status: `verified` for the automated evidence below. Physical-device performance
and voice/listening quality are not `human_validated`.

Build under test: Spoken Margins 0.1 (6), branch `codex/supertonic-tts`, based on
commit `61b4f0c` plus the feature working tree.

## Verified

- Asset manifest validation: 22 payload files matched pinned sizes and SHA-256
  values; each payload resolves to a source and version. The approved Sherpa
  archive SHA-256 and Supertonic model revision are enforced by the validator.
- SessionKit: 114 tests passed, including Supertonic asset structure, canonical
  voice IDs, renderer input rejection, and exclusive remote-command ownership
  across the speech/media route boundary.
- App unit/integration tests: 97 tests passed across a 96-test app run and the
  separately signed Keychain entitlement test. The app run included 11
  Supertonic tests; no in-scope test was skipped.
- App-focused tests: James/M2 and Lily/F2 produced finite, non-silent 44.1 kHz
  WAV output. Both renders used one runtime load, demonstrating reuse of the
  four ONNX sessions.
- App-focused tests also passed for selectable voice mapping, migration,
  sentence/comma/whitespace chunk priority, source offsets, one-chunk prefetch,
  generation-token cancellation, malformed audio, system fallback offset, and
  voice-switch stop/no-auto-resume behavior.
- Transport tests verified that rate changes reuse the rendered WAV and leave
  synthesis fixed at 1.0, pause wins while an initial render is pending, a
  media-services reset retains the current chunk for explicit resume, and the
  presentation and conservative recovery offsets remain distinct.
- Live native speech now publishes playback-rate commands through the same
  compact-control contract as app controls. The routed audio client disables
  dormant media remote-command handlers while speech owns playback, preventing
  two command handlers from acting on one Lock Screen event.
- XcodeGen generation, generic iOS Simulator build, generic iOS device build,
  Release archive, App Store export, and release-testing thinned export passed.

## App thinning size report

- iPhone variant: 135.4 MB compressed, 175.4 MB uncompressed.
- iPad variant: 135.4 MB compressed, 175.4 MB uncompressed.
- Universal: 136.2 MB compressed, 176.3 MB uncompressed.
- Bundled `Supertonic` resource payload before package compression: 141.21 MiB.

## Still pending product-owner validation

- Cold/warm first-audio and sustained real-time-factor targets on the phone that
  struggled with Kokoro.
- Memory trend across 100 chunks, 30-minute foreground/background narration,
  thermal behavior, interruptions, lock-screen controls, and AirPods routing.
- James and Lily voice quality and the complete listening flow.
- App Store release is blocked until legal/product-owner review confirms the
  versioned Spoken Margins Terms and affirmative acceptance flow satisfy the
  OpenRAIL-M downstream-agreement requirement, and focused automated evidence
  verifies that Supertonic cannot initialize before acceptance.
