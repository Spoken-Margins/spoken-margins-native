---
name: ask-cole
description: The check every Spoken Margins session runs before asking the owner anything (a Decision for Cole, a Step for Cole, an approval, a phone check), and the format the ask must take. Use before any message, issue comment or queue item that asks the owner to decide or do something.
---

# Before you ask the owner

The owner reads only the Claude project chats, never GitHub, and every ask costs him attention. Many past asks did not need him: calls an agent could take, housekeeping, repeats of an answered question, and messages to carry between sessions.

## 1. Can you avoid asking?

Answer each in order. Any "yes" means don't ask.

1. **Is it reversible or technical?** Refactors, tests, lanes, scheduling, labels, internal structure, dead code: post a **Default taken** on the issue (options, pick, why) and keep going. He vetoes by number.
2. **Is it housekeeping?** Superseded PRs, merged-fix issues, labels, re-arming, stale claims, worktrees and caches that `ops/disk` calls safe, Test Desk and Mac worker starts. Do it.
3. **Did he already answer?** Search `docs/decisions.md`, the issue, and project memory. If an earlier answer covers it, act on it and quote it.
4. **Can a script, a thread or the coordinator do it?** Then they do it. Another session's work goes through the coordinator (threads use their message-the-coordinator tool), never through him. Never ask him to relay a message, paste text into another session, or check on another thread.
5. **Was it asked before with no new facts?** Don't ask again. If a blocker repeats, file one issue for its lasting fix and stop repeating the ask.

Ask only when it touches his data, packet or database compatibility, money, his accounts or devices (beyond housekeeping), anything public, `main` or a release, a merge of a workflow change that touches permissions, secrets or self-hosted runners, or a real secret (a key, token or password) that only he holds. A clash between two of his standing calls goes to him as one question.

## 2. How to ask

Write it in full in the chat (a project thread in its own thread; the coordinator in the project chat), under a heading:

- `**Decision for Cole**`: what this is, the question, your pick, the options with their cost, what it blocks.
- `**Step for Cole**`: numbered steps, the full link, what to tap and type, how long it takes, and what happens after.

Lead with the answer, use short plain sentences, and put issue numbers at the end. Never let colour alone carry meaning. More on how he reads is in `OWNER.md`, "Working with the owner".

Repeat the ask as an issue comment for the record. "Needs your decision, see #N" is never enough on its own.

## 3. After he answers

An answer that will recur goes into `docs/decisions.md` the same day, quoting him with the date, in a docs-only PR. A tap on a question is his answer: quote the question and his pick.
