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
- Current internal candidate: version 0.1 (21) from the accepted `main` runtime was uploaded successfully on 2026-08-27, completed App Store Connect processing, and is available to the internal `Margins` group; see `artifacts/validation/testflight-external/build-21/build-21-testflight-upload.md`. Build 20 had already been uploaded on 2026-08-24 and is superseded; do not submit it externally.
- Next bounded candidate: Build 22 is reserved for the renewed #84 media-seek reconvergence fix on `codex/testflight-triage`. Its automated evidence is `verified`; it is not accepted into `main`, uploaded, distributed, or `human_validated` until the product owner completes the recorded device checklist and makes that release decision.
- Next integrated candidate: Build 23 combines the complete quality-of-life program, the private experience overhaul, and the one-way sharing foundation on `codex/build-23-release`. Integration work may consume the exact verified Build 22 patch before its human decision, but Build 23 must not be distributed until that decision is recorded. Sharing also remains unavailable outside own-device validation until the rights and provenance gate in #14 is accepted.
- `main` represents the released runtime plus explicitly accepted release-integration changes. Governance- or evidence-only commits may follow the released source commit; runtime changes may enter `main` only through a recorded product-owner release decision.
- When a later build reaches the largest distributed audience, update this section in the same change that advances the release lanes.

## Active Branches

Only these branches are active development lanes:

| Branch | Role | Current authorized scope | Merge target |
| --- | --- | --- | --- |
| `main` | Released and accepted integration runtime plus repository governance | Documentation, validation evidence, distributed runtime, and product-owner-accepted release integration | N/A |
| `codex/testflight-triage` | Active Build 22 rapid-fix lane, based on the accepted Build 21 integration runtime | #84 end-to-end media scrub/seek reconvergence only | `main` after product-owner acceptance; exact verified patch may also enter `codex/build-23-release` |
| `codex/sharing-next` | One-way sharing source lane | Sharing foundation issues #17, #18, #67, and #68; audit reconciliation #81 | `codex/build-23-release` once, then freeze the source lane |
| `codex/quality-of-life-next` | Quality-of-life source lane | Complete non-Watch program: #34, #64, #72, #73, #61, #79, #74, #69, #76, #77, #86, and #87, plus the accepted temporary experience-overhaul integration | `codex/build-23-release` once, then freeze the source lane |
| `codex/experience-overhaul` | Temporary private-experience integration branch | Native Library, Sources, and local Margins shell; typed intake; item, playback, recording, Timeline, onboarding, and storage presentation over the verified quality-of-life runtime | `codex/quality-of-life-next`, then delete the temporary branch after integration |
| `codex/build-23-release` | Unified Build 23 integration and release lane | Complete quality-of-life and experience work; one-way sharing foundation; recipient import and provenance presentation; exact verified Build 22 seek patch | `main` only after all Build 23 release gates and product-owner acceptance |

All other local and remote branches are historical and read-only. Their commits may be inspected or deliberately extracted, but work must not resume directly on them without a product-owner plan change. In particular, `codex/sharingV1` is source material for reconciliation into `codex/sharing-next`; it is not an active integration branch.

## Merge Direction

Permitted flow:

```text
codex/testflight-triage ───────────────► main  (Build 22 acceptance only)
                 │
                 └─────────────────────► codex/build-23-release  (exact verified patch)

main ──────────────────────────────────► codex/sharing-next
main ──────────────────────────────────► codex/quality-of-life-next
codex/quality-of-life-next ────────────► codex/experience-overhaul

codex/experience-overhaul ─────────────► codex/quality-of-life-next  (temporary integration only)
codex/quality-of-life-next ────────────► codex/build-23-release  (one integration)
codex/sharing-next ────────────────────► codex/build-23-release  (one integration)
codex/build-23-release ────────────────► main  (accepted Build 23 only)
```

Rules:

- Never merge `codex/sharing-next` directly into `codex/quality-of-life-next`, `codex/experience-overhaul`, or the reverse. Their first shared descendant is `codex/build-23-release`.
- Merge `codex/experience-overhaul` into `codex/quality-of-life-next` before either quality-of-life or sharing work enters `codex/build-23-release`.
- Merge each source lane into `codex/build-23-release` once. Resolve structural conflicts in favor of the experience overhaul's navigation and presentation composition, preserve sharing's package/import/playback contracts, and regenerate project and package-resolution artifacts from the resolved source rather than manually blending generated files.
- Build 22 acceptance remains a separate human decision. If its exact verified patch enters Build 23 before that decision, record it as inherited `verified` evidence and block Build 23 distribution until the Build 22 result is known.
- Do not move unreleased runtime work from a feature lane into triage merely to make it ship sooner.
- Dependency ordering inside a lane is represented by issue state, commits, tests, and feature flags—not additional persistent branches.

## TestFlight Triage Lane

`codex/testflight-triage` accepts a change only when all of the following are true:

1. The behavior exists in the released TestFlight baseline.
2. The defect is reproducible or supported by specific tester/device evidence.
3. The fix is bounded and does not introduce a new product feature, schema family, or architecture.
4. Focused regression evidence can be added without claiming product-owner validation.
5. The change can be described in the next TestFlight handoff with exact in-scope and out-of-scope behavior.

Issue #84 was explicitly readmitted by the product owner on 2026-08-30 after the scrubber again dislocated from audible playback on current private branches. The bounded outcome is one acknowledged media-seek transaction in the shared playback spine, with combined regression evidence proving both historical failure modes in one sequence: periodic playback updates cannot fight an active drag, and after release the accepted player time, app timeline, persisted position, elapsed/remaining labels, and Now Playing state reconverge and continue advancing. The implementation at `22caa72` is `verified`; Build 22 assignment, app-build regeneration, and product-owner validation evidence remain to be recorded without claiming acceptance.

The accepted post-Build-19 fixes through `22788cb` include the earlier playback, recording-continuity, scrubbing, transport, PDF, and podcast-resolution corrections tracked through issues #56, #71, #78, #83, #84, and #85. The renewed #84 evidence proves that the earlier isolated scrubbing checks were insufficient; the issue remains open until Build 22 is exercised and accepted by the product owner.

For each TestFlight cycle:

1. Start triage from the currently recorded released baseline.
2. Add only admitted regression fixes.
3. Run proportional automated verification and prepare the product-owner handoff.
4. Merge accepted fixes into `main` and record the new distributed build and source SHA.
5. Recreate `codex/testflight-triage` from the new `main` so it does not become a permanent divergent product version.

## Sharing Lane

`codex/sharing-next` is the source lane for the one-way Build 23 foundation, not a branch per sharing issue. After its one integration into `codex/build-23-release`, further Build 23 sharing experience work belongs only on the release lane under the frozen seams below.

### Phase 1: Foundation

- #17: reviewed interjection packages and sender preview.
- #18: recipient import and distinct commentary layers.
- #67: deterministic cleanup and bounded anchor context for reviewed representations.
- #68: accessible provenance-aware Timeline presentation.
- #81: reconcile the existing `codex/sharingV1` implementation with current source and record implementation versus verification status.

These issues form one end-to-end boundary: prepare, preview, export, import, and distinguish shared commentary. Rights and provenance decisions from #14 gate external enablement even when implementation remains disabled behind a feature flag.

### Later release: Co-op Replies

- #19 begins only after the Build 23 one-way foundation is implemented, verified, and product-owner accepted.
- Co-op replies require a later release-lane decision; they are not Build 23 work.
- #26 AI synthesis is not authorized by this lane plan.

## Quality-of-Life Lane

`codex/quality-of-life-next` supplies the complete non-Watch quality-of-life program and integrated private experience overhaul to Build 23. All source work remains a per-issue or tightly complementary issue-group commit series on this single branch; do not create issue-specific persistent branches.

Earlier Build 21 and Build 22 references on the branch describe local automated evidence only and are superseded: Build 21 is the current internal hotfix line, Build 22 is the renewed #84 triage candidate, and the unified candidate is Build 23.

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

## Temporary Experience Overhaul Lane

The product owner authorized `codex/experience-overhaul` on 2026-08-28 as a bounded temporary integration branch from `codex/quality-of-life-next`. Its purpose is to recompose the already implemented private quality-of-life capabilities into a scalable native experience without importing the sharing lane or changing SessionKit contracts.

Authorized scope:

- adaptive Library, Sources, and local Margins destinations;
- app-layer navigation and presentation models;
- typed intake routing over existing import handlers;
- item detail, Now Playing, guarded recording, local Timeline provenance, onboarding, and offline-storage presentation;
- semantic design tokens, accessibility behavior, focused regressions, validation evidence, and the product/spec updates required by this direction.

Explicitly excluded:

- reviewed sharing packages, imported people, recipient preview, co-op replies, or any other `codex/sharing-next` runtime;
- Watch, new SessionKit commands or snapshot/schema fields, publisher-artwork dependencies, account/profile concepts, remote execution, and speculative disabled controls;
- distribution or a claim of `human_validated` status without a separate product-owner decision and hands-on validation.

The branch merges only into `codex/quality-of-life-next`. Delete it after that integration; it must not become a persistent release lane. Sharing is composed only after quality-of-life reaches `codex/build-23-release`, where the design overhaul owns navigation and screen composition and sharing owns its reviewed-package, import, provenance, and playback semantics.

## Build 23 Unified Release Lane

`codex/build-23-release` is the only branch where the quality-of-life/experience source and sharing source may be composed. It exists to complete a coherent release, not to preserve both branches' duplicate screens.

### Product contract

The sender experience is a four-stage state machine:

1. **Select:** choose the final set of Margins and confirm the item and rights context. Starred Margins may be preselected, but the final set is explicit.
2. **Review:** inspect a compact list, edit one Margin in detail at a time, choose its representation, and batch-prepare eligible representations without losing per-Margin review status.
3. **Recipient preview:** render what the other person will receive from the successfully round-tripped, verified archive. Any package-affecting mutation invalidates this preview and requires regeneration.
4. **Share:** invoke the system share surface with the exact verified `.spokenmargins` file represented by the preview.

The recipient experience is preview, import, then an explicit behavior choice. Imported Margins remain a distinct provenance-aware layer, default to Companion voice, and never autoplay. When recipient-supplied source material is missing, the import route must enter Add Source and return to the pending import rather than require the user to reopen the file.

### Frozen ownership boundary

- Experience-overhaul composition owns navigation, semantic design tokens, adaptive screen structure, sheets, toolbars, and persistent-player placement.
- Sharing owns reviewed-package schemas, archive signing/verification, bounded anchors, representation preparation, imported-layer semantics, and shared-Margin playback behavior.
- Session and persistence integration is an additive union; neither source lane may discard the other lane's durable fields or migrations.
- `Package.swift` contains each target and ZIP dependency once. `Package.resolved` files and the Xcode project are regenerated after source conflicts are resolved.
- Root composition, app-model integration, shared SessionKit models/protocols/engine, project generation, contract validators, and release evidence are steward-owned seams during parallel work.

### Release gates and stopping rules

Build 23 may be called `implemented` when all in-scope paths exist, and `verified` only after contract validators, the complete SessionKit suite, focused app tests, generic simulator/device builds, and the scoped route checklist pass. It remains not `human_validated` until the product owner completes its handoff.

Stop distribution or acceptance if:

- Build 22's seek behavior is rejected or remains undecided;
- #14 rights/provenance policy is unresolved for any externally enabled sharing path;
- recipient preview is derived from draft UI state rather than the exact verified archive;
- editing after preview can share stale bytes;
- imported and local Margins are distinguishable only by color, imported audio autoplays, or import silently changes source ownership;
- a merge drops storage, playback, anchor, provenance, or migration behavior from either source line;
- Watch runtime, co-op replies, accounts, hosted storage, or AI synthesis enters the diff;
- generated project/package files are hand-merged without a clean regeneration check.

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
