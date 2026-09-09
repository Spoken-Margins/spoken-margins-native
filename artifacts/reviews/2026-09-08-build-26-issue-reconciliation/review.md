# Build 26 issue reconciliation and next improvements

Reviewed 2026-09-08. Branch: `codex/provisional-next`; clean starting HEAD: `fdbceda0dd840a541653ac6fe84957ffd6bec704`. No runtime, release-lane, branch, or distribution changes were made.

## Evidence and disposition

Build 26 is version 0.1 (26), exact uploaded source `9c967793e7a0e86c26a3030390818e87d830723b`. The product owner accepted runtime `cd2bf54b5b6e11d7bce3036861f19aad1978636d`; the release cut adds numbering/evidence. Current HEAD differs from the uploaded source only in rollout documentation. The release manifest records verified at the exact source, with 425 app/adapter/UI tests plus fast checks. Distribution evidence records Testing in internal Margins with six testers. Build 21 remains external.

Sources:
- [Owner acceptance](../../validation/gate-1/2026-09-08-build-26-acceptance.md)
- [Build 26 handoff](../../validation/testflight-external/build-26/build-26-testflight-upload.md)
- [Exact release manifest](../../test-runs/20260908-100107-133593-release/manifest.json)
- [September 7 bounded owner feedback](../../validation/gate-1/2026-09-07-device-feedback.md)
- [September 8 diagnostic evidence](../../validation/gate-1/2026-09-08-device-feedback.md)
- [Authoritative release lanes](../../../docs/release-lanes.md)

The acceptance is candidate-level human_validated, not a fabricated per-device/per-flow matrix. Earlier failed experiments remain historical evidence. No fresh physical flow was exercised during this review.

29 GitHub issue bodies were updated with current disposition and evidence links while preserving original reports/checklists. All 29 bodies and states were fetched after mutation and matched the intended update.

Closed as completed on the accepted candidate:
- #84 scrubber lifecycle/progress
- #99 cross-source Follow suggestions
- #101 feed-entry title propagation
- #102 canonical completion and Continue Listening
- #103 assistant rendering at the current position
- #104 assistant transport and current-target Retry

Updated and retained open:
- #98 preparation recovery, #91 original article Follow/import journey, #95 historical missing-note/freeze investigation
- #93/#97 physical performance measurements
- #64/#73 durable audio and resource-policy matrices; #76/#77 full subscription/suggestion scope; #78 representative PDF corpus
- #17/#18/#27 integrated, bounded-accepted sharing/alignment; #81 remaining audit checklist
- #19/#70/#82 later co-op/classroom work, distinguished from the available one-way foundation
- #88/#89/#90 implemented private maps/Skim with remaining device, grounding, and resource gates
- #106/#107/#108 broader UI proposals, distinguished from already accepted stabilization

Before/after issue bodies and original states are retained in [issue-changes.json](issue-changes.json). Issue comments were read for these updates, including the original audit and added scope; no historical comment was deleted. Existing issue labels were preserved. Closed historical reports unrelated to the Build 26 delta and unchanged future proposals were not rewritten merely to attach a newer build number.

## Decision model

**User outcome:** make an existing populated Library and its accumulated thoughts easier to use, while preserving accepted listening, capture, and import behavior.

**Available resources:** canonical item/session/interjection IDs; local transcripts and cleaned/display text; Margin detail copy/retry/Timeline actions; existing source completion, download, preparation, and export actions. These support useful improvements without new cloud services, models, package formats, or playback engines.

**Constraints:** one implementation agent/lane; preserve the populated Library; serial inference and immediate playback precedence; only the owner validates flows. Broad #100/#106/#107/#108/#109 redesign needs a separate lane decision. #14 still gates external sharing. Watch, co-op, classroom and figure narration are not authorized next-candidate implementation.

**Mechanisms and risk:** presentation and local filtering have a small failure surface when derived from stable IDs. Navigation can change the selected session or playback target. Preparation controls can affect inference ownership. Generation introduces resource, grounding, and supported-device risks. These are different layers, not interchangeable UI tasks.

**Decision criteria:** direct benefit to repeated owner workflows, confidence from observed gaps, extent of existing primitives, regression blast radius, reversibility, and whether success can be tested narrowly. Benefit/risk ratings below are qualitative engineering judgments, not measured usage or effort estimates. Assumption: retrieval of accumulated Margins is a frequent enough task to outweigh purely visual polish; the owner audit and current populated Library support, but do not quantify, it.

## Recommended order

| Order | Bounded improvement | Benefit / risk | Evidence and acceptance |
| --- | --- | --- | --- |
| Conditional first | #98: keep a usable start/recovery path while opening audio prepares | High if reachable blockage / medium | Item Detail still replaces Play with a noninteractive preparing indicator. Force queued, paused, failed, and missing-manifest states; if no usable path exists, fix this before optional features. Reuse supported live-start semantics and preserve queue ownership. |
| 1 | #94 with the smallest #109 slice: local Margins text search, All/Item scope, source context and existing Timeline navigation | High / low–medium | Current screen only filters All/Attention/Recent and opens a detail sheet. Search existing text locally; filter a loaded snapshot rather than reload all sessions for each keystroke. Test case-insensitive partial/phrase matching, missing transcripts, duplicate source titles, no results, and correct assistant/source anchors. |
| 2 | #107: useful Item Detail hierarchy and existing actions | Medium–high / low–medium | Put sessions before chapters, use Continue, consolidate secondary actions, and show specific readiness only when useful. Empty Overview is already omitted and Source Reference is already selectable. Reuse canonical completion/download/render actions; do not create screen-local state or generate new overviews. |
| 3 | #92: clearer Margin previews using already available approved text | Medium / low for presentation, higher if generation is needed | MarginRow.preview already prefers displayText, cleanedTranscript, then transcript. Establish whether approved per-Margin summaries actually exist before claiming a summary-only UI change. Preserve originals/provenance and useful fallbacks; never initiate bulk generation just to populate cards. |
| 4 | #108: compact Library chrome and margin-count sort | Medium / low–medium | Safe-area and completion fixes already shipped. Bound this to density and canonical counts, test duplicate titles and large libraries, and keep touch targets. The requested default completion filter materially affects discovery; handle it as an explicit later decision with an obvious reveal-all control. |

For the first feature slice, scope #109 to retrieval and source identity. Group by item ID: the current screen groups and counts by item title, so two different sources with the same title collapse visually. Retain existing Copy with Context and Open in Timeline. Move session export only after its replacement route is complete. Do not add a broad Fix All: missing audio, context failure, and pending transcription require different handling.

## Alternatives and omission checks

- **More performance refactoring:** #93/#97 remain important, but first obtain a paired trace on the populated device. Quick Add responsiveness was accepted; generic CPU contention has not been established. Do not spend another cycle rewriting scheduling on that assumption.
- **Interactive swipe navigation (#106):** useful polish, but crosses gesture ownership beside the newly accepted scrubber. Lower benefit/risk than local retrieval; test partial cancellation and repeated drags before any install.
- **Player restyling (#100):** smaller implementation risk but less functional value than finding a saved thought. Keep it separate from transport changes.
- **Skim/maps (#88–#90):** already implemented; the next work is device/grounding/resource evidence, not a new feature announcement.
- **Figure narration (#105), Watch (#75/#96), co-op/classroom:** substantially wider runtime, resource, contract, or policy surfaces. Defer.
- **Sharing:** bounded sender/recipient validation does not resolve #14 or all negative paths. This review does not recommend external promotion.
- **Missing notes (#95):** no assertion that old lost/inaccessible content was recovered.
- **Persistence:** the historical intermittent SQLite IOERR_VNODE test failure remains undiagnosed despite the later passing release gate. A pass is not a demonstrated repair.

## Audit and stopping rules

The prior failure mode to catch is treating passing automated checks or a candidate release acceptance as evidence that every user journey and future proposal is complete. This review ties changes to exact source/evidence, preserves negative history, and keeps narrower acceptance gaps open.

For search, compare the existing browsing route with search on the same populated Library: can the owner locate several remembered thoughts with correct source/anchor and fewer steps? Stop if results cross item/session identity, typing triggers storage-wide reloads, navigation changes playback unexpectedly, or audio-only notes become inaccessible. If search does not improve retrieval, reconsider the prioritization rather than expand it into a redesign.

For readiness, falsify the remaining risk with a controlled preparing state and bounded recovery action. The UI mechanism alone is not a new reproduction of the historical five-minute stall. Do not request another five-minute wait or a Library reset.

For any implementation, first record the authorized scope in release-lanes.md where required, then use the repository fast/app checks and scoped UI seams; add adapter/speech-canary evidence if playback scheduling changes. Only owner acceptance advances the new flow to human_validated. Stop after the bounded slice passes its evidence and owner check; do not silently add generation, new contracts, or broad navigation work.

This was an issue/evidence review, not implementation: existing exact-build verification was inspected rather than rerun. The saved audit files are uncommitted.

