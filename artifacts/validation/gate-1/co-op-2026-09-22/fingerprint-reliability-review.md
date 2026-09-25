# Podcast fingerprint reliability review

September 23, 2026 · Updated after reviewing the re-export and sender diagnostics. No implementation changes or runtime tests.

**Your expectation is correct:** after a Margin, continued podcast playback should normally supply its own post-Margin fingerprint, without refetching. The app already attempts this. Zero fingerprints in a packet does **not** establish that fingerprinting itself failed: acquisition, saving, or export can lose the evidence. The new diagnostics support your expectation: playback continued after at least four of the five Margins, yet the re-export still contains no fingerprints. The precise loss point remains unknown.

**What the re-export and diagnostics establish**

- **Still no acoustic evidence:** the packet created September 23 at 15:28:50 UTC contains five cleaned voice assets, five empty `machineEvidenceAssetIds` arrays, bounded before/after transcript text, no fingerprint spine, and no exact source-edition hash. All six declared asset/artifact sizes and SHA-256 digests match their archive contents. These integrity hashes identify package contents, not the podcast edition. Diagnostics independently report `margins=5;evidence=0;map=preparing_or_unavailable`.
- **Continued playback is recorded:** four September 21 recording positions exactly match packet anchors. Within about 30 seconds after each resume, source time advances by 52.0–52.6 seconds, with playback reporting `failure=none`. This supports sufficient playback opportunity, not proof of tap sample delivery. The retained log starts after the first Margin.

| Packet Margin | Source anchor | Source advance after resume |
| --- | ---: | ---: |
| 2 | 2,203,746 ms | 52,555 ms |
| 3 | 2,386,292 ms | 52,297 ms |
| 4 | 3,061,250 ms | 51,996 ms |
| 5 | 3,685,184 ms | 52,367 ms |

- **Re-exporting did not recover evidence.** This weakens “exported before capture finished” as a sufficient explanation. A stale draft remains a code risk, not the established cause. A later offline-download event for the same logged item does not establish that this file was the edition played at capture.
- **Diagnostics still miss the decisive evidence:** no per-Margin tap, signature, persistence, or inclusion-toggle outcomes are present. `prepared=5;fallbacks=0` concerns share preparation, not fingerprint success. The `developerRecording` covers September 17; the separate `playbackEvents` covers September 21–23. Neither should be treated as a complete capture trace. The build label is `device-diagnostics-20260908-C`, not a commit SHA; current-source findings below are not proof of the installed binary’s exact implementation. The previously observed recipient simulator speech failure is a separate incident.

Evidence: [re-export](/Users/colemiller/Downloads/DS-55-Jreg-d952b75b.spokenmargins), [sender diagnostics](</Users/colemiller/.codex/attachments/19f606e3-e4c9-4494-a5e6-b72336c12723/Pasted text.txt>). Packet SHA-256: `aa69ae8355fb30268afb43a1d43e88762bbf9dc1a1942eed33251bcd8f5479a0`.

**What the current source does**

| Stage | Current behavior and failure path |
| --- | --- |
| Acquire source audio | At Margin completion, the engine requests a buffered pre-window and a 12-second post-resume sample. A memory-only 20-second ring can provide pre-audio without refetching. Both depend on the same playback tap. [Engine](../../../../Packages/SessionKit/Sources/SessionKit/SessionEngine.swift#L1519) |
| Attach the tap | The continuous tap is attempted when the player item is created and requires an audio track to be present already. There is no readiness-triggered installation retry in this path. Post-capture arming tries again, but can also return false. An installed tap is not proof that samples arrive. Thus one acquisition failure can eliminate pre, post, and sparse landmarks together. This is a code-supported possibility, not the diagnosed historical cause. [Adapter](../../../../Packages/SessionKit/Sources/SessionKitAudio/AudioAdapters.swift#L1899) |
| Complete capture | Post-capture has a 60-second wall-clock deadline, including stalls or pauses. Invalid buffers, missing media timestamps, signature errors, insufficient remaining audio, or an item change can fail it. Seeking resets accumulation without renewing that deadline. There is no durable post-capture retry job here. [Capture](../../../../Packages/SessionKit/Sources/SessionKitAudio/PostResumePodcastEvidenceCapture.swift#L124) |
| Recover and save | A tap failure falls back to a downloaded file only when it is the file currently playing. Without that exact local edition, it falls through to source-context recovery. Source-window fingerprint generation runs **after successful transcription**, so speech failure can also prevent this acoustic backup. Signature-file and database writes can fail separately. [Recovery](../../../../App/SpokenMarginsApp/Sources/SpokenMarginsApp/Gate1AppModel.swift#L13072) |
| Export | Export uses the sharing draft’s Margin copy, silently drops missing signature files, and permits zero evidence. Capture completion updates the database without refreshing that draft: opening sharing early creates a stale-evidence risk even if capture subsequently succeeds. One aggregate capture status also obscures separate pre/post outcomes. [Persistence](../../../../App/SpokenMarginsApp/Sources/SpokenMarginsApp/Gate1AppModel.swift#L13488), [export](../../../../App/SpokenMarginsApp/Sources/SpokenMarginsApp/Gate1AppModel.swift#L14244) |

Apple’s signature generator consumes supplied audio buffers; it does not acquire playback audio itself. That acquisition boundary is essential. [Apple documentation](https://developer.apple.com/documentation/shazamkit/shsignaturegenerator)

**What “just works” should mean**

Given enough usable, continuous source playback, save correctly timed evidence automatically. Preserve the Margin regardless. If evidence cannot be obtained or the recipient edition is ambiguous, recover automatically where possible and expose the remaining uncertainty—never silently place a Margin incorrectly. A full-episode hash is useful for identical files but is not a prerequisite for streaming fingerprints.

**Recommended order of work**

1. **Make post-capture observable and durable.** Persist session-qualified per-Margin outcomes, sample counts, failure stages, and the producing build/commit so relaunch and re-export cannot erase the diagnosis. Track pre and post independently: waiting, collecting, saved, retryable failure, or unavailable with a reason. Attach/retry when the track becomes ready; measure actual sample delivery. Budget capture in usable audio time, with bounded wall-clock/resource limits. Resume pending work after interruptions; after relaunch, reacquire only with trustworthy edition/position provenance. Never pretend lost audio was captured.
2. **Protect timing and evidence.** Freeze available pre-audio; collect post-audio from actual resumed playback. Record source start/end, offset to the original Margin, and seek continuity. A later sample across a seek or ad boundary is not automatically equivalent to the original flank. Commit files and metadata recoverably, verify readability, and retain evidence while its Margin needs it. Keep decoded audio bounded and transient; share no podcast audio.
3. **Make the backups independent.** Generate fingerprints from available source-window audio even if transcription fails. Prefer the observed playback edition or its exact local file. Treat a refetch as another possible edition. Pre/post samples and sparse landmarks add coverage, but all using one broken tap is not acquisition redundancy. First test reliable tap installation; consider a different playback acquisition architecture only if supported real-device playback modes still cannot expose samples.
4. **Make export enforce completeness.** Reload current evidence from storage, verify every referenced asset, and record per-flank outcomes plus the inclusion choice. Retry missing evidence where possible. Keep quick sharing available through an explicit “share without automatic positioning” choice when needed; never silently omit evidence. This is a proposed refinement of the existing nonblocking-share policy.
5. **Recover on the recipient without guessing.** Keep overlapping acoustic reference windows and test uniqueness across the episode. Fuse independent acoustic and transcript evidence. Try bounded transcript windows near credible positions, then widen within a fixed budget; a broken speech service needs another path, not endless smaller retries. A post-only match can be valuable, but duplicated audio or an intervening edition edit can invalidate the inferred Margin position. Use corroboration and explicit recipient position confirmation when uncertainty remains.

**How to prove it**

First reproduce the observed case: normal playback advances over 50 source seconds after a Margin but re-export has zero evidence. Locate the first missing transition: armed → samples received → signature generated → saved → exported. Then test real-device streaming and downloaded playback, delayed track readiness, pauses over 60 seconds, seeks, rapid Margins, episode endings, relaunch, failed file writes, and sharing opened before capture completes. Include repeated passages, inserted/deleted ads, and unavailable speech recognition. Measure saved-post coverage among eligible playback events, time to readiness, export completeness, placement error, and false-confident placements separately. Require no silent export omissions, an explainable outcome for every flank, and zero false-confident placements in the adversarial test set; production reliability still requires measurement. Stop bounded retries with a useful recovery choice. Automated evidence is **verified**; only owner use establishes **human_validated**.

Earlier recipient findings: [simulator-demo-status.md](simulator-demo-status.md). Priority remains sender capture-to-export accountability and independent recovery; repeated listening or re-export alone is not an adequate repair.
