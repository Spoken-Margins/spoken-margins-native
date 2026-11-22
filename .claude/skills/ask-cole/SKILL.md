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
6. **Is it one of the things that are never decisions (Cole, 2026-11-22)?** Whether to keep working (the Dial on #589 decides; on Cloud max a HALT on #337 is ignored, so keep going), whether to take the next issue (the queue rules decide), a phone check, a by-ear check, a Diagnostics export, an "after the next build" step, or checking merged work. Don't ask. Write an `**Owner check**` comment on the issue, add `needs-owner`, and end the thread stopped ([thread-workflow skill](../thread-workflow/SKILL.md), section 4). He has said that sessions ending on these asks fill his waiting list with things that need no answer.

Ask only when it touches his data, packet or database compatibility, money, his accounts or devices (beyond housekeeping), anything public, `main` or a release, a merge of a workflow change that touches permissions, secrets or self-hosted runners, or a real secret (a key, token or password) that only he holds. A clash between two of his standing calls goes to him as one question.

**Real decision test.** A thread may end waiting on him only when both are true: the choice is one only he can make (the list above), and the thread's own work cannot go on without it. If you can finish your PR, do; put the question on the issue as a **Decision for Cole** card and end stopped. A thread that has nothing left to do except wait for his phone or his export is stopped, not waiting.

**How a thread ends decides how the sidebar shows it (#4986).** A real ask is the last thing the thread says, with nothing after it. A thread with no ask ends every turn, including a later turn woken by a PR event, on exactly `Nothing needed from Cole.`; it never ends on a question, a deferred action of its own, or a closing line that names an owner check ([thread-workflow skill](../thread-workflow/SKILL.md), section 8).

## 2. How to ask

Write it in full in the chat (a project thread in its own thread; the coordinator in the project chat), under a heading:

- `**Decision for Cole**`: what this is, the question, your pick, the options with their cost, what it blocks.
- `**Step for Cole**`: only for a step on his accounts or machines that blocks the work and that no script or thread can do (a real secret, a console he alone can sign in to). Numbered steps, the full link, what to tap and type, how long it takes, and what happens after.

Lead with the answer, use short plain sentences, and put issue numbers at the end. Never let colour alone carry meaning. More on how he reads is in `OWNER.md`, "Working with the owner".

A phone run, a listen or an export is not a card: it is an `**Owner check**` on the issue (see 1.6), with no chat ask.

Repeat the ask as an issue comment for the record. "Needs your decision, see #N" is never enough on its own.

## 3. After he answers

An answer that will recur goes into `docs/decisions.md` the same day, quoting him with the date, in a docs-only PR. A tap on a question is his answer: quote the question and his pick.
