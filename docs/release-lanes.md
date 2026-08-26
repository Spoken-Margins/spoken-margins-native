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
- `main` represents the released runtime. Governance- or evidence-only commits may follow the released source commit, but unreleased runtime changes must not remain on `main`.
- When a later build reaches the largest distributed audience, update this section in the same change that advances the release lanes.

## Active Branches

Only these branches are active development lanes:

| Branch | Role | Current authorized scope | Merge target |
| --- | --- | --- | --- |
| `main` | Released runtime and repository governance | Documentation, validation evidence, and runtime changes already distributed to the largest TestFlight audience | N/A |
| `codex/testflight-triage` | Rapid fixes for reproducible behavior already shipped from `main` | Issue #83 and later product-owner-approved TestFlight regressions | `main` |
| `codex/sharing-next` | Next major numbered feature release | Sharing foundation issues #17, #18, #67, and #68; audit reconciliation #81; then co-op replies #19 | `main` when the numbered sharing release is accepted |
| `codex/quality-of-life-next` | Later numbered quality-of-life release | Initially only prepared core audio issues #34 and #64 | `main` when a bounded quality-of-life release is accepted |

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

Issue #83 is the current active triage item. Issues #56, #71, and #78 already have implementation on the post-Build-19 line and remain human-validation work unless new failures require additional changes.

For each TestFlight cycle:

1. Start triage from the currently recorded released baseline.
2. Add only admitted regression fixes.
3. Run proportional automated verification and prepare the product-owner handoff.
4. Merge accepted fixes into `main` and record the new distributed build and source SHA.
5. Recreate `codex/testflight-triage` from the new `main` so it does not become a permanent divergent product version.

## Sharing Lane

`codex/sharing-next` is one major-feature lane with ordered phases, not a branch per sharing issue.

### Phase 1: Foundation

- #17: reviewed interjection packages and sender preview.
- #18: recipient import and distinct commentary layers.
- #67: deterministic cleanup and bounded anchor context for reviewed representations.
- #68: accessible provenance-aware Timeline presentation.
- #81: reconcile the existing `codex/sharingV1` implementation with current source and record implementation versus verification status.

These issues form one end-to-end boundary: prepare, preview, export, import, and distinguish shared commentary. Rights and provenance decisions from #14 gate external enablement even when implementation remains disabled behind a feature flag.

### Phase 2: Co-op Replies

- #19 begins only after the one-way foundation is implemented and verified.
- Co-op replies remain in `codex/sharing-next`; do not create a persistent child branch.
- #26 AI synthesis is not authorized by this lane plan.

## Quality-of-Life Lane

`codex/quality-of-life-next` is a release lane for bounded improvements. It is not permission to implement every issue listed below.

### Active phase

- #34: remove residual Kokoro/MLX code and formalize Supertonic render identity.
- #64: durable prepared native-text audio and Lock Screen scrubbing.

Together these form the prepared core audio boundary. The lane must establish stable render identity, durable manifests/chunks, source-to-media mapping, cancellation, invalidation, and recovery before dependent offline features begin.

### Queued candidates — not authorized for implementation

- #61: DRM-free EPUB ingestion.
- #69: remotely configurable guided-podcast onboarding.
- #72: unified offline-storage budget.
- #73: power-aware demand-window preparation.
- #74: charging-only background preparation.
- #75: untethered Apple Watch playback and interjection sync.
- #76 and #77: local source following, inbox, and engagement suggestions.
- #79: DRM-free audiobook import.

The product owner must explicitly promote a queued candidate into the active phase and update this document before implementation. Background execution and Watch work are product quality-of-life outcomes but technically high-risk integration work; the lane name does not lower their verification requirements.

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
