# A3 · triage: sort the issue backlog into the streams

**Outcome.** Each of the 106 open issues is in one of four states: assigned to a stream, closed as done, closed as a duplicate or obsolete, or explicitly parked. Stale issues that would help an active stream get a note saying how.

**Why now.** Streams need to know which issues are theirs. The owner also asked which old issues have synergy with this plan. The repo review found duplicates, done-but-open issues and 5–14k-character agent walls (§8).

**Where.** Cloud. Read-only on code; writes only to GitHub, and only after owner approval.

## Starting points

- `docs/repo-review-2026-09-24.md` §8 lists probable duplicates (#133/#136, #64/#73/#74, #70/#82, #88/#89, #48/#51, #117/#118, #75/#96/#121, #93/#97/#131, #132/#141/#143, #129/#142, #105/#124/#138), closable issues, and issues implemented but awaiting validation.
- Issues labeled `status: needs-human-validation` belong to the owner's next device pass, not to a stream. The label is only for changes the owner would see or hear; internal work is closed when it merges into `next`.
- The stream briefs in `docs/workstreams/streams/` list the issues they already know about. Start from those.

## Milestones

**M1: Proposal.** A triage table the owner can approve from the phone.
- Done when a single comment or gist lists every open issue, one row each: number, a title of ten words or fewer, proposed state (`stream:<id>` / close-done / close-duplicate-of-#N / close-obsolete / park), and a one-line reason.
  - Every "close-done" cites the commit or build that did it.
  - A second list names up to 15 stale issues with real synergy with a stream, each with one sentence on how it would help.

**M2: Apply.** The approved rows are applied.
- Done when every approved row is applied: labels added, closures made with `state_reason` and a one-line comment. Nothing unapproved was changed, and the proposal table and the resulting labels agree.
  - Also: issues longer than about 4,000 characters that stay open get a short "current state" summary comment at the top of the thread. Don't edit the owner's original text.

## Must not break

Owner-written issue text. Never close an issue that is `status: needs-human-validation` without the owner saying so.

## Out of scope

Fixing anything. Creating new issues, except where two open issues must be merged into one.
