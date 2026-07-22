# External TestFlight 0.1 — build 5 handoff

## Build identity

- Marketing version: `0.1`
- Build number: `5`
- Branch: `codex/external-testflight-readiness`
- Implementation base: `75bd993da7ed0428414aa9a956f8eeae6a1290fe`
- Final merged `main` SHA: **PENDING — record after reviewed PR merge**
- Supported devices: iPhone and iPad
- Minimum OS: iOS/iPadOS 18.0
- Shipping extensions: Widget/Live Activity, Share extension, Safari Web Extension

## State

- `implemented`: #13 runtime/session fixes, #29 offline podcasts and local anchor enrichment, action feedback, safe permanent deletion, and idempotent link intake are present on the readiness branch.
- `verified`: the branch evidence below supports implementation claims; re-run it from the reviewed merge commit before archiving.
- `human_validated`: **NO — only the product owner may change this after using the exact archived candidate.**
- `submitted`: **NO — stop conditions remain below.**

## In scope

- #13 native-text voice/rate changes while starting, playing, paused, and after navigation.
- #29 Wi-Fi automatic podcast download, cellular streaming-only behavior, honest partial-download state, offline completion, local/remote handoff, adjustable 5 GB-default LRU cache, eviction, retry, clearing, and permanent deletion.
- #8 share-sheet intake for Safari articles, selected text, audio links, Markdown, plain text, and PDF, including Import Inbox recovery and background intake.
- #28 clean-install reviewer access to Listening Map, summary, and follow-up AI paths.
- #32 action feedback, independent destructive actions, and permanent deletion.
- #33 idempotent Return/focus-loss podcast-link submission.
- On-device-only podcast anchor enrichment from stored transcripts, downloaded audio, or a bounded remote window, with persisted Pending/Ready/Unavailable states.
- Copy/action feedback, independent destructive-row hit targets, and verified permanent deletion.
- Return/focus-loss podcast-link submission with validation, deduplication, and visible resolving/failure state.
- Fully offline native-text hardening that preserves imported source text while removing malformed media markup, emoji, joined/combining clusters, and other unsafe characters from the system-speech projection; default-voice fallback, navigation-only mini-player behavior, and resumable early stop.
- Build/signing identity and App Store Connect metadata/submission readiness.

## Out of scope

- Issues #14–#27 unless a behavior is already exposed or claimed in this beta.
- A hosted API proxy; this release remains BYOK.
- Product-owner validation or App Store submission performed by an agent.

## Automated verification

Branch verification on July 22, 2026 is recorded below. Re-run it from the final reviewed commit before requesting human validation.

- [x] `/opt/anaconda3/bin/python3 scripts/validate-contracts.py` — passed.
- [x] `/opt/anaconda3/bin/python3 scripts/validate-surface-contracts.py` — passed.
- [x] `swift build --build-tests --package-path Packages/SessionKit` — passed.
- [x] `swift test --package-path Packages/SessionKit` — 110 tests passed, including the system-speech projection invariant: unsafe grapheme clusters and markup are removed before playback, every retained character occupies exactly one UTF-16 unit, and retained characters preserve monotonic source offsets.
- [x] `SpokenMarginsAppTests` on iPhone 17 Pro / iOS 26.5 simulator — 84 tests passed, including the exact article import fixture and speech projection.
- [x] `SpokenMarginsAppUITests/Gate1FlowUITests` on iPhone 17 Pro / iOS 26.5 simulator — all 7 existing route tests passed.
- [x] `SpokenMarginsAppUITests/EmojiArticlePlaybackUITests/testExactEmojiArticleCompletesAfterPauseAndResumeNearCrashPoint` on iPhone 17 Pro / iOS 26.5 simulator — the exact supplied article completed naturally at 100% using System 0.55 after pausing at or beyond 23%, proving paused progress remained fixed, resuming, and continuing beyond the reported 25% crash point (final-code rerun: 191.860 seconds).
- [x] Generic iOS Simulator Debug and Release app builds — passed for the app and three embedded extensions.
- [x] Generic iOS device Debug and Release app builds — passed for the app and three embedded extensions.
- [ ] Generic watchOS build — not runnable: the generated project contains no `SpokenMarginsWatch` target/scheme; the AGENTS.md command is stale for the current project topology.
- [ ] Fresh Release archive from merged `main`
- [ ] App Store Connect IPA export and signing inspection

The branch Release device build reports version `0.1` build `5` for all four bundles. It is development-signed with `get-task-allow=true`, as expected for a routine build, and is **not** the submission artifact. Distribution signing remains an archive/export gate after merge.

## Product-owner checklist

Record device, OS, pass/fail, notes, and diagnostics for each line.

### #13 native text

- [ ] Live speech starts audibly before source progress advances.
- [ ] Change rate while playing; speech remains audible and resumes at the last audible source position.
- [ ] Change voice while playing; no silence or phantom scrubber movement occurs.
- [ ] Change rate and voice while paused; playback stays paused and the source position stays fixed.
- [ ] Repeat while playback is starting and after navigating away from/back to playback.
- [ ] Prepared speech and live speech both behave correctly.

### #29 podcasts

- [ ] On Wi-Fi, playback starts promptly while the complete episode downloads.
- [ ] Leave Wi-Fi before completion; the UI does not claim the episode is offline-ready.
- [ ] On cellular, the episode streams but does not download automatically.
- [ ] Complete a download, disable connectivity, relaunch if desired, and finish playback offline.
- [ ] While playing, allow download completion and confirm local handoff does not change time, rate, chapter, target, or interjection anchor.
- [ ] Confirm Waiting for Wi-Fi, Downloading, Available Offline, Streaming Only, Failed/Retry, and Evicted states are honest.
- [ ] Change the cache among 1, 2, 5, 10, and 20 GB; confirm a fresh install defaults to 5 GB.
- [ ] Confirm least-recently-played eviction protects active playback and in-progress downloads.
- [ ] Retry an evicted/failed episode and confirm redownload policy.
- [ ] Clear downloads and permanently delete an item; confirm remote-only/record/file behavior is correct.
- [ ] With a completed download and connectivity disabled, create an interjection; confirm its timestamp saves immediately and Before/After context becomes Ready from local audio.
- [ ] Without local audio, create an interjection; confirm Pending/Unavailable is shown honestly and Retry enriches it after audio or an imported transcript becomes available.

### Native-text stability and session recovery

- [ ] Fully offline, repeatedly play the supplied emoji-article fixture with the default voice and selected installed voices; confirm no crash, indefinite loading, or silent progress.
- [ ] While native text is audible, navigate Playback → Settings → mini-player; confirm audio, session, target, and position are unchanged.
- [ ] Stop near 1%, reopen the same session, and confirm it remains `in_progress` and resumes from the persisted source position rather than replaying the overview.
- [ ] Complete a source naturally and confirm only that path marks it `finished`; use the explicit restart action to replay it.

### Action feedback, deletion, and link intake

- [ ] Copy an interjection and copy diagnostics; confirm each button shows a temporary checkmark/“Copied” state and VoiceOver announces success.
- [ ] In Recently Deleted, activate Restore and Delete Permanently separately; confirm only the chosen action fires and permanent deletion cannot restore the item.
- [ ] In Import Inbox, activate Retry and Delete separately; confirm only the chosen action fires and feedback is visible.
- [ ] Submit a valid podcast link with Return and valid focus loss; confirm each imports exactly once.
- [ ] Confirm malformed URLs remain editable and Paste, Close, and explicit Add Link do not cross-trigger focus-loss submission.

### #8 share sheet

- [ ] Safari readable article.
- [ ] Safari selected text.
- [ ] Podcast/audio URL.
- [ ] Markdown file.
- [ ] Plain-text file.
- [ ] PDF file.
- [ ] Failed share appears in Import Inbox and succeeds after retry.
- [ ] Intake while another item is playing does not replace or interrupt the active session.

### #28 reviewer AI access

- [ ] Delete the app, reinstall, and enter the dedicated reviewer key from Beta App Review Notes.
- [ ] First live AI action presents the disclosure before transmission.
- [ ] Listening Map generation completes.
- [ ] Interjection summary generation completes.
- [ ] Follow-up generation completes.
- [ ] Settings → Delete API Key removes the reviewer key; revoking it server-side also stops access.

## Reset, samples, and diagnostics

- Fresh reset: delete the TestFlight app and reinstall. Also use Settings → Delete API Key before deletion when key removal must be verified.
- Seeded sample: `Welcome to Spoken Margins` appears on a fresh empty install.
- Diagnostics: Settings → Support & Privacy → Copy Privacy-Safe Diagnostics.
- Store validation evidence beside this file; do not put API keys, source text, transcripts, private URLs, or personal file paths in the artifact.

## Archive/export inspection

- [ ] Archive and IPA both report version `0.1` build `5`.
- [ ] Bundle identifiers: `com.spokenmargins.native`, `.gate2widget`, `.share`, and `.browsertext`.
- [ ] App and extensions use App Store distribution identities/profiles.
- [ ] `get-task-allow` is absent or false in all four signed bundles.
- [ ] dSYMs/symbol upload are present as expected.
- [ ] App Store Connect processes the uploaded build without profile or metadata errors.
- [ ] The misleading `artifacts/SpokenMargins-0.1-4.xcarchive` is not reused (directory says 4; contents are development-signed build 3).

## Stop conditions

Do not submit for external Beta App Review until #13 is resolved, #29 is genuinely offline-capable, #32 and #33 are product-owner accepted, #8 has product-owner evidence on this exact candidate, the reviewer AI credential works from a clean install, this artifact is marked `human_validated`, and a valid distribution IPA exists.
