# Resource recovery candidate — September 14, 2026

## Identity and scope

Development source: `codex/provisional-next`, base `ad533d6604dbacf892df85dc06f36d63c2f97a08` plus the uncommitted working tree. Version 0.1 (27); the number alone does **not** identify this candidate. Internal TestFlight source is separately recorded as `adeb923fc1d081b19dfe9d650b50ac9fb036535a`. No commit, installation or distribution performed in this pass. Preserve the pre-existing Margin/Follow changes and all Library data.

Scope: #122 memory-warning recovery, truthful Supertonic fallback and cached-audio eligibility, bounded inference temporary-object lifetime, and investigation of PDF repetition/#93 performance. No Watch changes, blanket device-specific quality reduction, or claim of human validation.

## Evidence and decision model

Resource owners: one reusable serial Supertonic renderer retains four ONNX sessions; playback retains file-backed chunk metadata, while Library preparation also uses the renderer. The disk cache limit is a storage budget, not a RAM limit. PDF import and shared-Margin playback are additional workloads; their presence before termination does not identify the memory owner.

Confirmed code gaps and candidate changes:

- The old memory-warning handler only enqueued model unloading. Live generation and Library work could keep scheduling, permitting sessions to load again. The candidate cancels the foreground worker, switches active Supertonic to the existing position-preserving system-speech path, and blocks new live/Library inference for 60 seconds using monotonic time. Repeated warnings extend the backoff. Model unloading preserves generated audio files. The current target stays on system speech until explicit Retry; other queued work remains saved.
- The old resource gate ran before cache lookup, rejecting usable prepared audio in Low Power Mode. Resource checks now govern fresh inference; prepared chunks and disk-cache audio remain usable. A missing chunk can still require fallback.
- The old fallback message conflated Low Power Mode and heat. The candidate identifies observed Low Power Mode, thermal pressure, or a recent iOS memory warning and gives recovery advice. It does not describe Low Power Mode as proof of low memory.
- An autorelease pool now drains Objective-C inference temporaries after each chunk. This establishes a release boundary; no measured reduction in peak or steady-state footprint is claimed.

Alternatives and limits: thread-count/quality reductions were not chosen without iPhone 14 throughput and responsiveness evidence. The renderer is already serial, and chunk caches hold URLs rather than decoded full-document audio, so neither uncontrolled concurrent models nor an all-audio-in-RAM cache is established. A synchronous inference operation may finish before cancellation/unloading takes effect. iOS can terminate an app without delivering a memory warning, so this is recovery hardening, not proof that #122 is resolved. A 60-second backoff is a conservative initial policy to test, not a measured OS recovery interval.

Local crash evidence: the only cached phone jetsam file found under Xcode DeviceLogs is `JetsamEvent-2026-09-12-071924.ips`. Its largest process is Podcasts; SpokenMarginsApp is listed suspended with 90 resident pages. It does not establish the reported newer local-build termination. No crash cause is assigned from that file. Issue #122 records the affected article and sequence, but has no attached memory trace.

PDF comparison: `App/SharedSources/PDFStructuredTextExtractor.swift` gained the page-margin repetition repair after internal Build 27. `artifacts/validation/gate-1/phone-feedback-2026-09-13/handoff.md` records owner acceptance of headers on the local phone candidate. Existing saved text/audio is intentionally unchanged; reimport as a separate item to test new extraction. The owner clarified that the tester heard a repeated passage. Inspection found that `playbackItemFinished` detached the player without advancing `currentStartOffset` when the next chunk was unavailable. During the gap, `currentCharOffset` and `currentRecoveryCharOffset` therefore returned the completed passage start; a timeout fallback could replay it. The candidate commits the next offset and clears the finished chunk length before detaching. A focused delayed-next-chunk test checks both gap offsets and actual fallback start. This transport defect also affects articles, and is present in internal Build 27; it is a plausible explanation, not a confirmed match to the tester's unidentified PDF. Contents handling remains a separate unresolved report; no blanket deduplication or source rewriting was added.

## Owner checks

Supported project platform: iPhone/iPad on iOS 18 or later; PDF Vision enhancement requires iOS 26. Specifically exercise the reported iPhone 14 and your local-test phone. Their actual OS versions and installed candidate identity should be recorded alongside results.

No reset required. Preserve original items/Margins. Use the existing shared-Margin podcast, the PDF from the report, and the article named in #122 (Spoken Margins AI Handoff: The Astra+Sol Thread Workflow for Coding). No private content was seeded or copied by this pass.

1. Normal power: play shared-Margin podcast, import PDF and article, switch to article, listen for several minutes, then repeat once. Record pass/fail, elapsed time, and whether audio was already prepared.
2. Low Power Mode: play a fully prepared item and confirm the Supertonic voice remains; try an unprepared item and confirm the explanation names Low Power Mode. Turn it off and use the existing Retry control; check source position and selected voice.
3. On iPhone 14: compare scrolling and navigation while a new item renders versus after preparation completes, using the same content. Record whether the problem is UI delay, audio gaps, or both.
4. PDF: reimport the NIST CSF 2.0 PDF from the prior header report as a disposable item; listen across page boundaries and confirm meaningful body text remains. For passage repetition, record the exact repeated words/page and whether it follows pause, seek, voice fallback or chapter change.

If a termination recurs, save Xcode's device memory/termination report before further reproduction. Settings' existing Developer diagnostic recording can preserve playback offsets, worker activity, power/thermal state and main-loop delays; it does not currently measure RAM. Xcode Memory Gauge/Allocations provides the missing footprint/owner evidence. Compare the first and repeated transitions, with and without concurrent rendering; stop reproducing after one useful failure capture. No full Library reset or repeated destructive reimport is needed.

All owner checks remain pending. Broad suites, device performance profiling, real-memory-pressure canary and full release gates are deferred by the owner's explicit instruction; run the full release gate before any future internal TestFlight push.

## Automated evidence

Final-source focused check: **41 tests passed, 0 failed, 0 skipped**, using the iPhone SE (3rd generation) simulator on iOS 18.6. This includes 37 Supertonic adapter/policy tests and four PDF extraction/outline tests. The app and test bundle compiled as part of the successful test action. `focused-final.log`, `focused-final.xcresult`, and `test-results.json` retain evidence. The existing AppBehavior plan intentionally excludes the real bundled-model synthesis canary; that canary, physical memory/performance measurement and device builds were not run in this bounded pass. `git diff --check` and the test inventory passed.

The initial iOS 26.5 attempt compiled the earlier candidate but stalled before tests executed and was terminated; `focused.log` is incomplete, not a passing result. The final iOS 18.6 retry includes the later passage-boundary repair. No broad suite was run. No claim of human validation or measured iPhone 14 performance improvement is made.
