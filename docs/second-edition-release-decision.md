> September 21 QoL follow-up: the current owner-directed repair pass is recorded in `release-lanes.md` and `../artifacts/validation/gate-1/qol-2026-09-21/handoff.md`. Margins sharing is item-level: one action per item opens that item’s existing export screen with session selection; do not add individual-note sharing. This follow-up preserves the accepted redesign and does not authorize distribution.

# Approved product-owner decision: second-edition native experience

Approved by the product owner on September 10, 2026. The owner reports the MVP has shipped to beta testing, authorizes the broader redesign and named agents/file ownership, and sets a 20% weekly-usage floor. AGENTS.md and docs/release-lanes.md record this decision before implementation.

## Approved authorization

Authorize the complete M0–M5 implementation sequence in `docs/second-edition-implementation-plan.md` on the existing `codex/provisional-next` lane. Expand the previously bounded #100/#107/#108 presentation authorization to the second-edition task hierarchy across Library, player, capture, Margins, intake, Following, Timeline, sharing review, offline/storage, settings and the listed edge states. Include the explicitly specified new local Margin search/filtering, session-qualified curation and Play this moment behavior, and written capture with backward-compatible persistence and export. Use the issue references as existing scope context; do not invent issue numbers for uncovered subwork.

Keep existing runtime capability rules, source and session identity, media/text navigation distinctions, recording exclusivity, preparation, original data, source disclosure restrictions, package integrity and sharing consent boundaries. The narrow changes needed for written capture and explicit playback return must receive coherent model/runtime/schema/tests where those layers are affected. Keep current gestures and established Library completion/sort semantics. Moving action presentation must retain existing actions and reachability.

Name the current parent task `design_steward`, `ui_implementer` as a GPT-5.6 Terra agent, and `evidence_reviewer` as a GPT-5.6 Terra review agent. Approve the exact allowed files, forbidden files and integration order in `docs/second-edition-work-packets.md`. Permit a maximum of one delegated implementation writer plus read-only review alongside the steward. This is a task-specific exception; it does not revive the archived surface-contract gate workflow or authorize unrelated parallel work.

Approve the proposed usage guardrails: calibrate after the core pilot or five additional percentage points of account consumption; preserve a 20-point integration reserve and a 20-point floor for other work. These are monitored checkpoints, not a guaranteed completion estimate or hard platform cap. Any incomplete milestones remain clearly incomplete when a budget boundary is reached.

The engineering target is a verified native candidate and a complete product-owner handoff. Only the owner establishes `human_validated` behavior. No TestFlight upload, external sharing enablement, Beta App Review, promotion to `main`, new feature branch, or unrelated architecture replacement is authorized by this decision.

## Application

The steward records the owner's confirmation, date, scope and this packet reference in `docs/release-lanes.md` before implementation and notes the bounded coordination exception there. Then execute the approved sequence without requesting routine per-file or per-milestone permission. Ask again only for an actual product tradeoff or new boundary outside this decision.

## Prior boundary superseded by this decision

The September 9 release entry said: “Completion filtering, sorting, export relocation, gesture changes, new Margins workflows, and broader redesign remain deferred.” `AGENTS.md` requires named stewardship, agents, allowed/forbidden files and merge order for parallel work. The proposed native rollout exceeds the recorded presentation-only scope. The owner's enthusiasm for the design is preserved as design direction; this document makes the implementation and coordination change explicit and auditable.
