# TestFlight Device Recheck

- Date: 2026-08-18
- Reporter: product owner
- Installed build number: not supplied in this report
- Installed commit SHA: not supplied in this report
- Device and OS: not supplied in this report
- Candidate context: the local investigation used project build 12 at commit `0508e5e`; this is not proof that the same binary was installed on the reporting device.

## State Rules

This record preserves only the bounded device results the product owner directly reported. A passing startup or seek check does not validate a different lock-screen transport property, and a successful recovery does not erase the UX defect that delayed the recovery prompt.

## Human-Validated Results

1. **PASS / `human_validated` — Spotify podcast seek behavior.** The product owner could not reproduce the reported rewind/fast-forward problem with Spotify episodes. This is device evidence against the intermittent symptom tracked in GitHub issue #63; it does not prove every readiness transition or satisfy unrun diagnostic criteria.
2. **PASS / `human_validated` — native-text background startup.** The product owner accepted checklist item 2 from the focused handoff. This result covers narration starting across the background/lock transition, not the accuracy or interactivity of Apple Now Playing's timeline.

## Native-Text Lock-Screen Timeline: Fail

The product owner reported that a native-text narration with at least five minutes of playback was represented by Apple Now Playing as roughly one-minute segments and that the Lock Screen did not allow scrubbing.

This flow is **not `human_validated`**. Source inspection explains the observed behavior:

- the native-text playback snapshot carries text offsets but no `currentMediaTimeMs` or `currentPlaybackDurationMs`;
- the Now Playing publisher substitutes a 100-second duration and treats the 0–100 progress percentage as elapsed seconds when those media values are absent;
- `seekToMediaTime` is intentionally exposed only for transcript-backed or browser-owned media, so Apple's change-playback-position command is disabled for native text.

The prior fallback made the Lock Screen card visible, but it does not model a long native-text narration truthfully. Remediation needs one canonical, monotonically advancing time model for the whole native-text target and an explicit mapping from a Lock Screen time seek back to the canonical text/rendered-audio position. A cosmetic duration substitution alone would make the display look correct while leaving seeks unsafe.

This finding overlaps the native-text Lock Screen scope of GitHub issue #62, but it is more specific than that issue's original desynchronization reproduction: the current defect is an incorrect synthetic duration and unavailable scrubbing from the outset.

## Delayed Podcast Episode Picker: Fail

The first Spotify episode import failed to resolve automatically. After the product owner began importing a different podcast, the app finally presented the earlier failed import's episode-selection sheet. Selecting the intended episode then imported and played it successfully.

The recovery mechanism itself is useful, but its presentation timing is a **FAIL / not `human_validated`**. The picker should appear as soon as the resolver returns multiple playable candidates, before a later import can begin.

Source inspection identifies a presentation-topology failure: the Add Source flow is already displayed as a sheet, while the candidate-review sheet is attached to the root view. Setting the review state while Add Source remains presented queues or hides the second sheet; a later successful import dismisses Add Source and exposes the stale review. This is separate from issue #63's playback-readiness/seek scope and should not prevent that seek investigation from being resolved independently.

## Current Product-Owner Result

- Focused checklist items 1 and 2: **PASS / `human_validated`** as reported.
- Spotify rewind/fast-forward symptom: **not reproduced on the reporting device**.
- Native-text Lock Screen duration and scrubbing: **FAIL**.
- Ambiguous Spotify episode recovery: selection and playback work, but immediate presentation **FAILS**.

## Build 13 Remediation

The build 13 working tree implements the bounded MVP response to these failures:

- live native-text narration no longer publishes invented elapsed time or duration to Apple Now Playing;
- native-text Now Playing retains Play/Pause and 15-second interval controls but does not advertise an unsupported arbitrary-position seek or previous/next-track commands;
- durable prepared native-text audio and arbitrary Lock Screen scrubbing remain post-MVP work in GitHub issue #64;
- an ambiguous podcast result now replaces the existing Add Source sheet with **Choose Episode** immediately, instead of competing with it as a second root sheet.

Automated evidence: 210 app tests passed; the iOS 18.6 Simulator passed focused system-playback-surface and immediate-candidate-picker UI tests; contract validators, surface validators, the SessionKit test build, the generic iOS Simulator build, the signed generic iOS device build, and an Apple Distribution-signed App Store Connect export passed. These results are `verified`, not `human_validated`.

## Next Validation Boundary

After build 13 is committed and uploaded, the shortest device recheck is:

1. Start a native-text item longer than five minutes and lock the phone. Confirm Now Playing does not show the false one-minute/100-second timeline or an unusable scrubber, and that Play/Pause plus 15-second back/forward controls remain visible.
2. Use Play/Pause and both interval controls from the Lock Screen, then unlock and confirm the app remains synchronized.
3. Import a Spotify episode that resolves ambiguously. Confirm **Choose Episode** appears immediately on the first attempt, select a candidate, and confirm that exact episode starts without initiating another import.

Full-duration native-text scrubbing is explicitly out of scope for this MVP recheck.

## Build 13 Product-Owner Result

On 2026-08-18, the product owner reported that all four build 13 handoff checks passed. The remediated native-text Lock Screen controls, app synchronization, immediate ambiguous-episode picker, and selected-episode import/start flow are therefore **PASS / `human_validated`**. The device and OS version were not supplied with this result. This acceptance does not expand MVP scope to arbitrary native-text Lock Screen scrubbing.
