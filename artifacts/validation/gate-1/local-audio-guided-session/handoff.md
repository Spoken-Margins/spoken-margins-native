# Local-audio guided listening handoff

Status: **owner reported source playback failure on 2026-09-09; correction tracked in ../local-audio-relocation-fix/handoff.md**. The checks below describe the original delivery and did not exercise the real source player.

## Build and source

- Development build **0.1 (26)**, on `codex/provisional-next`.
- Base commit **fdbceda0dd840a541653ac6fe84957ffd6bec704**, plus the intentional working-tree changes recorded in `source-files.json`. This is not the previously distributed TestFlight Build 26 runtime.
- All five test plans verified the same input fingerprint: **523bc47767e00f1c518bd731765af2eb24734380065923ce37867910d896b5fa**.
- Signed generic iOS device build succeeded; `device-build.log` records it. The development update was installed in place on the paired iPhone 17 Pro (iOS 26.6.1); no reset, uninstall, TestFlight upload, or external distribution was performed. Installation evidence: `device-install.json`.
- Deployment target: iOS 18+, iPhone and iPad. Automated app/adapter/UI evidence used iOS 26.5 Simulator. Physical-device listening has not been accepted by the owner for this change.

## Deliverable and scope

[Listening package](/Users/colemiller/Documents/Codex/2026-09-08/pl/outputs/Introduction listening session/AI Economics — Introduction.spokenmargins) and [exact MP3](/Users/colemiller/Documents/Codex/2026-09-08/pl/outputs/Introduction listening session/00 - Introduction.mp3).

The package contains 16 source-grounded scene summaries, 16 supplied Chatterbox Skim clips, and 11 labeled AI professor Margins (also Chatterbox). Professor prompts add 3:59.8; all Skim clips total 5:20.4. The original 52:02 source remains unchanged. The bibliography was already absent from that recording.

In scope: exact local audiobook matching, rehash before import, per-Margin exact-time resolution, scene bounds checks, durable imported maps, supplied summary adoption and preservation across voice preferences, ordinary chapter/scene navigation, Skim, and the optional professor commentary layer. The app importer never starts playback.

Out of scope: embedded full-source audio, matching a converted/retagged/different edition, live professor answers, cloud generation, and public distribution. Text-only summary synthesis is not the delivered path: an earlier integration test stalled while relying on system speech; the final package supplies every summary voice and the passing test uses supplied audio.

## Verification

| Plan | Result | Evidence |
| --- | --- | --- |
| fast | 266 passed; 1 skipped | [manifest](/Users/colemiller/Documents/GitHub/spoken-margins-native/artifacts/test-runs/20260908-213322-774394-fast/manifest.json) |
| app | 393 passed; 0 skipped | [manifest](/Users/colemiller/Documents/GitHub/spoken-margins-native/artifacts/test-runs/20260908-211506-755527-app/manifest.json) |
| adapters | 8 passed; 0 skipped | [manifest](/Users/colemiller/Documents/GitHub/spoken-margins-native/artifacts/test-runs/20260908-211837-296276-adapters/manifest.json) |
| speech-canary | 1 passed; 0 skipped | [manifest](/Users/colemiller/Documents/GitHub/spoken-margins-native/artifacts/test-runs/20260908-212005-969363-speech-canary/manifest.json) |
| ui | 8 passed; 0 skipped | [manifest](/Users/colemiller/Documents/GitHub/spoken-margins-native/artifacts/test-runs/20260908-212703-381880-ui/manifest.json) |

The fast plan's one skip is the explicitly allowed opt-in held-out podcast corpus (`testHeldOutPublicDomainPodcastAnchorCorpus`); this exact-byte local import does not use cross-edition fallback. No app, adapter, speech-canary, or UI tests were skipped. Earlier failed test attempts are retained in the test-run archive and are not counted as passes.

The package writer/readback and deterministic second write passed. All 18 distinct source entry points passed ASR opening checks. All 27 Chatterbox clips passed transcript comparison (maximum word-error rate 6.7%; ASR is an error screen, not human pronunciation validation). Final audio digests match the synthesis receipts. The final archive SHA-256 is `31e967d4c66e986b3faf21d97437bd47b23a1d0535471d2f00e85c6980b404ab`.

The new app integration regression covers local source identity, import without autoplay, resolved professor positions, persisted navigation, supplied Skim playback to the next scene, reconstruction, and rejection after source bytes change. Focused package tests reject wrong bytes, duration mismatches, non-media/out-of-range anchors, overlapping/out-of-order scenes, and preserve per-Margin resolution failures.

## Owner checklist

Open the MP3 through Add Source → Audio file; then open the `.spokenmargins` package and confirm import. The [listening guide](/Users/colemiller/Documents/Codex/2026-09-08/pl/outputs/Introduction listening session/Listening guide.md) supplies scripts and exact entry times. The files are prepared on the Mac; they have not been inserted into the phone Library by bypassing the importer.

| Check | Owner pass/fail notes |
| --- | --- |
| Source is recognized and package import does not start playback | Pending |
| Listening Map shows 16 scenes; a chosen scene starts at a coherent passage | Pending |
| Guided professor cue/intervention sounds right and source resumes naturally | Pending |
| Companion waits for Listen or Dismiss; disabling the layer preserves source listening | Pending |
| Skim Forward plays the supplied summary then moves forward; Backward recaps the previous scene | Pending |
| Record a personal response Margin and resume the source | Pending |
| Restart/resume and device voice preference change preserve the supplied Chatterbox summaries | Pending |

Reset only this experiment by removing its imported professor layer and reimporting the same package. Reimport also restores supplied summary files. Keep the Library and source MP3; converting or retagging the audio changes its exact identity.

Diagnostics: Settings → Developer → **Copy Privacy-Safe Diagnostics**. Relevant entries include `lastSpokenMarginsPackageImport` and `localAudioSkim:<itemId>`. Save owner observations and any diagnostic export in this directory.

The unrelated pre-existing `artifacts/reviews/2026-09-08-build-26-issue-reconciliation/` work was preserved. Implementation changes remain uncommitted.
