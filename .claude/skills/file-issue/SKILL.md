---
name: file-issue
description: How to file, complete or promote a Spoken Margins GitHub issue so it can join the ready queue - the five headings, the labels, the area and the milestone. Use whenever you file a new issue, fill in an existing one, or consider adding `ready`.
---

# Filing an issue

## Before filing

Search open issues first. On a duplicate, comment there instead of filing. One problem per issue.

## Body headings

- **Outcome:** one or two sentences on what's different for the listener or the pipeline when it's done.
- **Evidence:** what was seen, with the build number or `main` commit. For a bug: steps, expected, actual.
- **Done when:** numbered, checkable items, including the test that must fail without the fix.
- **Must not break:** the journeys ([docs/journeys.md](../../../docs/journeys.md)), packets, the database, and the owner's Library and recordings it could touch.
- **Cost and catch:** required when the work adds or changes a recurring cost (a lane step, a scheduled job, an agent loop, a per-PR check). Its cost per run, how often it runs, what it catches with evidence, and the signal that would show it's waste.

## Labels

- `bug` for failures.
- Exactly one area label from [docs/areas.md](../../../docs/areas.md): `area: get it in`, `area: hear it well`, `area: answer it`, `area: pass it on`, `area: groundwork`, `area: housekeeping`. Flaky tests, speed and pipeline work are `area: groundwork`.
- `ready` only when every heading above is filled in and the issue fits the standing calls. Fill missing headings yourself when the issue honestly supports it.
- `where:mac` only when it needs Mac hardware, signed-in Mac accounts or a physical device, not merely an iOS build.
- `owner-asked` when the owner asked for it himself.
- Never add or remove `priority`; only the owner or the lead session sets it.
- An outsider's issue (not OWNER, MEMBER or COLLABORATOR) gets `needs-triage-review` and a short reply, never `ready`.

## Milestone

A milestone is a release named by app version (`0.2`, hotfix `0.2.1`) and holds only what blocks that release reaching testers. When unsure, leave it empty. `0.2` (Showcase) is cut to #2256, #2096, #2505, #2511, #2717, #3633; nothing else joins it unless it blocks the tester build, and never move issues back into it. Groundwork has no milestone unless it blocks a release; then it goes in that release and keeps `area: groundwork`.

A bug that would stop the owner using the build goes to him as a one-line question, through the [ask-cole skill](../ask-cole/SKILL.md).
