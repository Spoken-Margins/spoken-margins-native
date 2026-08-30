# Issue 84 media-seek reconvergence verification

Status: `verified` by the automated evidence below. The physical-device flow is
not `human_validated` until the product owner completes the checklist.

Branch under test: `codex/testflight-triage`, based on `b6ea36b` plus this
working tree. No TestFlight build number has been assigned or uploaded by this
implementation pass.

## Failure model

The recurring defect had two independently patched symptoms:

1. During a drag, periodic playback ticks could replace the gesture-owned value
   and dislocate the thumb.
2. After release, the session protected the requested value while AVPlayer was
   still resolving a seek. Treating that navigation seek as a fresh playback
   start could leave the protected value pending or fail the whole transport
   even while audio continued, producing a sticky thumb and frozen labels.

The repaired invariant is: the gesture owns the displayed value only during
editing; after release, a uniquely identified media-seek transaction owns the
requested value until AVPlayer accepts or rejects it; then the player clock is
again canonical and must continue advancing. One bounded AVPlayer retry keeps
the same transaction identity. A rejected navigation seek reconverges to the
observed player time without changing an audibly playing session to `failed`.

## In scope

- Playback-screen scrub gesture ownership for both media and text sliders.
- The shared AVPlayer media route used by remote podcast/audio streams and
  local native or downloaded audio files.
- Session snapshot and persisted media-position reconvergence after an
  accepted or rejected seek.
- Privacy-safe diagnostics containing the seek id, requested time, and
  pending/accepted/failed outcome.
- Production forwarding through `RoutedAudioPlaybackClient`, not only direct
  AVPlayer-client tests.

## Adjacent paths and limits

- Real-time text-to-speech uses character-offset restart/confirmation rather
  than AVPlayer media-time seeking. It shares the scrub gesture ownership code,
  and its existing stale-position-until-confirmation regression tests remain
  green, but it does not use the new media-seek transaction.
- Rendered text that remains on the text playback route follows that same
  character-offset contract. Native media files, including downloaded podcast
  files, use the media transaction.
- Lock Screen metadata is still published from the AVPlayer clock; the package
  test proves the canonical session rejoins that clock, while final Lock Screen
  observation remains a physical-device check.
- No broad UI route, background interruption, network-stall, or physical-device
  validation is claimed by this pass.

## Automated verification

- `swift test --package-path Packages/SessionKit`: 168 tests passed, 0 failed.
- The combined media regression proves: no playback restart; requested value is
  protected while pending; acceptance rejoins multiple advancing player ticks;
  persistence advances with those ticks; and rejection recovers to observed
  player time while status remains playing.
- The routed-client regression proves the transaction crosses the production
  speech/media router and is not acknowledged prematurely at that boundary.
- The lifecycle regression proves a retry retains the original request id and
  navigation purpose and terminates after one retry.
- Focused app test
  `testPlaybackScrubStateKeepsGestureValueAuthoritativeUntilCommit` passed and
  proves gesture ticks cannot dislocate the thumb while editing and canonical
  ticks immediately advance it after release.
- Contract and surface-contract validation passed.
- Generic iOS Simulator and generic iOS device builds passed.

## Diagnostics and reset

- Diagnostics: Settings > Diagnostics > Refresh Diagnostics, then Copy
  Privacy-Safe Diagnostics. Inspect the `mediaSeek` entry for transaction id,
  requested milliseconds, and outcome. It contains no URL or content text.
- Reset if a clean library is needed: Settings > Storage & Testing > Reset
  Library and Load Sample, then confirm Reset Library. This deletes the local
  test library and seeds `Welcome to Spoken Margins`.

## Product-owner checklist

Record Pass or Fail and brief notes for each source type.

- [ ] While a remote podcast/audio stream is playing, drag repeatedly in both
  directions. Confirm the thumb stays under the finger, lands once on release,
  and elapsed/remaining labels continue advancing.
- [ ] Repeat with a fully downloaded podcast or other local native audio file.
- [ ] Repeat after pausing, resuming, changing playback speed, and moving the app
  between foreground and background.
- [ ] Force or encounter a slow/buffered seek. Confirm the UI holds the requested
  location only while the seek is pending, then follows audible playback rather
  than freezing or failing the transport.
- [ ] Scrub real-time text-to-speech and rendered text playback. Confirm the
  percentage remains gesture-owned during the drag and resumes advancing after
  the replacement speech start is confirmed.
- [ ] Check Lock Screen/Control Center during native media seeking and confirm
  elapsed time reconverges with the in-app thumb and audible position.
- [ ] Export privacy-safe diagnostics and attach the `mediaSeek` entry if any
  source type fails.

Product-owner result: Pending.

Product-owner notes: Pending.
