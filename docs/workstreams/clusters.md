# Cluster runs

A cluster run splits one milestone into a few clusters. Each cluster has one lead session, one branch, and a fixed list of issues. The leads do little themselves. Background agents do the reading, coding and fixing, and send back short summaries. This page holds the rules. Live state is on the run's tracking issue (the first run was #2673 on 2026-10-25, the second #2715 on 2026-10-26).

Everything in [AGENTS.md](../../AGENTS.md) still applies. Where this page is stricter, this page wins for a cluster run.

## Who writes what

Every piece of state has exactly one writer.

| What | Where | Writer |
|---|---|---|
| These rules | this page | the run's lead session, by PR only |
| Cluster list, issue lists, held items | the tracking issue's body | the run's lead session |
| A cluster's status | one comment on the tracking issue | that cluster's lead, edited in place |
| CI, `main` health, closes, cleanup | one comment on the tracking issue | the chief of staff, edited in place |
| Code | the cluster branch and its sub-PRs | that cluster's agents |

- A lead posts its status comment once, at the start, and from then on edits it (`gh api -X PATCH repos/{owner}/{repo}/issues/comments/<id> -f body=...`). It never edits anyone else's comment.
- A lead works only on the issues in its row. If it needs another cluster's issue or file, it tells the chief of staff, which moves the issue in the body's table (through the run's lead session) and tells both leads.
- **One cluster owns `Gate1AppModel.swift` and its extension files.** The tracking issue says which one. Other clusters put new logic in their own files, or ask the owning cluster for the change.

## A lead's day

1. Read this page, the tracking issue body, and each of your issues (a helper agent may summarize long issues).
2. Post your status comment: your issues, one line each, with state `todo`.
3. Make the cluster branch from `main` (`git fetch origin && git switch -c ws/cluster-<slug> origin/main`), push it, and work in your own worktree.
4. For each issue, hand a background agent a brief: the issue, the files, what done looks like, and the checks below. It works on its own sub-branch and opens a sub-PR into the cluster branch. It returns a summary of under 300 words: what changed, the checks run, and the sub-PR number.
5. Review the sub-PR's diff summary (have a helper agent review the full diff if it is large), then merge it into the cluster branch yourself.
6. When the list is done, open one rollup PR from the cluster branch into `main`, and arm it ([lane-request skill](../../.claude/skills/lane-request/SKILL.md)).
7. Update your status comment at every state change: `todo`, `in progress`, `sub-PR #N`, `merged into cluster`, `in rollup #N`, `handed back`.

## Checks on every sub-PR, not only the rollup

Yesterday these failed late, at the rollup, and forced refactors. Run them before a sub-PR merges into the cluster branch:

- `.venv/bin/python scripts/verify-tests.py --plan fast`
- The hot-file ratchet and the main-thread-reads guard (both run in `--plan fast`; if one fails, fix the design, don't raise the ceiling).
- For app changes, both builds from "Verification" in AGENTS.md.
- If the change needs simulator tests, say so in the sub-PR, and ask for `/lane T3` once on the rollup with every needed test on its `tests:` line.

## Rollup PRs

- The body lists `Closes #N` once for each issue finished, one per line. Sub-PRs merge into the cluster branch, not `main`, so their `Closes` lines never fire. Only the rollup's do.
- The chief of staff checks after the merge that every issue closed, and closes any that didn't with `sm-gh close-issue`.
- A rollup that fails an audit: at the second finding in one area, change the design or post an **Accepted audit finding** (AGENTS.md, "Fix the cause of an audit finding").

## CI watching

- **Leads and their agents never watch CI.** No `gh run watch`, no polling loops, no timers. On 2026-10-25 several leads polled every 3 seconds and hit GitHub's secondary rate limit.
- The chief of staff is the only watcher, at most once every 2 minutes, and tells a lead only when its PR's state changes (passed, failed, conflict, audit finding).
- A lead that wants to know where its PR stands asks the chief of staff, or waits for its message.

## Before the run starts

The chief of staff checks that `main` is green: hosted integration, the Linux SessionKit check, and the lane's host tests on `main`'s tip. If `main` is red, no cluster starts work. The chief of staff gets it fixed first (on 2026-10-25, a red Linux check made every sub-PR show red for hours).

## Context budget

Cluster leads and the chief of staff are automatic sessions: 250k tokens to wrap up, 300k to stop (AGENTS.md, "How to work"). The aim is to end every session under 300k.

- Delegate every read of a big file, every diff review, every log, and every fix to a background agent. Ask for a summary of under 300 words, and full detail written to a file the lead reads only if needed.
- Never paste issue bodies, diffs, CI logs or audit text into the lead's own context when an agent can summarize them.
- At **200k**, write a hand-off note in your status comment: what's done, what's next, open sub-PRs, and anything learned. Then finish the current push.
- At **250k**, stop. The chief of staff tells the run's lead session, which starts a fresh lead from the status comment.
- Helpers use Sonnet. Use Opus helpers only for careful review or design. No Haiku.

## Wind-down

When every rollup is merged or handed back:

1. Each lead sets its status comment to its final state and stops.
2. The chief of staff removes the run's merged worktrees and local branches (the housekeeping in AGENTS.md's 2026-10-14 calls), and checks that every finished issue is closed.
3. The run's lead session posts a short retrospective on the tracking issue (what merged, what was handed back, token use per session, what to change), then closes it.
