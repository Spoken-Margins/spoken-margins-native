# Audit method and evidence boundary

Date: September 9, 2026. Perspective: an external human-centered design review performed by an agent, not a study with recruited humans.

## Source identity

Native candidate: version 0.1 (26), branch `codex/provisional-next`, base commit `d8766c43bb0ae54ec15b3254679bba0a9378cd6e`, plus the existing compact-presentation working-tree changes. This is not the distributed TestFlight 26 binary. A fresh simulator build completed successfully. Existing app changes were preserved; the audit introduces no native runtime changes.

The current release lane takes precedence over historical prototype and design documents. In particular, the proposal preserves iOS 18+, local-first operation, deliberate imports, independent commentary layers, optional device intelligence, native audio versus text navigation semantics, and the owner's completion behavior. Watch expansion, accounts, embedded third-party chat, full podcast transcript reading, and distribution changes are outside this proposal's implementation scope.

## Method

1. Model user intent, attention constraints, durable resources, actors, mechanisms, and evidence separately.
2. Inspect the current product boundary and native views.
3. Build and traverse representative simulator states. Capture the actual interface, including denial and accessibility states.
4. Distinguish observed presentation from code-backed behavior, inferred usability risk, proposed behavior, and untested conditions.
5. Compare a presentation-only improvement, a task-first redesign, and a much broader product reinvention against continuity, effort, comprehension, and release risk.
6. Propose bounded changes with falsification tasks and a stop rule. The owner alone establishes human validation.

## Simulator conditions

iPhone 17 Pro, iOS 26.5. Standard text size `large`, light appearance; additional Library checks at accessibility-extra-extra-extra-large and in dark appearance. Restored large/light afterward. Most screen traversal used the existing `--ui-testing` seed. A second seed supplied original sample prose and a sample Margin; a NoopRecordingClient exposed recording and finish states without capturing microphone audio. The first recording attempt used the real permission path and microphone permission was denied intentionally. The observed denied-permission recovery is real; the later transcript failure is fixture-induced and is not evidence of a production transcription defect.

The default UI fixture includes generated response turns. The word “Summary” on its player is not treated as an incorrect source title or evidence of a remote AI feature. Normal launch was also inspected for the onboarding card and guided coach, but persisted onboarding progress was not reset; these are not a pristine first-run walkthrough.

The pasted-text route was exercised through its actual UI with original audit sample prose. It added a visible Library item without automatically playing. Source-player progress and return to Library at completion were observed. No audio fidelity, latency benchmark, or persistence-under-crash claim follows from this traversal.

## Coverage boundaries

Additional iPad attempt: the existing Spoken Margins Feedback iPad simulator (iPadOS 26.5) was booted and the freshly built app installed. Launch timed out after 300 seconds and the runtime snapshot exposed no inspectable targets. This is not a passing tablet walkthrough. The simulator was returned to shutdown; tablet findings remain source-backed hypotheses. A different iPad was already running an unrelated verification job and was left alone.

Direct phone inspection: Library and filters, Add router, pasted-text form and successful add, Item Detail, source and generated-turn player layouts, microphone denial, recording/finish fixture, Timeline, individual Margin detail, export configuration and action area, empty Sources and Margins, Settings, onboarding card/coach, completion, dark Library, maximum text-size Library.

Source review: source discovery and consent, voice/readiness rules, preparation queue, storage protection, Recently Deleted, sender review and recipient import, imported commentary controls, optional summaries, native text access, and adaptive navigation.

Not established: real participant comprehension; VoiceOver traversal; Switch Control; headset, Bluetooth, walking or lock-screen interaction; physical-device recording/transcription quality; long-item preparation; large real libraries; source-link ambiguity outcomes; Safari PDF/share extension proof; physical offline recovery; real cross-device packages; old-OS compatibility; professional accessibility conformance. These require follow-up evidence, not favorable assumptions.

## Severity and confidence

S1: credible threat to task completion, saved work, or trust. S2: substantial friction in a frequent task. S3: polish or occasional comprehension cost. Severity is expert judgment about impact and frequency, not measured prevalence. “Observed” describes the interface, not a verified user difficulty. “Code” establishes an implementation path, not that it is usable. “Inference” is an explicitly testable prediction.

## Preservation checks

Do not erase source/voice ownership, automatically import a followed entry, pretend partial audio is fully offline, expose full native-audio transcripts, replace active playback when browsing old notes, silently publish private Margins, call generated summaries original source, or equate a successful build with human validation. Proposals that change sorting, gestures, export routing, note editing, or root labels require a later release-plan decision.
