# Build 27 owner validation — September 11, 2026

The owner reports using **Build 27** and states: “everything accept the above is validated.” This records product-owner acceptance of the other checklist flows, with the exceptions below. The exact installed commit is not proven by the build number; no acceptance is inferred for subsequent changes.

| Exception | Owner observation | Recheck after repair |
| --- | --- | --- |
| Publisher chapters | Apple episode 1000774870615 did not import description timestamps. | Seven chapters from the exact Apple episode; followed-source imports also retain show-note chapters. |
| Scrolling | Large Timeline and Item with shared Margins scroll jerkily during native audio. | Same large item, paused and playing, with summaries and shared layers present. |
| Timeline provenance | Chapters/scenes and own/other people's Margins are not distinguishable. | Distinct Chapter, Listening map, My Margin and Shared Margin labels; shared text opens shared detail. |
| Skim exit | Tapping Skim during the summary restarts it. | Second tap ends summary and moves to the chapter boundary; original play/pause state is preserved. |
| Share regression | Share button animates for two Margins but no system sheet appears. | Same two-Margin flow builds a verified package and opens the native share sheet; a failure is visible. |
| Margin actions/context | Copy/recording actions lack visual feedback; context retry fails despite local audio. | Visible feedback in the presented detail, working recording state, context recovery after container relocation, visible failure if recovery cannot complete. |

The other checklist flows are `human_validated` by owner report for Build 27. Do not ask the owner to repeat unchanged accepted flows by default. User-checked policy decisions in `docs/external-testflight-sharing-decision.md` are preserved. This record does not independently establish App Store Connect processing, the installed source SHA, or authorization for a new upload.

## Diagnostic evidence

Owner-supplied diagnostics were read from the private attachment `b2206103-9167-470a-b505-d17dda7a00c5/pasted-text.txt`. The full Library inventory is not copied into this repository.

- `bulkSharePreparation`: complete, prepared=2, fallbacks=0.
- `lastSharedPackageFailure`: `invalidManifest("scene summary asset is absent or has the wrong role")`.
- `sourceWindowTranscription:ij-002`: `failed:persistence_failed:source_audio_file_missing`.
- The recording contains 1,200 samples: home 896, export 290, settings 14. It has no Item/Timeline scrolling sample, so it cannot establish a scrolling frame-time baseline.
- The diagnostic build label is the older instrumentation label `device-diagnostics-20260908-C`; it is not a replacement for the owner-reported app version.

Exact episode: https://podcasts.apple.com/us/podcast/dwarkesh-podcast/id1516093381?i=1000774870615. Apple's lookup identifies Grant Sanderson – AI and the future of math. At inspection the associated RSS endpoint returned HTTP 403; the exact Apple metadata contained seven timestamped chapters. A separate followed-entry import path also bypassed description parsing when it imported the audio enclosure directly.

## Local repair candidate

Status: `implemented`; automated verification listed below. The six repairs are not yet `human_validated`. Local version remains 0.1 (27), with uncommitted changes based on `4fbb131b7c7b1c8a86aabd6a6474ed7ec3c0cb60`; implementation input SHA-256 is `e6159025d847c31f5b8300c455c7e4480e54a7918a7c34f1cacdc07b30da9014`.

- Chapters: preserve Apple's description and duration when the feed fails; parse descriptions on followed-entry enclosure imports too. The exact episode regression checks all seven starts: 00:00:00, 00:11:32, 00:26:12, 00:38:08, 00:53:48, 01:07:07 and 01:16:02. Existing Library entries are not automatically backfilled.
- Scrolling: cache Skim resources between playback ticks, stop sharing presentation from subscribing to every playback/diagnostic update, use lazy imported Margin rows, and skip rebuilding unchanged Timeline rows. Tests verify tick isolation and cache reuse; this is not a physical-device frame-time measurement.
- Timeline: distinguish Chapter, Listening map, My Margin and Shared Margin; shared entries retain author/collection and open their detail. Remove the duplicate expanded shared list below the Timeline while retaining layer controls.
- Skim: a second tap completes the active summary bridge at its destination, preserving source play/pause intent. Real-player coverage verifies source advancement after exit.
- Sharing: outgoing textual map proposals omit references to local Skim assets that are not being exported. Selected Margin content and local maps remain intact. Regression coverage reads the actual two-Margin package and verifies its manifest; preparation errors are visible beside Share.
- Margin actions: show feedback inside the detail sheet, expose context-retry progress, and resolve current app-owned audio locations for recovery. A relocated-file regression verifies the actual URL passed to transcription and completed context recovery.

### Verification

- App: [manifest](../../test-runs/20260911-144806-985445-app/manifest.json), **414 passed, 0 failed, 0 skipped**; final build 9.026s, tests 62.509s.
- Fast: [manifest](../../test-runs/20260911-145214-649620-fast/manifest.json), passed on the same input: 285 package tests passed, one explicitly permitted corpus skip, 11 browser tests and 10 runner tests; contract/surface/inventory validators passed.
- Audio/UI: [manifest](../../test-runs/20260911-145929-323586-build27-audio-ui-retry/manifest.json), **14 passed, 0 failed, 0 skipped**: all 11 AudioAdapters selections, the complete SpeechCanary selection, and the two affected UI tests (direct primary Share opens the native sheet; Copy with Context feedback appears in Margin detail). Tests 397.261s. One shared build took 53.165s and passed bundle verification.
- The initial combined run started no tests and was stopped after diagnosing an idle test host. [Incomplete evidence](../../test-runs/20260911-145252-330629-build27-audio-ui/manifest.json) is retained. Restarting the test simulator without erasing it allowed the single retry above to pass using the same build. No additional development runs are needed on these unchanged inputs.
- Earlier failed development attempts are retained: protocol syntax, a test initializer, and a persistence-rounded test timestamp were corrected before the final app pass. No failed run is counted as a pass.

### Installation and owner recheck

No updated device install, archive, upload or external submission is established by this repair record. The old Build 27 IPA predates these changes. Before rechecking, identify the installed source and build, device/OS and date. Supported deployment is iPhone/iPad iOS/iPadOS 18+; simulator verification uses iPhone 17 Pro / iOS 26.5. Intelligence features depend on device/OS capability.

Preserve the existing Library and the 24-scene item. No full reset or map regeneration is required. Use the exact Apple link in a disposable import for new chapter metadata, the original two Margins for sharing, and the previously failing Margin for context recovery. For a disposable Simulator only, Settings → Developer tools → Reset Library and Load Sample supplies sample content. Diagnostics: Settings → Copy Privacy-Safe Diagnostics; enable recording only for a short failure reproduction, then export and disable it.

Fill the six exception rows above with Pass/Fail/Not tested and a note. Full exact-source release verification, iPad checks and a fresh signed archive remain separate prerequisites for distribution.

## September 12 issue reconciliation

The owner accepted the bounded sharing policy and authorized GitHub updates. See [closed issues and six remaining retries](../gate-1/2026-09-12-build-27-github-reconciliation.md). Existing acceptance is preserved; subsequent repairs still require owner use.
