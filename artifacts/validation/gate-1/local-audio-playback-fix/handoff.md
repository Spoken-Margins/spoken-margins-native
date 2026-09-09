# Local source playback correction — 2026-09-09

Superseded after owner reported continued failure. This correction addressed asset ID routing but omitted data-container relocation. See ../local-audio-relocation-fix/handoff.md for the subsequent device diagnosis and owner-confirmed source playback.

## Failure and correction

The owner reports silent Play with working Skim summaries. Audiobook imports deliberately use an internal nativeMediaId, separate from their file URL. The session engine passed that ID without a playback URL to AVPlayer. Supply the native file URL in PlaybackMediaContext while retaining the stable target ID and any explicit playback-transport override. This applies to existing imported items and resumed sessions; no package regeneration or source re-import is required.

The former integration test injected NoopAudioPlaybackClient for source playback. It therefore verified package import and independently rendered Skim, but missed the source transport defect. The strengthened test uses RoutedAudioPlaybackClient and real AVPlayerStreamPlaybackClient with a non-silent local audio file and a distinct asset ID. It asserts real source time advances before Skim, after pause/resume, and after Skim and dismissal of Companion's intentional prompt. The before-change test failed at zero source progress; the corrected test passes. Before/after test-result JSON is retained here.

## Build and scope

Development build 0.1 (26), codex/provisional-next, base fdbceda0dd840a541653ac6fe84957ffd6bec704 plus working-tree changes. This is distinct from distributed TestFlight 26. Input fingerprint: bec3e38a94c53a3f4bad40f08ef7c2b5d5a3f7913d8eec70c44c745e7df66408. Source hashes for this correction are in fix-source-files.json; prior session changes remain present and unrelated review artifacts were preserved.

Signed generic iOS build passed. Installed in place on the paired iPhone 17 Pro; see device-install.json. Supports iOS 18+ on iPhone and iPad. Automated playback runs on iOS 26.5 Simulator. No reset, uninstall, upload, or public distribution.

In scope: native local-audio URL routing, source Play/pause/resume, return from Skim. Out of scope: new speech generation, package changes, cross-edition matching, layout changes, distribution. The existing Introduction MP3 and .spokenmargins package remain the seeded sample; all professor/Skim recordings remain Chatterbox Turbo.

## Owner recheck

Open the existing Introduction item and press Play. Confirm audible narration and advancing time; pause and resume; use Skim and confirm narration continues after the summary (dismiss a Companion prompt or let a Guided Margin finish if one appears). Close/reopen the app and continue the same item. All owner pass/fail notes remain pending.

No reset is required. Keep the existing Library and imports. If playback fails, retain that state for investigation. Developer diagnostic recording/export remains available in the app; automated logs and before/after results are in this directory. Known limitation: automated playback progress is not a human judgment of audible output or professor balance.

## Final verification

- fast: verified — [fast manifest](/Users/colemiller/Documents/GitHub/spoken-margins-native/artifacts/test-runs/20260909-091005-128580-fast/manifest.json)
- app: verified — [app manifest](/Users/colemiller/Documents/GitHub/spoken-margins-native/artifacts/test-runs/20260909-091024-299066-app/manifest.json)
- adapters: verified — [adapters manifest](/Users/colemiller/Documents/GitHub/spoken-margins-native/artifacts/test-runs/20260909-091135-888744-adapters/manifest.json)
- speech-canary: verified — [speech-canary manifest](/Users/colemiller/Documents/GitHub/spoken-margins-native/artifacts/test-runs/20260909-091203-263178-speech-canary/manifest.json)

All plans share the input fingerprint above. No UI layout changed; the broader UI routes were not repeated for this transport correction. The phone install succeeded; automatic launch was blocked by the device lock. Unlock and open the app manually.
