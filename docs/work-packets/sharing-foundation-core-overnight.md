# Overnight Work Packet: Sharing Foundation Core Reconciliation

## Copy/Paste Assignment

Work end to end on the bounded **sharing foundation core reconciliation** described in this packet. Work only on `codex/sharing-next`. Treat `codex/sharingV1` and commit `493af50` as read-only source material, not as branches to resume or commits to cherry-pick wholesale. Preserve all unrelated work. Do not merge, push, open a pull request, close issues, or claim product-owner validation.

Your objective is to establish a buildable, contract-verified foundation for issues #17, #18, #67, and audit #81 by deliberately extracting only the portable sharing contracts, fixtures, package/archive services, cleanup model, imported-layer core model, and focused tests that can land without touching active TestFlight-triage playback or app UI code. This is the first implementation slice of the sharing foundation, not completion of the user-facing flow.

Before editing, read `AGENTS.md` and `docs/release-lanes.md`, run the preflight in this packet, and report the branch, base SHA, authorized issues, expected files, verification plan, and preservation risks. Use the stopping rules instead of guessing through a cross-lane conflict.

## Why This Packet Exists

The repository contains useful sharing work on historical local branch `codex/sharingV1`, principally implementation commit `493af50` (`Implement sharing v1 and visible article acquisition`). That branch also contains unrelated playback, article-acquisition, site, project, and co-op-reply changes. It does not cleanly represent the current release-lane boundary.

The prior failure mode was treating prose or a broad historical branch as proof that sharing existed on the default branch. This packet is designed to falsify that assumption by requiring a deliberate file/behavior inventory, a buildable reconciliation on `codex/sharing-next`, reproducible tests, and explicit remaining gaps.

Prepared core audio is not the overnight target. It overlaps active TestFlight triage work in Supertonic playback, cancellation, interruption, and session-state code. Do not work on issues #34 or #64 during this packet.

## Authority And Lane

- **Working branch:** `codex/sharing-next`
- **Merge target:** `main`, but merging is not authorized by this packet.
- **Authorized issues:** #17, #18, #67, and reconciliation evidence for #81.
- **Related but not implemented here:** #68 Timeline presentation.
- **Explicitly excluded:** #19 co-op replies, #26 AI synthesis, classroom work, ActivityPub, accounts, hosted services, social-network publishing, and all quality-of-life or triage issues.
- **Feature state:** keep sharing unavailable to ordinary users. Do not enable a UI gate or externally distributed behavior.
- **Workflow:** single agent, one active implementation target.

## Objective

Produce a package-level sharing core on `codex/sharing-next` that:

1. Defines and validates a reviewed interjection package and share-revision representation.
2. Represents imported commentary as a distinct local layer without reusing package IDs as local primary keys.
3. Supports deterministic package creation, archive round-trip, digest verification, and explicit invalid-package outcomes.
4. Supports deterministic text cleanup and bounded anchor-context selection without mutating the private interjection capture.
5. Demonstrates default data minimization: unselected audio, full source text, diagnostics, filesystem paths, unrelated turns, and private representations are absent.
6. Records exactly which historical implementation was reused, rewritten, deferred, or rejected.

The overnight run is successful when this core is `implemented` and `verified` at the contract/package level. It is not a complete app flow and must not be called `human_validated`.

## Typed Boundaries

Keep these layers separate during implementation and in the handoff:

### Contract layer

- package and share-revision schemas;
- imported-layer control schema when required by the core model;
- stable schema/version identifiers already proposed by the issues;
- valid and negative fixtures;
- validator registration.

### Domain and service layer

- immutable reviewed share revisions;
- package-scoped identity versus recipient-local identity;
- selected representation and provenance;
- redaction/inclusion record;
- source identity and retained anchor evidence;
- archive/import/export and digest behavior;
- deterministic cleanup and anchor-context bounds.

### Persistence layer

- only the smallest migration-safe additions needed to persist the core imported-layer model;
- no replacement of local sessions or interjections;
- no destructive migration and no silent flattening of imported data into local captures.

### Presentation and playback layer

- out of scope for this packet;
- #68 remains the future accessible provenance presentation work;
- recipient reveal modes, inline playback, Now Playing ownership, and exact return-to-source behavior remain future app integration unless they already have isolated domain tests that require no playback-file changes.

### Verification evidence

- validators, package tests, negative fixtures, build evidence, and reconciliation notes;
- automated evidence is `verified`, not `human_validated`.

## Preflight

Run and record:

```bash
git status --short --branch
git rev-parse HEAD
git rev-parse main
git rev-parse codex/testflight-triage
git rev-parse codex/sharingV1
git log --oneline --decorate -8
```

Requirements:

- The current branch must be `codex/sharing-next`.
- The worktree must be clean before implementation.
- Do not switch the existing TestFlight-triage worktree away from its branch. Use the configured sharing worktree or create a separate worktree only if the product owner has already authorized that operational setup.
- If `main` has advanced through an accepted triage release and `codex/sharing-next` has not received it, follow `docs/release-lanes.md`: merge `main` into the sharing lane before implementation. If that merge conflicts, stop and report the conflict; do not choose historical playback code over accepted triage behavior.
- Run the baseline contract validators and SessionKit test build before extraction. Record pre-existing failures separately.

Baseline commands:

```bash
./scripts/bootstrap-python-tools.sh
.venv/bin/python scripts/validate-contracts.py
.venv/bin/python scripts/validate-surface-contracts.py
swift build --build-tests --package-path Packages/SessionKit
```

## Historical-Source Audit

Inspect, do not resume:

```bash
git show --stat --summary 493af50
git diff --name-status codex/sharing-next...codex/sharingV1
git log --oneline --reverse codex/sharing-next..codex/sharingV1
```

Before copying code, classify every candidate file or hunk into:

1. portable sharing contract/fixture;
2. package/domain/persistence core;
3. presentation/playback integration to defer;
4. unrelated historical change to reject.

Create or update:

`artifacts/validation/sharing-next/foundation-core-reconciliation.md`

The evidence file must identify:

- starting branch and SHA;
- historical source branch, tip, and relevant source commit;
- file-by-file disposition;
- known ancestry or conflict information;
- commands and results;
- implemented, verified, deferred, and rejected behavior;
- remaining work for #17, #18, #67, #68, and #81.

## Expected Source Material

These historical paths are candidates, not an instruction to copy blindly:

```text
Contracts/schemas/interjection-package.schema.json
Contracts/schemas/interjection-share-revision.schema.json
Contracts/schemas/imported-commentary-control.schema.json
Contracts/fixtures/interjection-packages/minimal-article.json
Contracts/fixtures/interjection-packages/podcast-cleaned-audio.json
Contracts/fixtures/sharing/cleanup-revision.json
Contracts/fixtures/sharing/imported-commentary-control.json
Packages/SessionKit/Sources/SessionKit/InterjectionCleanup.swift
Packages/SessionKit/Sources/SessionKit/SharingModels.swift
Packages/SessionKit/Sources/SessionKitSharing/InterjectionPackageArchive.swift
Packages/SessionKit/Sources/SessionKitSharing/PortableArticleAnchorResolver.swift
Packages/SessionKit/Tests/SessionKitTests/SharingTests.swift
docs/interjection-sharing-and-article-acquisition.md
scripts/validate-contracts.py
```

The following may be modified only when a concrete contract/package dependency requires it and focused tests prove the change:

```text
Contracts/schemas/interjection.schema.json
Contracts/docs/sessionkit-contract.md
Packages/SessionKit/Package.swift
Packages/SessionKit/Sources/SessionKit/Models.swift
Packages/SessionKit/Sources/SessionKit/Protocols.swift
Packages/SessionKit/Sources/SessionKit/InMemoryRepository.swift
Packages/SessionKit/Sources/SessionKitPersistence/SQLiteSessionStore.swift
```

Prefer the smallest migration-safe adaptation to current source. Do not replace a current file with its historical branch version.

## Forbidden Surfaces

Do not modify these during this packet:

```text
App/SpokenMarginsApp/Sources/SpokenMarginsApp/Gate1AppModel.swift
App/SpokenMarginsApp/Sources/SpokenMarginsApp/Gate1RootView.swift
App/SpokenMarginsApp/Sources/SpokenMarginsApp/StreamingSpeechQueue.swift
App/SpokenMarginsApp/Sources/SpokenMarginsApp/SupertonicSpeechPlaybackClient.swift
Packages/SessionKit/Sources/SessionKit/SessionEngine.swift
Packages/SessionKit/Sources/SessionKitAudio/AudioAdapters.swift
App/Gate2Shared/
App/SpokenMarginsGate2Widget/
Site/
project.yml
SpokenMarginsNative.xcodeproj/
```

Also exclude:

- `Contracts/fixtures/interjection-packages/reply-child-guided.json`;
- recursive reply/conversation runtime behavior from #19;
- visible article-acquisition work not required to represent a canonical source reference;
- unrelated playback-state fixes from commits `ee52649`, `8764c95`, or later triage history;
- app UI, share-sheet presentation, and feature-gate enablement.

Do not cherry-pick `493af50`, merge `codex/sharingV1`, or restore entire historical files over current versions. Extract and adapt deliberate hunks or recreate the smallest current-compatible implementation.

## Required Behaviors And Tests

At minimum, focused tests must cover:

- deterministic package digest and archive round-trip;
- tampered digest rejection;
- malformed archive or JSON rejection;
- unsupported schema-version rejection;
- default exclusion of audio and other unselected representations;
- explicit inclusion only of the selected reviewed representation;
- separation of immutable private capture from cleaned/edited share revision;
- deterministic filler-word cleanup without substring corruption;
- bounded before/after anchor context;
- package IDs mapped to distinct recipient-local IDs;
- duplicate import that is idempotent or fails with a stable explicit result;
- wrong-source, ambiguous-source, and context-only resolution remaining distinguishable where the extracted core supports resolution;
- no API keys, diagnostic payloads, private paths, or full source text in default packages.

Use stable fixtures rather than only constructing values inline in tests. Do not add a fixture family without registering it in the schema validator and contract documentation.

## Verification Commands

Run after implementation:

```bash
git diff --check
./scripts/bootstrap-python-tools.sh
.venv/bin/python scripts/validate-contracts.py
.venv/bin/python scripts/validate-surface-contracts.py
swift build --build-tests --package-path Packages/SessionKit
swift test --package-path Packages/SessionKit --filter SharingTests
swift test --package-path Packages/SessionKit
```

If package or project integration changes make the app consume a new SessionKit product, also run:

```bash
xcodegen generate
xcodebuild -project SpokenMarginsNative.xcodeproj -scheme SpokenMarginsApp -destination 'generic/platform=iOS Simulator' build | xcbeautify
```

Do not run broad UI routes for this package-level slice. Preserve complete failure output in the evidence file; do not weaken tests or validators to manufacture a pass.

## Commit Guidance

Keep the work auditable as up to three local commits:

1. `Add sharing package contracts and fixtures`
2. `Add sharing package and imported-layer core`
3. `Record sharing foundation reconciliation evidence`

Combine commits only when the actual change is smaller. Do not commit unrelated formatting, generated build output, or user work. End with a clean sharing worktree.

## Stopping Rules

Stop implementation and write a precise handoff when any of these occurs:

- Current `main` contains an accepted triage release that has not been reconciled into `codex/sharing-next`.
- Required implementation would modify a forbidden playback, app UI, project, or triage-owned surface.
- A merge conflict requires choosing between historical sharing behavior and accepted triage behavior.
- The contract requires an unapproved rights, identity, trust, network, or cross-edition policy decision.
- Completing the slice requires #19 recursive replies, #26 synthesis, accounts, hosted storage, or a new transport.
- A migration cannot preserve existing local interjections and sessions.
- Malformed, tampered, duplicate, or unsupported packages cannot produce deterministic outcomes.
- Baseline failures prevent distinguishing new regressions from existing repository state.

When stopped, do not broaden scope. Record the blocker, the smallest decision needed, files already changed, commands run, and the safest continuation point.

## Definition Of Done

All of the following must be true:

- Work is on `codex/sharing-next` and the branch remains separate from triage and QoL.
- Contract/package core behavior is implemented without forbidden-surface changes.
- Required validators and focused tests pass, or failures are recorded with no unsupported success claim.
- The reconciliation evidence names the exact historical source and file dispositions.
- Privacy defaults and negative-package behavior have reproducible coverage.
- Remaining presentation, playback, #68, and #19 work is explicit.
- No issue is closed and no flow is called `human_validated`.
- No merge, push, PR, external deployment, or GitHub status mutation occurred.
- The final handoff includes the starting SHA, final SHA, commits, files changed, tests and builds, known issues, and recommended next bounded step.

## Final Handoff Template

```text
Branch and starting SHA:
Final SHA and local commits:

Implemented:
-

Verified:
-

Deferred:
- #17:
- #18:
- #67:
- #68:
- #81:

Historical source disposition:
- Reused:
- Rewritten:
- Rejected:

Checks:
- Contract validator:
- Surface validator:
- SharingTests:
- Full SessionKit tests:
- App build, if required:

Known failures or risks:
-

Human validation status:
- Not requested / not performed.

Recommended next bounded step:
-
```
