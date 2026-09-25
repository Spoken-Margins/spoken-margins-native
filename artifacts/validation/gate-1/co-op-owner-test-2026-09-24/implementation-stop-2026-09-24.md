# Co-op implementation stopping point — September 24, 2026

**Historical checkpoint:** the owner subsequently asked to continue. Nano audio, all three verified packets, the final fast gate, and the owner handoff were completed afterward. See `owner-packet-handoff.md` for the current state; the incomplete-work statements below describe only this earlier stop.

Owner requested a good stopping point within one minute and a documentation update. Work stopped at the first integrated code slice; this is **not** a complete owner test packet or human-validated experience. Branch `codex/co-op`, HEAD `34837c6055471297ca0b360c591f734bad5c2c82` plus pre-existing dirty work. No commit, merge, simulator boot, device installation or distribution.

## Implemented in the dirty tree

- `MarginConversation` now accepts an ordered list of two to four exact parent revisions, with backward decoding/encoding for v1 one-parent records. Graph merge checks cycles and known cross-item links; ancestor planning includes shared ancestors once.
- Packet builder requires `spoken-margins.conversation.v2` when a record has multiple targets; archive reader recognizes and enforces it. The closed commentary schema accepts the bounded `parents` array and disallows competing `parent` and `parents` fields.
- A real archive/import regression was changed to Casey with two parents, including Casey-first import, overlap deduplication, restart and conflict rollback. The focused test passed. The preexisting 482-test app pass does not cover these changes.
- App conversation context now gathers both targets; forwarding includes their ancestor closure; source capture anchor is no longer replaced by a parent anchor. The Response & Context editor supports selecting up to four targets. The conversation replies section offers a Reply to several sheet; recording attaches the ordered selected revisions. Selected targets and missing-target indication are shown in playback. Direct archived playback falls back to Margin playback when source context is unresolved.
- Package builder gained a distinct synthetic TTS representation using the existing `tts_voice` and `sender_approved_tts` vocabulary. No synthetic audio packet has been written.

## Verification and remaining risks

- Focused macOS package test `SharingTests/testConversationForksRoundTripAndDeduplicateAcrossDifferentPacketsAndRestart` passed (1/1).
- Generic iOS Simulator app build passed after the first UI compile correction. The final incremental build also passed (`/tmp/co-op-multi-stop-build.log`). This is compilation evidence, not execution of the new app flow.
- `git diff --check` passed.
- No UI route or current full fast/app/adapters/speech plans ran for this slice. The prior XCTest startup stall and platform incident restrictions remain in force.
- Multi-target recording needs focused app regression coverage and UI observation; the new selection sheet has not been exercised at runtime. Review cancellation/restart, direct playback on unresolved source, exact target labels, and whether the share review exposes all forwarded bodies. The destination list can still be improved for group-scale navigation.
- Packet generation is incomplete. The bundled `chatterbox-tts==0.1.7` lacks the `nano=True` loader despite the current upstream model documentation. Official Resemble source at commit `5de7a54aa4e5e2baadb0182dde554908b48b85c2` was installed into `/Users/colemiller/Downloads/SpokenMargins-Coop-Test-2026-09-24/.nano-venv`. Its Nano smoke run started fetching model files, then was interrupted to honor the owner's stop request. No smoke WAV or final Nano audio was verified. The three grounded scripts, synthetic reference WAVs and generation script are in that Downloads folder. No model files or voices were added to the repository.
- An unfinished generator target was removed from `Packages/SessionKit/Package.swift` before stopping; packet generation needs a dedicated reproducible CLI or test harness next. Never claim Casey's two links are verified in an owner packet until that real packet passes the production importer.

## Resume from here

1. Start from the passing final incremental app build and inspect only new failures introduced by subsequent edits.
2. Add focused negative graph/schema tests (duplicate parent, cycle across either edge, cross-item known parent, old v1 decode) and app recording/playback tests. Use the mandatory gates only after the integrated behavior is complete.
3. Resume official Nano smoke generation from the cached download. Verify `nano=True`, model identity, output speech and duration before generating the three full responses. Do not use the old PyPI loader.
4. Build actual A/B/D packets with the real archive writer/importer, retaining the selected Cole legacy revision identity and source evidence. Verify normal/reverse/repeated import and exact D→A,B links. Keep generated audio labeled synthetic and forwarded originals labeled correctly.
5. Prepare the exact candidate handoff and owner checklist. Owner acceptance, physical-device resource evidence and the blocked iOS export test remain separate evidence paths.

Usage at start was 38% weekly used / 62% remaining; at this stop it was 40% used / 60% remaining, a 2-point increase as reported by the account meter. The owner then directed “get it complete,” superseding the older floor. The Nano smoke process was terminated after interruption; no generation process remains running. Obtain a fresh usage reading at resume. Do not infer a precise cost from elapsed machine time.
