# Sharing-next product-owner validation handoff

Status: `implemented` and `verified`; not `human_validated`.

Branch: `codex/sharing-next`

Implementation commits:

- `f96194a` (`Complete testable one-way sharing experience`)
- `4d3d311` (`Restore schema five library compatibility`)

Local build setting: version 0.1 (21)

Build 21 is already reserved for the accepted hotfix line. This checkout is suitable for a local developer/device build, but a new sharing TestFlight build number must be allocated before upload.

## Supported validation environment

- iPhone or iPad running iOS/iPadOS 18.0 or later.
- The iOS Simulator build is verified, but microphone recording, background podcast download, real ShazamKit matching, and listening experience should be exercised on a physical device.
- Filler and pause cleanup requires word-timed speech recognition for that Margin. New recordings attempt aligned transcription on supported devices; older recordings without word timing remain eligible for original-voice or text-only sharing.

## In-scope flows

- Select active item-level Margins, review and edit their transcripts, and explicitly choose original voice, cleaned voice, or text only for each Margin.
- Preview original and cleaned voice before export; accept or undo each proposed filler/pause edit without modifying the private original recording.
- Export a deterministic `.spokenmargins` archive containing only reviewed Margins, bounded text context, source identity, selected voice files, and optional non-playable acoustic signatures. Podcast audio, full podcast transcripts, unrelated sessions, and diagnostics are excluded.
- Open a `.spokenmargins` file, inspect its integrity-checked unsigned contents, explicitly confirm import, acquire/download the recipient podcast edition without autoplay, and persist it as a distinct Shared Margins layer.
- Resolve podcast anchors as exact-edition or conservatively verified cross-edition placements. Ambiguous, absent, unresolved, and wrong-source Margins remain readable but cannot interrupt playback.
- Use Shared Margins controls per layer: enable/disable, mute cue, Fresh, Companion, Guided, and delete.
- Review imported Margins and provenance in the item screen and Timeline.
- Use **Create Recipient Test Session** after export to exercise the real archive, verification, import, persistence, resolver, and playback route on one device in a distinct session.
- Persist portable Listening Map proposals from the package without activating them.

Reveal modes are intentionally different:

- **Fresh** records that the anchor was crossed but does not reveal or play the imported Margin.
- **Companion** sounds a cue and lets the listener choose whether to listen.
- **Guided** sounds a cue and plays the Margin automatically, then resumes the source when appropriate.

## Out of scope or not yet authorized

- Sharing with another person remains gated by issue #14 rights/provenance acceptance. This handoff authorizes the product owner's own-device validation, not external distribution.
- Sender identity is unsigned and explicitly displayed as unverified.
- Offline phone generation of Listening Maps, proposal activation, chapter/scene summary bridge playback, and Skim controls are not in this MVP.
- Co-op replies, remote revocation, accounts, trust networks, and AI-generated summaries are not implemented here.
- There is no silent timestamp-only fallback. A Margin without sufficient matching evidence remains context-only.

## Known issues and constraints

- High-reliability acoustic evidence can be captured only when the exact podcast edition is already downloaded locally at the time the Margin is recorded. A Margin captured while only a remote stream is available will warn that it cannot be resolved on a different edition.
- A text-only Margin is readable but has no voice playback.
- Automatic cleanup is unavailable for an older Margin without aligned word timing. The sender can still edit its shared transcript and choose original voice or text.
- The benchmark used one held-out public-domain spoken-work pair with synthetic but representative podcast edits. Representative physical-device runtime, battery, and thermal behavior are not yet measured.
- An imported package with the same content digest is idempotent. Reusing **Create Recipient Test Session** starts another session with the existing imported layer rather than duplicating the layer.

## Reset, sample, and diagnostics

- Do not use reset or uninstall as a response to a library-access or schema-version error. Install the compatible build over the existing app first; see `schema-five-library-recovery.md`.
- Remove one imported layer from the item's **Shared Margins** section with **Delete Shared Margins**.
- For a complete DEBUG-build reset, open **Settings → Developer → Developer tools → Reset Library and Load Sample**. Deleting and reinstalling the app also clears the app-owned library and downloaded test media.
- No podcast or voice fixture is committed. The seeded validation sample is the real package you create from your own locally downloaded podcast and Margin; this avoids committing copyrighted podcast audio or private voice.
- In a DEBUG build, open **Settings → Developer → Developer tools**, tap **Refresh Diagnostics**, and inspect `lastSharedPackage`, `lastSpokenMarginsPackageImport`, `podcastAnchorEvidence:<interjection-id>`, and `importedPodcastAnchorResolution:<item-id>`.
- **Settings → Copy Privacy-Safe Diagnostics** provides the shareable diagnostics export.

## Verification summary

- Dedicated held-out benchmark: 232 anchors, 226 eligible and 6 deliberately absent; fused/monotonic placement produced 210 confident eligible placements, zero wrong confident placements, 4 ms p95 error, and declined all 6 absent passages.
- Normal `SharingTests`: 21 passed, 1 dedicated held-out test skipped by design, 0 failed.
- Contract validator: passed.
- Surface contract validator: passed.
- SessionKit build with tests: passed.
- Generic iOS Simulator `SpokenMarginsApp` build: passed.
- Diff whitespace check: passed.

See `podcast-anchor-benchmark.md` and `podcast-anchor-benchmark-result.json` for method comparisons, falsification history, thresholds, and the reproducible command.

## Product-owner checklist

Record each item as Pass, Fail, or Not run, with device/OS and notes.

1. **Prepare the sender edition.** Add a podcast, wait for its download to finish, start a new session, and confirm normal playback from the downloaded edition. Result: ___
2. **Capture acoustic evidence.** Record two or more Margins at well-separated passages. Include an intentional “um,” a removable “uh,” a semantic use of “you know,” and a long pause in at least one. Wait for transcription/evidence processing. Result: ___
3. **Review the package.** Open the item and tap **Share Margins**. Confirm that each selected Margin shows editable text, explicit voice representation, optional acoustic evidence, and bounded context; confirm no podcast audio is disclosed. Result: ___
4. **Validate cleanup.** Tap **Remove Fillers & Long Pauses**, preview Original and Cleaned, turn individual proposed edits off and on, and verify semantic “you know” is not removed merely because it is a phrase. Restore Original once, reapply cleanup, and choose the version you intend to share. Result: ___
5. **Export.** Tap **Share Reviewed Margins**. Confirm the package-ready screen appears and **Share File** offers a `.spokenmargins` file. Result: ___
6. **Exercise the real same-device route.** Tap **Create Recipient Test Session**, inspect the import disclosure, then tap **Import & Resolve Margins**. Confirm import does not autoplay and a separate session is created. Result: ___
7. **Inspect provenance and status.** On the item, confirm **Shared Margins** says integrity checked, sender identity unverified, and reports resolved/context-only/ambiguous status truthfully. Confirm the imported Margins also appear in Timeline. Result: ___
8. **Companion experience.** Select Companion, keep cue unmuted, start listening from before the first anchor, and confirm the cue appears at the passage without immediately playing the Margin. Choose Listen, confirm the reviewed representation plays, and confirm source playback resumes. Result: ___
9. **Guided experience.** Select Guided, cross a later anchor, and confirm the cue, automatic Margin playback, and source resume feel correct. Result: ___
10. **Fresh and mute controls.** In a new session select Fresh and confirm crossing an anchor does not reveal or play it. In another run use Companion or Guided with Mute cue enabled and confirm only the cue is suppressed. Result: ___
11. **Persistence and duplication.** Relaunch the app and confirm the layer, mode, mute state, resolution, and Timeline rows persist. Reuse the same package and confirm no duplicate layer is created; if using the same-device button, confirm a new listening session still starts. Result: ___
12. **Conservative failure behavior.** Try a Margin that warned acoustic evidence was unavailable, or a materially different/edited recipient edition. Confirm unresolved or ambiguous Margins remain readable and never interrupt playback. Any wrong confident interruption is a release-stopping failure. Result: ___
13. **Deletion and reset.** Delete the Shared Margins layer and confirm it no longer cues, plays, or appears in Timeline. Result: ___

## Acceptance rule

The own-device MVP can be marked `human_validated` only after the product owner accepts the sender review, same-device import, at least Companion and Guided listening, persistence, and conservative no-interruption behavior. Any wrong confident cross-edition placement, podcast audio leakage, unreviewed voice/text export, autoplay during import, private-original mutation during cleanup, or duplicate imported layer is a stop condition. External sharing remains blocked until issue #14 is explicitly accepted even if every item above passes.
