# Podcast anchor integration handoff — September 23, 2026

Implementation paused at the explicit account reserve: 13% used, 87% remaining. This is an incomplete engineering candidate, not a product validation or release handoff. No branch, commit, device installation, simulator boot, distribution, or server change occurred. The previously dirty worktree was preserved.

## Implemented after the core handoff

- App capture persistence now updates durable pre/post windows independently when observed or exact-local evidence commits. A sibling failure retains committed evidence and the first failure reason. Nil reference-edition evidence no longer erases a known exact-edition digest. Tap failure results carry an explicit window role; live requests carry attempt generation 1, and app callbacks check it and the original anchor before writing. The aggregate status is pending while any flank is pending, ready only when both are committed, and unavailable if a terminal sibling is absent.
- `SourceTranscriptionClient.acquireSourceAudioWindow` and the production audio adapter can acquire a bounded local window without invoking speech recognition. The app derives reference-edition signatures from that acquisition before independently attempting bounded source ASR. A stored transcript satisfies the text side without ending acoustic work. Production source-window audio is shared through the existing bounded cache path; its provenance stays distinct from observed playback.
- Export reloads current selected Margins from SQLite while preserving reviewed text and cleanup choices. It does not silently use stale draft evidence. Missing/incomplete podcast evidence prompts the sender to keep preparing or explicitly share without automatic positioning assurance. Nonempty available evidence is included; the archive remains the final integrity validator. Intentional acoustic opt-out remains a separate toggle.

Files changed in this integration pass: `App/SpokenMarginsApp/Sources/SpokenMarginsApp/{Gate1AppModel,SharingExperience,Build23SharingSeams,Build23SenderSharingExperience}.swift`, `Packages/SessionKit/Sources/SessionKit/{Models,Protocols,SessionEngine}.swift`, `Packages/SessionKit/Sources/SessionKitAudio/{AudioAdapters,PostResumePodcastEvidenceCapture}.swift`, and focused package tests. See `capture-handoff.md` for the earlier A–C inventory. Other dirty app/audio files in `git status` predate this work.

## Verification executed

- `xcodegen generate` succeeded.
- `xcodebuild -project SpokenMarginsNative.xcodeproj -scheme SpokenMarginsApp -destination 'generic/platform=iOS Simulator' build` succeeded; full log: `app-build.log`. No simulator boot. A final one-line anchor identity comparison was edited after this build and has not been recompiled under the usage stop.
- `swift test --filter 'SessionKitCoreTests.testRoutedPodcastCaptureForwardsOnlyOnActiveMediaRouteAndPreservesSessionIdentity|SessionKitCoreTests.testPodcastInterjectionArmsBoundedPostResumeSampleBeforePlaybackRestarts|SQLiteSessionStoreSafetyTests.testPodcastCaptureWindowsSurviveRestartAndOutOfOrderCompletionAcrossSessions|SharingTests.testPostResumeWatchdogSeparatesRepeatedMarginIDsBySessionAndUsesSourceProgress|SharingTests.testContinuousEvidenceRingExtractsExactPreWindowAndSeekInvalidatesIt|SharingTests.testPostResumePodcastEvidenceUsesOnlyArmedDecodedAudioWindow'` passed: six tests, zero failures.
- `git diff --check` passed.

## Unfinished work and material limits

- Packet F recipient recovery remains unchanged: it still can request full-source transient ASR; a unique hit in a bounded local transcript is not globally proven; no explicit recipient position-confirmation action is wired. The current conservative partial-flank resolver must remain in force.
- No versioned per-Margin safe outcome summary was added to the share package/schema, so a delivered degraded packet does not describe which roles were unavailable or intentionally omitted. The degraded choice is held in the current share session only. Existing packages remain readable.
- Export checks current records and lets archive assembly validate available files, but there is no transactional pin/snapshot across deletion races. An archive race fails rather than silently omitting evidence; a durable export disposition is still needed.
- No startup/foreground job reconciliation, orphan-file cleanup, exact-edition change token for all worker paths, durable retry scheduler, measured reattachment limit, or off-callback PCM format conversion is implemented. A request with no attempt generation (legacy or exact-local path) does not get the new stale-attempt check. Source-window acquisition failure still prevents that attempt's ASR because no audio was acquired.
- The production adapter has not been verified with real streamed MP3, HLS, lock screen, route changes, or device resource measurements. Required `fast`, `app`, `adapters`, `speech-canary`, scoped `ui`, and release gates remain open. Neither app build nor host tests establish `human_validated` product flows.
