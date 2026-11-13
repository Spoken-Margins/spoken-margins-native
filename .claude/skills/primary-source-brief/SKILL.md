---
name: primary-source-brief
description: Brief a helper agent (Sonnet sweep, Explore, critic, inventory) so every claim it returns cites a primary source, and check two of those claims before acting on its answer. Use whenever you hand a helper a question about GitHub state, code, deploys or what merged, and before you repeat a helper's answer to the owner or act on it.
---

# Briefing a helper on primary sources

**The failure it prevents.** A helper reads a comment that says "merged", "deployed" or "waiting on #N" and reports it as fact. Comments go stale; the code and GitHub's own fields don't. On 2026-11-04 an inventory repeated "deploy the server" a day after the deploy. The same day's audit found GitHub saying things `main` didn't: #3218 open after its fix merged, #460 silent about a revert, #1612 held on a PR merged two weeks before.

## 1. Put these lines in every brief

Paste them as written, under the question:

```text
Every claim you return names where you read it, as one of:
- file:line at a commit (e.g. scripts/trunk.py:21 at 26f30d4a2)
- a commit sha, with the command that shows it (git merge-base --is-ancestor <sha> origin/main)
- a gh JSON field with its command (gh pr view 3315 --json mergedAt,baseRefName,closingIssuesReferences)
- a live URL you fetched in this run, with what it returned
A comment, issue body, PR description, memory note or doc is a lead, not a source: say "comment says X" and then check X in one of the four.
If you could not check a claim, write "unchecked" beside it. That is an allowed answer; a guess is not.
Say for each item whether it is built (on origin/main), merged elsewhere, open in a PR, or only planned.
```

## 2. What counts as the source

| Claim | Read this, not the comment |
|---|---|
| PR merged | `gh pr view N --json mergedAt,baseRefName,mergeCommit` |
| fix is on main | `git merge-base --is-ancestor <mergeCommit> origin/main` |
| issue closed by a PR | `gh pr view N --json closingIssuesReferences`, then `gh issue view M --json state,closedAt` |
| reverted | a merged PR whose title or body says `Revert #N`, and its `mergedAt` |
| deployed / running | the host itself (health URL, `systemctl status`, the deploy log), never a PR or comment |
| code does X | `file:line` at a named commit |
| a label or claim is current | `gh issue view N --json labels,comments` and the newest comment's `createdAt` |

## 3. Before you act: check two claims

1. Pick the two claims your next action depends on most (a close, a merge, a message to the owner).
2. Re-run their cited commands yourself. Don't ask the helper again.
3. Both hold: act, and name the two you checked ("checked: #3315 `mergedAt` 2026-11-04T02:02:41Z; 9c5bc28 is on main").
4. One fails or has no source: treat the whole answer as leads. Re-check each claim you use, or send a narrower brief.
5. Never forward "unchecked" claims to the owner as fact. List them as unchecked.

## 4. Keep it small

- Ask for the answer and its sources, not the files' contents (AGENTS.md, "Keep bulk out of your context").
- One question per helper. A helper asked "what's the state of everything" returns comments.
- Helpers run on Sonnet. Haiku 5.5 at low effort may sort or label text handed to it (at most 3 issues or about 4,000 words a batch); it never makes a claim about code or GitHub state, and its output is checked before anyone acts on it. Never Haiku 4.5. (2026-11-12, replacing the 2026-10-20 "never Haiku".)
