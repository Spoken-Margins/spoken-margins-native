# Release Lanes

This document is the authoritative routing plan for implementation work in Spoken Margins. Branches represent release lanes, not individual issues or every dependency between issues.

The purpose of this plan is to reduce three risks:

- **Human routing error:** a reasonable request is accidentally sent to the wrong release line.
- **Agent routing error:** an agent infers a new branch or combines scopes differently from prior work.
- **Technical integration risk:** dependent work is developed against incompatible playback, contract, persistence, or project state.

If a GitHub label, issue comment, local branch name, older planning document, or agent instruction conflicts with this file, stop and reconcile the conflict before implementation. An explicit product-owner direction may change the plan, but this file must be updated first.

## Released Baseline

- Largest distributed audience: TestFlight Build 19, version 0.1 (19).
- Released source commit: `738c743e202f5e700f4d6975adee52862f63c69f`.
- Upload evidence: `artifacts/validation/testflight-external/build-19/build-19-testflight-upload.md`.
- Accepted integration baseline: TestFlight triage fixes through `22788cb96a6763d186a607961ee229c5b01d6156` have been accepted into `main` by explicit product-owner direction. Their automated evidence is `verified`; this record does not invent physical-device validation or claim that a later build has reached the largest distributed audience.
- Next distribution candidate: version 0.1 (21) from the accepted `main` runtime was uploaded successfully on 2026-08-27, completed App Store Connect processing, and is available to the internal `Margins` group; see `artifacts/validation/testflight-external/build-21/build-21-testflight-upload.md`. Build 20 had already been uploaded on 2026-08-24 and is superseded; do not submit it externally. Build 21 is reserved for the accepted TestFlight hotfix line; the quality-of-life candidate advances from its provisional local Build 21 evidence to Build 22 before upload.
- `main` represents the released runtime plus explicitly accepted release-integration changes. Governance- or evidence-only commits may follow the released source commit; runtime changes may enter `main` only through a recorded product-owner release decision.
- When a later build reaches the largest distributed audience, update this section in the same change that advances the release lanes.

## Active Branches

Only these branches are active development lanes:

| Branch | Role | Current authorized scope | Merge target |
| --- | --- | --- | --- |
| `main` | Released and accepted integration runtime plus repository governance | Documentation, validation evidence, distributed runtime, and product-owner-accepted release integration | N/A |
| `codex/testflight-triage` | Idle rapid-fix lane, currently aligned with the accepted integration baseline | No active issue; a later reproducible TestFlight regression requires explicit admission | `main` |
| `codex/sharing-next` | Next major numbered feature release | Direct-share policy #14; testable one-way sharing MVP: #17, #18, #67, #68, and #81; cross-edition podcast resolution through #27; portable proposal-contract slice of #88; then co-op replies #19 | `main` when the numbered sharing release is accepted |
| `codex/quality-of-life-next` | Next numbered quality-of-life release | Complete non-Watch program: #34, #64, #72, #73, #61, #79, #74, #69, #76, #77, #86, and #87 in the ordered phases below | `main` when the complete numbered quality-of-life release is accepted |

All other local and remote branches are historical and read-only. Their commits may be inspected or deliberately extracted, but work must not resume directly on them without a product-owner plan change. In particular, `codex/sharingV1` is source material for reconciliation into `codex/sharing-next`; it is not an active integration branch.

## Merge Direction

Permitted flow:

```text
codex/testflight-triage ───────────────► main

main ──────────────────────────────────► codex/sharing-next
main ──────────────────────────────────► codex/quality-of-life-next

codex/sharing-next ────────────────────► main  (numbered release only)
codex/quality-of-life-next ────────────► main  (bounded release only)
```

Rules:

- Never merge `codex/sharing-next` directly into `codex/quality-of-life-next`, or the reverse.
- After a TestFlight triage release reaches `main`, merge `main` into both feature lanes before further integration work.
- Do not move unreleased runtime work from a feature lane into triage merely to make it ship sooner.
- Dependency ordering inside a lane is represented by issue state, commits, tests, and feature flags—not additional persistent branches.

## TestFlight Triage Lane

`codex/testflight-triage` accepts a change only when all of the following are true:

1. The behavior exists in the released TestFlight baseline.
2. The defect is reproducible or supported by specific tester/device evidence.
3. The fix is bounded and does not introduce a new product feature, schema family, or architecture.
4. Focused regression evidence can be added without claiming product-owner validation.
5. The change can be described in the next TestFlight handoff with exact in-scope and out-of-scope behavior.

There is no current active triage implementation item. The accepted post-Build-19 fixes through `22788cb` include the bounded playback, recording-continuity, scrubbing, transport, PDF, and podcast-resolution corrections previously tracked through issues #56, #71, #78, #83, #84, and #85. They remain product-owner validation work in Build 21 unless new failing evidence justifies another admitted triage change.

For each TestFlight cycle:

1. Start triage from the currently recorded released baseline.
2. Add only admitted regression fixes.
3. Run proportional automated verification and prepare the product-owner handoff.
4. Merge accepted fixes into `main` and record the new distributed build and source SHA.
5. Recreate `codex/testflight-triage` from the new `main` so it does not become a permanent divergent product version.

## Sharing Lane

`codex/sharing-next` is one major-feature lane with ordered phases, not a branch per sharing issue.

### Phase 1: Foundation

- #14: direct-share rights and provenance policy for referenced versus embedded items.
- #17: reviewed interjection packages and sender preview.
- #18: recipient import and distinct commentary layers.
- #67: deterministic cleanup and bounded anchor context for reviewed representations.
- #68: accessible provenance-aware Timeline presentation.
- #81: reconcile the existing `codex/sharingV1` implementation with current source and record implementation versus verification status.

These issues form one end-to-end boundary: prepare, preview, export, import, and distinguish shared commentary. Rights and provenance decisions from #14 gate external enablement even when implementation remains disabled behind a feature flag.

Product-owner revision, 2026-08-29: package terminology and transport must distinguish a reusable **source** (for example an RSS feed, newsletter, blog, or social feed) from the discrete **item** being listened to. URL-backed items share source/item references and never redistribute the item payload by default. A linkless native-text or document-derived item may be embedded only after the sender explicitly confirms that the share is private and that they have the right to share the item. Declining that confirmation must not block Margin export; the package instead declares that the recipient must supply the same item. App-authored sample text may be embedded without a user rights assertion because its provenance is known. Missing canonical URLs must never be represented by invented public URLs or reported as persistence failures.

Product-owner revision, 2026-08-29 (playback validation): sender review must use one compact, readable inline transcript in which words and bracketed pause markers can be tapped to remove or restore them; it must not duplicate the same edits as a vertical toggle list. Imported-item presentation must show one Listening Map generation request and a play/resume action without requiring a long scroll. Companion playback must sound a cue and expose **Listen** and **Dismiss** on the playback screen and Live Activity when a shared Margin is reached. The playback screen must also expose an auto-play control that selects automatic versus opt-in shared-Margin playback without creating a second persistence model.

### Phase 1A: Testable podcast-sharing MVP

The product owner expanded the sharing foundation on 2026-08-29 so it can reach a trusted-tester MVP instead of stopping at package-only infrastructure.

- #27 is authorized first as the cross-edition benchmark and then as the production evidence/resolver gate. Automatic verified placement requires zero false-confident placements in the held-out benchmark and p95 error no greater than 1.5 seconds. The implementation must retain ambiguous, absent, unresolved, and wrong-source outcomes instead of forcing placement.
- A sender timestamp remains a hint. A silent timestamp fallback is authorized only when strong episode identity and a benchmark-approved duration guard hold, transcript and acoustic evidence are genuinely unavailable, and no evidence contradicts the placement. It is never eligible after ambiguity, absence, digest mismatch, or wrong-source detection.
- #88 is authorized only for the portable scene-map proposal schema, validation, deterministic `.spokenmargins` transport, and proposal persistence. Offline podcast map generation, proposal activation, summary bridge playback, and Skim controls remain post-MVP and unauthorized.
- After a recipient confirms an integrity-checked import, the existing podcast download coordinator may treat that explicit import as a user-initiated download. It must show progress/cancel/retry and must not autoplay.
- Add a same-device "Create recipient test session" route that exercises the real archive, verification, import, persistence, resolver, and commentary-playback path in a distinct local imported layer.
- Sharing is exposed without a tester-facing Settings toggle in the first dedicated sharing TestFlight build, but incomplete routes remain unregistered until the complete end-to-end path is verified. #14 still gates sharing with other people outside the product owner's own-device validation.

The `.spokenmargins` package is still unpublished. This lane is authorized to replace its pre-release v1 schema and fixtures in place, without a legacy decoder, before any external user relies on it.

### Phase 2: Co-op Replies

- #19 begins only after the one-way foundation is implemented and verified.
- Co-op replies remain in `codex/sharing-next`; do not create a persistent child branch.
- #26 AI synthesis is not authorized by this lane plan.

## Quality-of-Life Lane

`codex/quality-of-life-next` delivers one numbered non-Watch quality-of-life release. All work remains a per-issue or tightly complementary issue-group commit series on this single branch; do not create issue-specific persistent branches.

Its next TestFlight candidate is Build 22. Earlier Build 21 references on the branch describe local automated evidence only and are superseded because the product owner reserved Build 21 for the accepted hotfix distribution.

### Authorized ordered program

1. **Prepared core — #34 and #64.** Remove reachable Kokoro/MLX runtime and configuration, establish exact Supertonic render identity, durable prepared-audio manifests and chunks, typed recovery/cancellation state, source-to-media mapping, complete offline media, and truthful Lock Screen duration/scrubbing.
2. **Offline lifecycle — #72 and #73.** Establish one storage ledger and budget, reservations, protections, deterministic eviction, adoption, and an injected power/thermal/storage-aware preparation horizon.
3. **Books and local audio — #61 and #79.** Add canonical DRM-free EPUB ingestion and app-owned audiobook import without conflating authored source structure, playable media, or offline ownership.
4. **Charging preparation — #74.** Add opt-in charging-only `BGProcessingTask` execution using the same durable jobs, manifests, storage reservations, and renderer as foreground work.
5. **Guided onboarding and followed sources — #69, #76, and #77.** Add bounded remotely configurable onboarding, shared feed parsing/discovery, explicit subscriptions and inbox state, readable-page import, and suggestion decisions. Issue #69 includes the EPUB and audiobook routes shipped in this release.
6. **Library comfort and sleep timer — #86 and #87.** Add metadata-only search, typed filters/sorts, and session-scoped timed/end-of-chapter sleep modes.
7. **Single-release integration.** Keep unfinished paths unexposed, deploy and validate the production onboarding manifest/audio, update specifications/evidence/legal/diagnostics, and prepare the product-owner handoff only after the complete non-Watch program is implemented and verified.

Each phase may begin only when its dependency invariants have focused automated evidence. Background preparation must remain disabled until durable manifests and the storage ledger are verified. The release stops if partial audio advertises a complete scrubber, rendering can exceed reservations, EPUB structure is flattened, foreground/background output diverges, following imports automatically, remote onboarding introduces executable routes, or Watch runtime work appears in the diff.

### Explicitly out of scope

- #75: untethered Apple Watch playback and interjection sync.
- Any new Watch playback, transfer, rendering, connectivity, or synchronization work.

Existing dormant Watch artifacts may be counted by the storage ledger, but this authorization does not permit changing or enabling Watch runtime code. Issue #75 remains queued for a later product-owner release decision.

## Work-In-Progress And Branch Creation Rules

- The repository remains single-agent by default.
- Keep one active implementation target at a time unless the product owner explicitly changes the workflow.
- Do not create branches for individual issues inside an active lane.
- Temporary recovery or experiment branches require explicit product-owner approval and must name their merge target and deletion condition.
- Keep each issue or tightly complementary issue group identifiable as a commit series even when it shares a release branch.
- Incomplete runtime paths must remain disabled through an existing, documented capability or feature flag. Do not invent a new flag without updating its contract, runtime, validator, and tests together.

## Agent Start Checklist

Before editing implementation code, report:

1. Current branch and base SHA.
2. Issue or issue group being addressed.
3. Why that work belongs to the branch under this document.
4. Expected files or runtime surfaces.
5. Verification evidence planned.
6. Any dirty or historical work that must be preserved.

Stop before implementation when:

- the issue is not authorized for the current lane;
- the request would merge feature lanes together;
- a triage fix expands into a new contract or product feature;
- required work exists only on a historical branch and has not been deliberately reconciled;
- a new branch appears necessary but the product owner has not changed this plan.

## Status And Validation

Use repository status terms exactly:

- `implemented`: a runtime or user path exists.
- `verified`: automated checks or developer evidence support it.
- `human_validated`: the product owner exercised and accepted it.

Every release-lane handoff must name the build number and commit SHA, supported devices and OS versions, in-scope and out-of-scope flows, known issues, reset and sample-data instructions, diagnostics location, automated verification, and the product-owner pass/fail checklist.

## Changing This Plan

This plan is intentionally small. A product-owner decision may add, remove, rename, or repurpose a lane. Make that change here first, then update branch refs, GitHub labels or milestones, and implementation work. Do not maintain a second competing branch plan elsewhere in the repository.
