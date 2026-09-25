# Podcast anchor reliability implementation status

**Current checkpoint — September 24:** the three remaining recipient reliability fixes are implemented and the applicable test plans, builds, and held-out benchmark have been exercised. The latest app-suite attempt stalled before XCTest connected, leaving one new iOS AV-export test unexecuted; a focused macOS AVFoundation test passed for that path. See [full-verification-2026-09-24.md](full-verification-2026-09-24.md) for exact evidence and remaining validation limits. The opening checklist and earlier stop/resume entries below are historical; they are not a current remaining-work list.


Owner authorization: September 23, 2026; `docs/release-lanes.md` records scope. Starting account remaining: 90%; mandatory floor: strictly above 85%. This is an engineering work log, not a product-validation handoff.

## Ownership

- Primary: strategy, lane record, narrow integration reviews, usage reserve, final evidence reconciliation.
- Sol-6 high (`capture_implementation`): sole code writer for core capture/contracts/persistence and host regressions, packets A–C.
- Luna-6 max (`integration_audit`): independent read-only app integration audit, packets D–F. Writes only its audit artifact.
- No archived parallel workflow; no concurrent app/package writers or competing test runners. Later assignments replace these bounded scopes explicitly.

## Completion checklist

- [x] A: production router forwards capture; boundary regression fails before and passes after repair.
- [ ] B: durable per-flank state, session identity, migrations/contracts and restart reconciliation.
- [ ] C: bounded reliable acquisition, generation/continuity checks, worker safety, evidence storage.
- [ ] D: acoustic recovery independent of ASR and existing transcript availability.
- [ ] E: current evidence export, asset completeness, explicit degraded sharing, durable diagnostics.
- [ ] F: bounded conservative recipient recovery, unresolved voice playback, explicit position confirmation.
- [ ] G: required verification and owner-ready evidence, with platform blockers distinguished.

## Constraints

Preserve original voice/anchors and pre-existing dirty changes (`baseline.diff`, `baseline-status.txt`). No commit, merge, distribution, physical-device installation, or server/ASR service work. Existing simulator incidents remain restrictions; host tests and generic builds do not substitute for device or owner validation. Budget checkpoints occur on work-packet handoffs, not continuous agent polling. At 13% used, stop expanding work and reserve capacity for audit, safe closeout, and an explicit unfinished-work record; never claim the whole brief complete if anything remains.

## Placement gate clarification

The authoritative existing #27 gate in `docs/release-lanes.md` is zero false-confident placements in the held-out benchmark and p95 error ≤1.5 seconds. New capture coverage targets do not weaken this gate.

## Independent integration audit

Luna completed `integration-audit.md` without code edits or test runs. Confirmed app-state integration, ASR/acoustic coupling, stale export, digest-binding, and recipient-confirmation gaps. The inherited sender-ASR obligation is now explicit in the brief. Usage at audit handoff: 89% remaining.

## Core handoff and next ownership

`capture-handoff.md` records a bounded A–C implementation and focused host checks. B/C are partial: app consumption, restart reconciliation, complete artifact lifecycle, format conversion, and bounded reattachment still need implementation or explicit deferral. No full gate is claimed.

Sol remains sole writer/test owner, now for app integration D–F and necessary support. Luna is auditing core changes read-only, with `capture-audit.md` as its only output. Usage at handoff: 89% remaining. No simulator boot is authorized by this assignment.

## Final checkpoint — incomplete engineering candidate

All agent assignments have returned. Work stopped at **86% remaining** (14% used), preserving the owner's strictly-above-85% reserve. The 13% expansion stop and 14% coding stop were shepherd safety checkpoints, not different owner requirements. No feature expansion is continuing in the background.

Implemented: production capture forwarding; independent persisted flank outcomes; session-qualified capture and a bounded worker queue; track-readiness handling; app-side per-flank updates and digest preservation; bounded source-window acquisition independent of ASR; current SQLite-backed export evidence; degraded consent tied to the reviewed selection/evidence disposition; failure rather than silent loss when referenced assets disappear. See capture/integration/export handoffs for exact limits.

### Final verification

- Full `fast` plan passed after the final changes: [manifest](../../../test-runs/20260923-121952-428068-fast/manifest.json), [log](final-fast.log). Runner checks, contracts, surfaces, inventory, browser, and package suites passed.
- Generic iOS Simulator `SpokenMarginsAppBehavior` **build-for-testing passed**, compiling the app test target: [log](final-test-build.log). This supersedes the earlier uncertainty about whether new app regression source compiles. It does **not** execute those tests.
- Focused host tests passed in the earlier core slice; generic app build passed. Final `git diff --check` passed.
- Required app/adapters/speech-canary/UI execution, real-device capture/resource evidence, recipient benchmark and release gates are outstanding. No simulator was booted, physical device installed, commit made, or product flow marked human_validated.

### Resume order and blocking findings

1. Resolve capture-audit findings 1–4 before treating this sender candidate as complete: stale attempt rejection in every completion/failure path; epoch-bound delayed queue-gap invalidation; exact PCM trimming at pre-window boundaries; durable role/schema compatibility. The export/consent finding was addressed, with regression source compiled but not executed. See [capture-audit.md](capture-audit.md).
2. Finish B/C lifecycle guarantees: durable startup/foreground reconciliation, artifact integrity/retention/transaction semantics, edition tokens on all asynchronous paths, supported-format conversion and bounded retries/reattachment. A saved per-window record alone is not a recovery scheduler.
3. Finish D/E transport guarantees: versioned safe per-Margin outcome summary, durable export disposition and transactional asset pins; exercise fresh-draft, missing/changed-file, ASR-failure, and legacy compatibility cases through the app.
4. Implement F recipient work: bounded digest-bound transcript recovery with global-uniqueness safeguards and explicit recipient position confirmation. Current full-source recovery and conservative matching remain; this packet is unchanged.
5. Run remaining required gates after evidence-backed resolution of applicable simulator restrictions, then prepare the repository-required owner validation handoff. Preserve original data and the #27 zero-false-confident / p95 ≤1.5s gate.

This is a partial implementation under a usage constraint, not completion of the full brief and not release-ready. Existing dirty work was preserved. No branch, merge, distribution, cloud service, or automatic continuation was created.

Final fast input SHA-256: `a60d5e70e2711f0d8118fbaa5b930500c50e2ff2d756456b00b311afeac0b611`; HEAD: `34837c6055471297ca0b360c591f734bad5c2c82`. Uncommitted changes are part of this candidate.

## Resumed under 80% floor

Owner authorized resumption September 23; live start meter 85% remaining. First slice is exclusively capture-audit findings 1–4 plus counterexample tests, followed by stable independent review. No new features before that acceptance checkpoint. Sol is sole code/test writer; Luna prepares the bounded recipient/test-environment plan read-only. Existing simulator restrictions remain. Historical stop statements above describe the prior run.

### Resumed checkpoint 1 — capture corrections accepted

`capture-corrections-handoff.md` and independent `capture-corrections-audit.md` close original audit findings 1–4 for current writes. Full fast passed (322 package tests, expected corpus skip); generic app build passed. Auditor noted missing-role callback fail-open and hypothetical invalid legacy-role decode boundaries; next lifecycle slice addresses the former. Current remaining usage: 84%. Sol is sole writer for sender lifecycle/transport completion; no recipient feature expansion until its stable audit.

## Final resumed-run stop — 80% remaining

All writers returned; no further work dispatched. Original capture findings 1–4 passed stable independent audit. Sender lifecycle implemented integrity reconciliation, protected owned evidence, worker format conversion, pinned export evidence and optional privacy-reduced package outcome summaries. Two additional sender P1s (late-audio retry and foreground invalidation) were corrected and independently audited. See sender lifecycle and P1 handoffs/audits. The latest pre-runtime fast gate passed 326 package tests with one expected corpus skip; generic build-for-testing passed.

Owner confirmed host unlocked. Full app plan on the same phone `856FA6EF-5E03-4120-939B-F0EF42A804E8` executed and failed eight assertions: `artifacts/test-runs/20260923-131453-730339-app/manifest.json`. A bounded repair preserved bounded ASR when acoustic acquisition fails and persisted sharing-test fixtures through a DEBUG-only seam so strict durable export refresh remains intact. Changed: Gate1AppModel.swift, Build23SenderSharingExperienceTests.swift, Build23SharingSeamsTests.swift, SpokenMarginsPackageHandoffTests.swift. Debug test build and exact eight-test rerun passed on that phone; see `app-regression-targeted.log` and `app-regression-targeted.xcresult`. No crash was reported during that run.

Usage reached the owner’s 80%-remaining floor. Full app/fast plans were NOT rerun after the last correction, nor was that final small correction independently audited. No complete-release or human-validation claim is made. No commit, merge, distribution, or physical-device installation occurred.

Remaining: recipient packet F; full final gates including adapters/speech/UI/held-out benchmark as applicable; original producing-digest capture for safe local recovery; atomic artifact/ledger commit and orphan reclamation; physical-device/resource validation. Hypothetical invalid legacy capture-role migration remains documented. The full brief is still incomplete. Resume with review of the final app correction and complete gates for the sender slice before recipient expansion. Earlier unresolved capture P1/P2 lists are superseded by their correction audits, not ongoing open defects.

## Continuation under 75% floor — stopped at 76% remaining

The owner authorized continued bounded sub-agent work with an account floor of 75% remaining; `docs/release-lanes.md` records the revision. No writer remains active, and no more implementation is dispatched in this run.

The sender's final correction passed independent review. The shared source window now feeds fingerprint generation and bounded ASR without a second remote fetch; legacy clients retain their already-produced transcript, and a deterministic adapter seam checks the source-time offset. Final sender fast and app plans passed on the same iPhone 17 Pro / iOS 26.5 simulator: 328 package tests plus one expected skip, and 476/476 app tests. See `shared-acquisition-correction-handoff.md`, `protocol-offset-correction-handoff.md`, and their audits for exact manifests and limitations.

Recipient exceptional recovery is **implemented and host verified, but its final app runtime gate is blocked**. Unresolved or ambiguous imported podcast Margins retain direct voice playback and offer a user-confirmed source position bound to the exact recipient file digest. Independent reviews closed seek ordering, delayed readiness, and missing-transport-proof findings. The final fast plan passed 330 package tests with one expected skip, the generic iOS Simulator app build passed, and `git diff --check` passed. See `recipient-confirmation-handoff.md`, `recipient-confirmation-final-correction-handoff.md`, `final-transport-proof-handoff.md`, and `final-transport-proof-audit.md`.

The full recipient app plan failed before XCTest connected: `artifacts/test-runs/20260923-141405-747326-app/manifest.json` records **0/477 tests completed** and exit 65 after 329.721 seconds. A changed-input focused attempt also stalled before suite start and was terminated at a bounded threshold. No simulator system-process crash was reported. No further simulator boot or unchanged retry occurred. The final paused/transport-proof assertions have compiled or parsed but **have not executed**. A passing generic build and host tests do not substitute for that app gate. Offline result-bundle inspection confirmed the runner-connection failure; a narrow host sleep/fault check did not identify a cause.

Still open from the brief: bounded, digest-bound recipient transcript windows with episode-wide uniqueness checks (the existing full-source path remains); original producing-edition digest capture for safe local recovery; transactional artifact/ledger commit and orphan reclamation; applicable adapters, speech-canary, UI, held-out benchmark, device/resource, and owner validation gates. There is no commit, merge, distribution, or physical-device installation. Preserve the current dirty tree and resume from this evidence, diagnosing the XCTest connection stall before another runtime attempt.

## Continuation under 70% floor — September 23 engineering checkpoint

The owner extended the existing authorization to a 70%-remaining account floor; `docs/release-lanes.md` records it. This continuation began at 75% remaining. One implementation writer worked at a time, with independent read-only audits after bounded slices. Earlier stop statements above describe previous runs.

The final implementation and audit handoffs completed with 71% remaining. No further code packet was dispatched; that one-point reserve covers the final evidence reconciliation without crossing the owner's floor.

**Recipient F:** The full-source fallback was replaced by digest-bound local, widened, and chunked transcript windows. A transcript match is eligible for verification only after measured audio-window coverage spans the recipient episode and episode-wide uniqueness is checked. A short export, incomplete/budget-exhausted sweep, changed file, or nearby repeated passage stays unresolved or ambiguous. Recipient cache cleanup is isolated from episode-map preparation, and a changed edition queued during a sweep starts a fresh job. Direct voice playback and explicit digest-bound recipient position confirmation remain available. The final independent audit closed the measured-coverage, replacement, cleanup, and nearby-repeat findings. See `recipient-window-handoff.md` and `recipient-window-correction-handoff.md`.

**Sender B/C:** The evidence reference and protected owned-asset ledger rows now commit in one SQLite transaction. An injected failure rolls back both across reopen; a new or changed evidence reference without a matching protected row is rejected, while unchanged legacy references remain loadable. Startup reconciliation preserves committed references on indeterminate read errors and invalidates confirmed missing/corrupt bytes. A constrained, idempotent orphan pass removes only aged, unreferenced app-owned capture signatures for still-known Margins; unknown files remain untouched. The independent audit closed the transaction and transient-read findings. See `sender-durability-handoff.md`.

**Producing edition:** The main voice and trusted compact-control capture paths can persist an exact local-file digest only when the validated file remains bound to the same AVPlayer item/generation through capture and off-actor hashing. Same-path replacement, changed generation, streaming, or unproved origin leaves the digest unknown. The independent audits found no remaining P1/P2 in these bounded paths. Watch runtime was untouched. See `producing-edition-binding-handoff.md` and `compact-producing-edition-handoff.md`.

Final changed-input `fast` plan passed: [manifest](../../../test-runs/20260923-171646-268701-fast/manifest.json), 340 package tests passed, one expected skip, with runner/contracts/surfaces/inventory/browser checks passing. Generic iOS Simulator app `build-for-testing` compiled the app test target (`compact-producing-edition-app-test-build.log`); a separate generic iOS device build passed (`final-generic-ios-build.log`). `git diff --check` passed. The documented `SpokenMarginsWatch` command could not run because the current project has no Watch target or scheme (`final-generic-watch-build.log`, `project.yml`); it is a documentation/project configuration discrepancy, not a successful Watch build.

**Still outstanding:** The simulator app runner connection stall remains undiagnosed: the last full app plan completed 0/477 tests. No simulator boot or unchanged retry occurred in this continuation. New app assertions compiled but did not execute. Adapter, speech-canary, UI, held-out #27 zero-false-confident-placement/p95 ≤1.5 s, physical-device capture/resource, and product-owner validation evidence are pending. The recipient sweep is not durable across restart, has a 44-window request cap (episodes beyond its 36-chunk sweep budget stay unresolved), has no second recognizer fallback or global cross-item speech queue, and actual AV export behavior is untested. The file write and SQLite transaction cannot be one atomic operation; conservative orphan cleanup handles only provable aged files. No commit, merge, distribution, physical-device installation, or server work occurred. The dirty candidate remains an engineering implementation, not release-ready or `human_validated`.

Resume by diagnosing the XCTest connection failure on the same iPhone destination from the retained result bundle and device logs before any runtime retry; preserve the iPad simulator crash restriction. Then execute the compiled app assertions and measured AV export cases, followed by adapter/speech/UI and held-out benchmark gates. Recipient sweep persistence, cross-item scheduling, recognizer fallback, and physical-device resource evidence remain separate implementation and validation packets. Do not infer #27 acceptance or owner validation from the passing host/build evidence.


## September 24 — individual implementation fixes, verification deferred

1. Durable recipient recovery: private SQLite checkpoints retain completed, edition-bound windows; startup/foreground resume only unfinished windows. Changed bytes/version/duration replace the checkpoint. A superseded writer cannot replace a newer job. Item deletion removes the private state. Completed timelines remain local for matching; raw window audio is purged after each completion.
2. Shared speech scheduling: production Margin, source-map and recipient transcription use one cancellation-aware FIFO recognition queue, with at most 64 waiting calls. Recipient sweeps release the lease after each window. Queue pressure leaves the durable recipient job pending.
3. Bounded recognizer fallback: acquired source audio uses the existing supported on-device legacy recognizer after preferred recognition fails, preserving source-time offsets and avoiding another fetch. A failed legacy service suspends source recognition across items; file/empty-input failures and cancellation do not poison the service. Recipient service/empty-window suspension persists. Existing explicit Retry/Download Again actions reset the circuit and permit resuming a suspended job; ordinary launch/readiness does not reset it.

Added regression source for reopened checkpoints, superseded writers, item deletion, invalid bounds, durable suspension, app bootstrap resumption, FIFO/cancellation, fallback/circuit behavior, and non-service failures. **None executed.** Source/diff review only; `git diff --check` passed. No builds, system tests, simulators, independent agents, commits, or installs were run. The XCTest connection diagnosis, actual AV export/speech behavior, benchmark, resource measurements and owner acceptance remain for the later verification pass. The existing 44-request/36-sweep-window cap remains conservative; longer episodes can remain unresolved.

## September 24 — owner-requested full verification

The owner subsequently authorized full testing. Fast, the original 482-test app suite, adapters, speech canary, UI, the held-out anchor benchmark, focused real AVFoundation export on macOS, and generic simulator/device builds passed. The UI route needed a test-only scroll/precondition correction before its full rerun passed. The latest app run built successfully but completed zero tests because XCTest never connected; one new iOS real-export test is still unexecuted. Preserve that result as blocked. Exact manifests, inputs, counts, and remaining platform/owner checks are in [full-verification-2026-09-24.md](full-verification-2026-09-24.md).
