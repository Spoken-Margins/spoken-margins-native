# Implementation and management audit — September 23, 2026

The work made substantial correctness improvements, but the complete reliability brief remains unfinished. Both managers protected scope and reported limitations honestly. Astra's first run dispatched more work than its correction reserve could close; Sol's continuation enforced a stronger sender checkpoint but retained substantial supervision and repeated recipient correction cycles. These observations do not establish an intrinsic model ranking.

## Scope and method

Reviewed the three implementation turns in **Fix export fingerprints and matching**, their local request records, the implementation brief/status, capture/sender/recipient audit chains, relevant current source and tests, and machine-readable verification manifests. Earlier review/design and management discussion are excluded from execution totals. Existing dirty work includes unrelated Shortcut/conversation changes; repository-wide diff size is not attributed to these runs.

Assessment model:

- **Resources:** account reserve, model input/output, machine time, and owner attention are separate quantities.
- **Execution:** one implementation/test writer, an independent auditor, and a manager responsible for contracts, acceptance, sequencing, and closeout.
- **Target:** automatic source evidence through capture, durable recovery, export, and conservative recipient placement. Manual confirmation is an exception path, not completion of automatic recovery.
- **Evidence:** source inspection, boundary tests, full automated gates, OS/device measurements, and owner acceptance establish different claims.
- **Decision criteria:** useful accepted slices, escaped/repeated defects, verification completeness, preservation of constraints, and total coordination/rework overhead.

This was a records and targeted source audit, not a fresh whole-codebase review or runtime validation. No simulator, build, or test suite was started. `git diff --check` passed. Implementation files were not changed.

## Delivery findings

1. **High priority: the central product promise is still unproved.** Routing, per-flank state, stale-callback rejection, acoustic/ASR separation, export integrity, and recipient confirmation have meaningful implementation and test evidence. Bounded recipient transcript recovery with global uniqueness checks, initial producing-edition hashing, transactional artifact/ledger handling and orphan reclamation remain open. Required adapter/speech/UI/corpus/device evidence is incomplete. The managers correctly disclosed this. It nevertheless means the work has not yet delivered the requested robust automatic flow. [Current status](implementation-status.md)

2. **High priority: tests repeatedly bypassed the failing production boundary.** The acquired-window app fake returned already absolute timestamps, so it could not catch a production offset error. Recipient confirmation initially used a no-op player that could not model remote-to-local player replacement. Subsequent reviews found seek ordering, delayed readiness, and absent transport proof. The correction chain is substantive evidence of both auditor value and an insufficient initial acceptance contract. Tests now cover more of these boundaries, but final app assertions remain unexecuted. [Acquisition audit](shared-acquisition-correction-audit.md), [recipient correction audit](recipient-confirmation-correction-audit.md), [final proof audit](final-transport-proof-audit.md)

3. **Medium priority: architectural completion is less explicit than behavioral completion.** The brief calls for a capture coordinator outside `Gate1AppModel`. Retry and reconciliation orchestration still resides in that model (`retryActivePodcastCaptureIfPossible`, `reconcilePodcastAnchorEvidence`, and capture scheduling). This is an unclosed architectural requirement, not proof of a current runtime defect. Either implement that ownership boundary in a bounded change or explicitly record an accepted deferral; do not let partial behavior silently imply the design was fulfilled. [Brief](../../../../docs/podcast-anchor-reliability-implementation-brief.md)

4. **Medium priority: handoff state requires historical reconciliation.** The status file preserves good evidence, but its opening checklist marks only A complete and later appended checkpoints contain the actual partial completions and superseded findings. A new manager must reconstruct the current state. The brief also retains earlier authorization/floor wording. A short current acceptance matrix above the history would reduce rereading and incorrect resumption. One missing diff snapshot was identified and corrected in a later handoff, demonstrating why evidence paths matter. [Protocol correction handoff](protocol-offset-correction-handoff.md)

Verification independently checked in this audit:

| Claim | Evidence and limit |
| --- | --- |
| Current fast gate | Manifest `20260923-145048-859797-fast` is verified: 330 package passes, one declared corpus skip, plus runner/browser/contracts/surfaces/inventory. Recomputed current source fingerprint exactly matches `af22cd84cf5a5402fe1f13edadbd6e0b2e8ef83a5ab2885afb279b921120f4ea`. The skip does not establish held-out acoustic quality. |
| Sender app gate | Manifest `20260923-135424-830567-app`: 476 passed, zero failed/skipped, source fingerprint `8962815a2717f9ad9e395591d5f2b1de32d3f4648e98c522d4061f7e2374ca01`. This is an earlier sender checkpoint, not the final recipient tree. |
| Recipient app gate | Manifest `20260923-141405-747326-app`: exit 65, zero completed tests, 477 missing, runner connection failure. Subsequent final corrections have host/source evidence, not a successful final app run. |
| Final source identity | Both `Gate1AppModel.swift` and `Build23SharingSeamsTests.swift` hashes match the final transport-proof handoff. |
| Product validation | Not established. No release or human-validation claim is justified. |

## Manager assessment

| Dimension | Astra: first two implementation runs | Sol xhigh: latest continuation |
| --- | --- | --- |
| Scope and safety | Strong: preserved lane/data/distribution boundaries; stopped at 86%, then 80% remaining. | Strong: same boundaries, stopped at 76% above the 75% floor. |
| Sequencing | First run weak: core integration expanded while capture defects remained, leaving four capture findings at closeout. Second run improved with stable correction audits. | Better observed discipline: closed the prior correction and sender full gates before recipient expansion. |
| Technical judgment | Useful export-race spot review and simulator-plan correction. Did not establish all cross-component contracts early enough to avoid rework. | Useful shared-acquisition/compatibility closure and insistence on real local transport proof. Several recipient hazards still emerged one review at a time. |
| Verification honesty | Strong: explicitly distinguished compilation, eight targeted passes, outstanding full gates, and incomplete brief. | Strong: did not count zero-test XCTest failures or generic builds as app verification. |
| Efficiency | Mixed: moving-code review and broad initial scope created avoidable rereading/correction. | Mixed: improved acceptance sequencing, but supervision volume was not lower and audit output dominated the continuation. |
| Overall | Responsible stewardship; uneven conversion of the budget into completed increments. | Competent continuation with stronger checkpoint closure; no demonstrated management-quality collapse after the switch. |

The comparison is confounded: Sol inherited Astra's implementation, audits, plan, and lessons, and addressed different work. Astra's earlier design effort is excluded here. Neither the earlier subjective “10–25% worse” estimate nor a cost-superiority claim is supported by this sequential sample.

## Usage and supervision

Both supplied token tables reproduce exactly from local `token_usage_record` entries, deduplicated by response ID and grouped by implementation root turn across manager, implementer, and auditor sessions.

| Measure | Astra-managed runs combined | Sol-managed continuation |
| --- | ---: | ---: |
| Elapsed implementation-turn time | 84.9 min | 85.1 min |
| Manager request records | 149 | 150 |
| Manager output | 22,604 | 19,129 |
| Manager cached input | 27,573,632 | 14,149,376 |
| Recorded manager commentary items | 40 | 40 |
| Agent wait calls | 70 | 84 |
| Audit / implementation output | 98.4% | 133.2% |
| Audit share of total output | 45.4% | 51.9% |

Wait calls are not themselves proof of waste: bounded waits can be appropriate and avoid active polling. These counts do show that the switch did not produce substantially fewer manager requests or updates. Sol manager output fell 15.4%; that is not a measured cost-per-result improvement because scope and inputs differ.

Luna's reasoning was 70.0% of its output in the Astra runs and 71.7% in the continuation. Excluding reasoning, audit output was 36,142 and 30,684 respectively. It is misleading to interpret total audit output as merely a long written report. Reviews caught concrete P1/P2 defects; the record supports retaining independent review, while reducing repeated rediscovery through better initial contracts. There is no controlled evidence that a different auditor or effort setting would deliver equal coverage for less usage.

Cached input remains processed context, although it is not unique material. Token shares do not determine billing or quota shares. No account-percentage allocation to models is claimed.

## Testable next steps

1. **Close current runtime evidence before expanding features.** Diagnose the XCTest connection failure, identify a changed condition, then make one bounded same-device recovery attempt under the existing incident rules. If the same failure persists, retain the blocker and continue only independent authorized work. Do not weaken the gate.
2. **Use one acceptance contract per slice.** Specify state transitions and counterexamples before coding: stale generation, wrong edition, paused remote player, delayed seek/readiness, missing transport probe, and persistence interruption. Require tests to exercise the real owning boundary. This targets the recurring fake-client blind spot.
3. **Audit a frozen source/input identity.** Require a compact finding, reproducer, affected invariant, and closure test; review changed paths and dependencies. Escalate a recurring defect class into a consolidated contract review instead of continuing one local patch at a time.
4. **Keep Sol xhigh as a provisional execution-manager choice for this established plan.** This is justified by observed adequate stewardship, not proven model superiority. Compare future similar slices on first-review acceptance, correction rounds, unresolved high-impact findings, final-source gate coverage, and all-role usage. Consider a specialist architectural review only for a concrete unresolved decision; this audit does not demonstrate a need to restore Astra for routine supervision.
5. **Judge completion by covered obligations.** Maintain a current matrix for A–G, including the external-coordinator requirement, exact-edition recovery, recipient automation, crash consistency, and production capture-to-export evidence. Stop expansion while high-impact findings in the current slice remain open; reserve capacity for correction and final verification, not only initial implementation.

Falsification checks: an executed final recipient app manifest would close the runtime finding; a demonstrated production coordinator or explicit approved deferral would resolve the architectural finding; a production capture-to-export trace plus the required corpus/device gates would strengthen the reliability claim. More test counts alone would not. A fair model comparison needs comparable work and measured outcomes; these inherited sequential runs cannot supply it.
