---
name: thread-workflow
description: The life of one Spoken Margins project thread, from claiming a ready issue to the armed PR and the stop note, plus how to hand a PR to the Mac finisher or an issue back. Use at the start of every project thread that works an issue, and before you stop.
---

# One thread, one issue

A project thread works one issue and ends. When its PR is armed, or the issue is handed back, it posts the stop note and stops (section 8); the coordinator starts a fresh thread for the next issue. A cloud session may push only the branch it was given, so never start a second issue in the same thread.

**A thread ends "stopped", never "waiting on Cole" (Cole, 2026-11-22).** It holds a real decision only when only he can make it and the work can't go on without it (the [ask-cole skill](../ask-cole/SKILL.md) has the test). A phone check, a by-ear check, a Diagnostics export, an "after the next build" step, a check of merged work, and "should I keep working?" are not decisions: record them on the issue (section 4) and stop.

## 1. Before you start

1. Read the issue, its comments, and its area in [docs/areas.md](../../../docs/areas.md). An issue that changes what a listener sees or hears needs a **Design** comment before building (`needs-design` until then).
2. If the Dial on #589 reads Off, or Paced and its status says Holding, start nothing (finish a PR already under way first). If it reads Paced and the latest Mac tick on #337 says `HALT (usage breaker: Claude)` with no later `RESUMED`, start nothing. In Cloud max, ignore any HALT on #337 and the usage numbers: a note on #337 saying the Dial is Cloud max is enough, so don't stop to verify it. Whether to work while a HALT shows is never a question for the owner: the Dial decides. Paced and halted means stop quietly (finish your commit, push, post the stop note); Cloud max means keep going.
3. Claim it: add `in-progress`, remove `ready`, make sure it has exactly one area label, and comment exactly:
   `Claimed by project thread "<your thread title>"`
4. If its files likely overlap a running thread's, say so in a comment.

## 2. Do the work

1. Branch from the newest `origin/main` onto the branch this session was given (`git fetch origin main && git switch -c <session branch> origin/main`). Never push to `main` or `next`.
2. Write the change. Needing an iOS build, a simulator or captures is never a reason to skip or stop: write the Swift change, put host-testable logic in SessionKit, and let `main-t3` compile and test it after the merge. Say "Not checked: not built, no journey run" in the PR.
3. The cloud can't run Xcode. For app tests you may comment `/lane T3` with a `tests:` line and add `lane:queued`; never T4 or T5. A lane failure you can't reproduce goes to the Mac finisher (section 5); don't push guesses.
4. Run the host tests: `.venv/bin/python scripts/verify-tests.py --plan fast`, or the suites your change touches (Python, Node, SessionKit on Linux). Run a new regression test once without the fix and confirm it fails.
   On Linux run `scripts/run-sessionkit-linux-tests.sh`, never raw `swift test` (it rewrites `Packages/SessionKit/Package.resolved`), and stage files by path, not `git add -A`; the merge policy holds a PR that changes that file without `Package.swift` (#4972).
5. A fix for an owner-found bug names the test layer that should have caught it and adds a test there.
6. Before arming, have a fresh-context sub-agent review your diff against the issue's **Done when** and **Must not break**. Fix the real findings.

## 3. Open and arm the PR

1. One PR into `main`. The body names the issue as `Closes #N` (finishes it) or `Part of #N` (doesn't). A recurring cost needs a **Cost and catch** heading.
2. Arm it with the [lane-request skill](../lane-request/SKILL.md): add `automerge`. A `/lane T3` request is optional and never holds the merge.
3. The runner merges on PASS of the fast checks, signoff and, for audio, persistence or packet diffs, a clean "Codex audit (Astra) on <sha>" of the head. Don't wait for the audit, the lane or the merge; don't ask anyone to merge; set no timers on your own PRs.
4. PRs touching `.github/` or `scripts/lane-runner.py` are the owner's merge tap. Arm nothing there; the coordinator brings it to him.

## 4. Record what isn't code

Phone checks, by-ear checks, Diagnostics exports, "after the next build" steps, checks of merged work and every **Default taken** go on the issue as comments. They are never a `**Decision for Cole**` or `**Step for Cole**` and never a reason to end the thread waiting.

1. Comment on the issue, starting with the line `**Owner check**`: what to do, on which build or after which merge (the PR number), the exact steps, and what you or the next session will read when the result is in and what it unblocks. Write it so a session with no memory of this thread can act on the result.
2. Add `needs-owner` (leave `ready` off if only the check is left; `agent-verify` and `validate-by-use` issues keep their label and gain `needs-owner` only when the check needs his hands). `scripts/owner_card_guard.py` leaves an issue alone that has `needs-owner` and an `**Owner check**`, and `scripts/sm_owner_queue.py` lists it under "Owner checks". It is not a decision, so no thread waits on it.
3. Say it once in your stop note, then end the thread. Don't repeat it as a message asking for his reply.

Your last message ends with a question only when you hold a real decision (see the ask-cole skill, section 1) that blocks your work. Before asking the owner anything, run that skill.

An `agent-verify` issue shows a merged fix working with a host test, a real file or Diagnostics. Close it on a shown pass. On a fail, put it back to `ready` (milestone only if it blocks a release).

## 5. Hand-offs

**To the Mac finisher** (a lane failure on your own code that you can't reproduce or fix in the cloud):

1. The PR stays open into `main` with `Closes #N`.
2. Add `needs-mac`; remove `automerge` and `lane:queued`.
3. Post one comment starting `Handing to the Mac finisher:` with what fails and the report link, Done when, Must not break, the lane tier after the fix, and anything it must not change.
4. Stop pushing to that branch.

The finisher pauses on a Claude HALT in Paced or Off mode (never in Cloud max), disk under 20 GB, or Dial Off. It won't take lane faults, product or taste calls, packet or database calls, fixes over about an hour, or `.github/` and `scripts/lane*` changes. Details: [docs/workstreams/finisher.md](../../../docs/workstreams/finisher.md).

**Back to the queue** (you can't finish it): remove `in-progress`, add `ready`, and say why on the issue. The only valid reasons are the owner's phone or data, a named defect in the code or the Design (cite `file:line`), or the label `where:mac`. "Needs a Mac build" is never one.

**To another session**: never ask the owner to pass a message, paste text, or check on another thread. Message the coordinator instead.

## 6. Threads on the owner's Mac

A `where:mac` issue (Mac hardware, signed-in Mac accounts or a physical device), a ready issue no cloud thread can finish, or anything the owner asks for on the Mac goes to a thread on the owner's Mac. Check #337 first. That thread:

1. Works in its own worktree: `cd ~/Documents/GitHub/spoken-margins-native && git fetch origin && git worktree add .claude/worktrees/<slug> -b ws/<issue>-<slug> origin/main`, then `scripts/setup-worktree.sh`.
2. Builds only through `scripts/xcodebuild-lane`, with memory pressure normal and at least 10 GB free plus 4 GB per running build.
3. Never boots a simulator.
4. After the merge, deletes the worktree's `.build` folder and removes the worktree.
5. Takes the next Mac-only ready issue after arming. The headless Claude Mac worker (`ops/claude/`, #1599) does the same unattended.
6. **Ends its own Claude Code session (Cole, 2026-11-22: no idle sessions).** Once its work is merged or handed off, it posts the stop note (section 7) and then exits its session, so it never sits idle holding a session on his computer. The long-lived Mac finisher is the only exception. This is about the session on the Mac; nothing here closes or resolves a thread in the project.

The project instructions' pointer to "Threads on the owner's Mac" means this section.

## 7. Stop note

On stopping for any reason, comment on your issue exactly:

`Thread "<your thread title>" stopping: <PRs you armed> · <reason>. Nothing needed from Cole.`

Post the same line as the last thing in your final chat message (it is the whole message when you have nothing else to report). Then end the thread. If a PR event wakes it later, section 8 says how that turn ends. A thread listed as waiting must hold a real decision; the coordinator resolves one that is only waiting on an owner check, a phone step or "keep going?" (dispatch skill, section 0). The `ops/` wrappers that post a Mac worker's own stop notes keep their format; they match only the `Thread "<title>" stopping:` prefix.

## 8. What your last turn says (Cole, 2026-11-22, #4986)

The owner's sidebar files a thread under "Waiting on you" when the system's summary of the thread's latest turn says it needs input. The summary is rewritten after every turn, including a short turn woken by a PR event, and it follows what that turn ends on. A stop note that was right was overwritten by a later wake turn that ended "I will not re-label again until the limit clears". The findings and what is still only inferred are in the [record](../../../docs/decisions.md) (2026-11-22, "A thread's last turn decides"). So:

1. **End on the stop line or on a real ask, nothing after it.** The last thing the thread says is either a `**Decision for Cole**` or `**Step for Cole**` (and then it is a real wait), or the stop line ending "Nothing needed from Cole."
2. **You may keep watching your PR.** A session that opens a PR is subscribed automatically, and you may stay subscribed after the stop line to act on a queue drop or a failure on the PR's own code, as the lane-request skill (section 4) says. Whatever such a wake turn does, it ends on exactly this last line: `Nothing needed from Cole.` Don't end it on a comment about the check, a status, or what you will do next.
3. **A turn never ends on a sentence that promises or defers your own action**: "until the limit clears", "then I will re-label", "waiting on the audit", "events will wake me", "I'll re-check".
4. **Leave no checklist step open that reads "Waiting on...".** Before the stop line, bring every line to its true end state; a step that waits on a runner, an audit or a merge is not yours and is not listed.
5. **Owner checks stay on the issue (section 4), out of the final chat text.** The coordinator carries them to him from the owner queue. A closing line such as "Owner check recorded on #N" or "waits for your phone check" read as needing input on slot MS, Finish Margins and slot MY.

That a later turn overwrites an earlier stop line is confirmed from the transcripts. Rules 1 to 5 are the working explanation and are still being tested; in particular, slot MY stayed subscribed and read "completed" after a wake turn ending "nothing new to act on", but the exact closing line in rule 2 has not been tried yet. A thread that shows the wrong state under them goes in `/mnt/project-files/notes/waiting-state-findings-2026-11-22.md`, so the rules are corrected from evidence and not from a guess.
