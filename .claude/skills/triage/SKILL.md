---
name: triage
description: The Spoken Margins coordinator's daily triage - sort new issues, set areas, complete and promote issues, route merged listener-facing fixes, and sweep orphans. Use only in the daily triage scheduled task (21:30 Eastern) or when the coordinator is asked to run triage by hand.
---

# Daily triage

Runs at 21:30 Eastern as a scheduled task in the project. Don't ask the owner about the routine itself.

1. **New issues:** sort every issue opened since the last triage. Set exactly one area label on each, and complete it per the [file-issue skill](../file-issue/SKILL.md). Comment on duplicates and close them toward the original.
2. **Merged listener-facing fixes:** route each one per the [dispatch skill](../dispatch/SKILL.md), section 2 (`agent-verify`, `validate-by-use` or `status: needs-human-validation`). Leave it open until a `**Real-use proof**` is recorded on it (`scripts/real_use_proof.py --issue N --pr M`); report it as "merged, not yet shown working" until then.
3. **Orphan sweep:** list every open issue with no queue label (none of `ready`, `in-progress`, `needs-owner`, `needs-design`, `deferred`, `blocked`, `agent-verify`, `validate-by-use`, `status: needs-human-validation`), and every `owner-asked` or `found-on-phone` issue older than 3 days with no open PR. Complete and promote each to `ready`, or say why not in one line.
4. **Milestones:** a milestone holds only what blocks that release. Move anything else out; never move issues back into `0.2`.
5. **Report:** only what needs the owner, through the [ask-cole skill](../ask-cole/SKILL.md). Otherwise post nothing.
