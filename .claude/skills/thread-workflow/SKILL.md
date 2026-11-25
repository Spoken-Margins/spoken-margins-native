---
name: thread-workflow
description: The life of one Spoken Margins project thread, from claiming a ready issue to the armed PR and the stop note, plus how to hand a PR to the Mac finisher or an issue back. Use at the start of every project thread that works an issue, and before you stop.
---

# One thread, one issue

A project thread works one whole issue and ends. **One PR per issue (Cole, 2026-11-23).** The thread keeps its issue until all of its agent work is in that PR and the PR is armed (or merged), then posts the stop note and stops (section 7); if it can't finish, it hands the issue back (section 5). A Design comment or an older comment that plans several steps or slices for the issue doesn't change this: build all the remaining steps in the one PR. The only split is two PRs when a database or packet change must ship before the feature (so the last shipped build can still open the database or import the packet): the first PR holds only that change and says `Part of #N`; the same thread keeps the issue, and when the first PR merges (the PR event wakes it) it restarts its session branch from the newest `main` and opens the second PR with `Closes #N`. Never push the second part onto the armed first PR's branch. In that case there is no stop note after the first PR; the thread posts it after the second PR is armed (or when it hands the issue back). After the stop note, the coordinator starts a fresh thread for the next issue. A cloud session may push only the branch it was given, so never start a second issue in the same thread.

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
3. The cloud can't run Xcode. For app tests you may dispatch `branch-t3` (`gh workflow run branch-t3.yml --ref main -f branch=<your branch> -f tests='ClassA ClassB' -f pr=<n>`; the [lane-request skill](../lane-request/SKILL.md), section 3): a hosted Mac runs those classes and comments PASS or FAIL on the PR. `lane.yml` is off, so a `/lane T3` comment gets no answer (#4839). Never ask for T4 or T5. A lane failure you can't reproduce goes to the Mac finisher (section 5); don't push guesses.
4. Run only the host tests your change touches (Cole, 2026-11-23): `scripts/test-scope.py` prints the tier and what to run, for example the Python tests of the scripts you changed, the Node suite of the page you changed, or SessionKit on Linux. A change under `App/` or `Packages/` also runs `python3 scripts/swift_scan_tests.py`, the Swift source scans every PR check runs (#5220). Don't run the whole `verify-tests.py --plan fast`; the lane and the merge queue run the full suites on every armed PR. Run a new regression test once without the fix and confirm it fails.
   On Linux run `scripts/run-sessionkit-linux-tests.sh`, never raw `swift test` (it rewrites `Packages/SessionKit/Package.resolved`), and stage files by path, not `git add -A`; the merge policy holds a PR that changes that file without `Package.swift` (#4972).
5. A fix for an owner-found bug names the test layer that should have caught it and adds a test there.
5a. **A listener-facing issue (any area but groundwork) is proved by a real run, not by fixture tests (Cole, 2026-11-22).** Before you call it done, run it the way the listener would: the real link, file or screen, covering every hop from where they start to where they see or hear the result (the sending side and the receiving side of a share link, not one of them). Use what the session has: a host test on the real artifact, a real URL in Playwright's Chromium, the lane or Test Desk for the simulator. Record it as a `**Real-use proof**` (Real input, Path, Steps, Result: PASS, Commit) in the PR body or on the issue. A run that fails is recorded as `Result: FAIL` and fixed, never skipped. [docs/workstreams/real-use-proof.md](../../../docs/workstreams/real-use-proof.md) has the record and `scripts/real_use_proof.py`.
6. Before arming, have a fresh-context sub-agent review your diff against the issue's **Done when** and **Must not break**. Fix the real findings.

## 3. Open and arm the PR

1. One PR into `main` for the whole issue. The body names the issue as `Closes #N` (finishes it) or `Part of #N` (doesn't: only the first of the two allowed PRs, or when the real-use proof is still owed). A recurring cost needs a **Cost and catch** heading.
   - **`Closes #N` on a listener-facing issue needs its real-use proof on the PR or the issue, or the `merge policy` check holds the PR** (the reason says what is missing). If you could not run it before the merge (an app change with no simulator in your session), write `Part of #N`, say "Merged, not yet shown working" in the PR, and put an `**Owner check**` or a `ready` follow-up on the issue for the run; the issue closes when the proof is recorded. `Real-use proof waived: <reason>` is only for work with no listener surface.
   - **In a cloud session, don't open the PR yourself (#4915).** The cloud's proxy sends everything as the owner, so a PR you open is his, and GitHub won't let him approve it. Push and ask the App instead; a session on the owner's Mac that acts as the App still opens its PR with `gh pr create`. Commit your work first; the request commit must change no file, so stage nothing for it. Write the PR message to a file outside the repository (never commit it): line 1 `PR: <title>`, a blank line, the body as above, and, as the last paragraph, `PR-Labels: automerge` when step 2 would arm it (only `automerge` is honoured; leave it off for a step 4 PR). Then:
     ```
     git commit --allow-empty --cleanup=verbatim -s -F /tmp/pr-message.txt
     git push origin HEAD
     gh api -X POST repos/Spoken-Margins/spoken-margins-native/actions/workflows/open-cloud-prs.yml/dispatches -f ref=main -f "inputs[branch]=$(git branch --show-current)"
     ```
     `open-cloud-prs` (on `main`) opens the PR as `spoken-margins-agent[bot]`, usually within a minute; if the dispatch call fails, its 20-minute schedule picks the branch up. Find the PR with `gh api "repos/Spoken-Margins/spoken-margins-native/pulls?head=Spoken-Margins:$(git branch --show-current)" --jq '.[0].html_url'`. Only a `claude/` branch pushed in the last 7 days that never had a PR is opened, from its newest `PR:` commit; a closed PR is never reopened, so push a new branch instead. Later pushes, labels and comments on the open PR work as before.
2. Arm it with the [lane-request skill](../lane-request/SKILL.md): add `automerge` (in a cloud session, the `PR-Labels: automerge` line above does it). A `branch-t3` run is optional and never holds the merge.
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

**"The owner's phone or data" needs a repro attempt first (Cole, 2026-11-22).** Before you hand an issue back, skip it or label it `needs-owner` for his phone or data, try to reproduce it yourself with what you have: the real link or file in a browser, a host test on the real artifact, the simulator through the lane. Then comment on the issue: `**Repro attempt**`, `Tried:` (what you ran, on which real input), `Result:` (reproduced or not, and what you saw), and `Needs from owner:` (only the exact thing only his phone or account has). Without that comment the issue goes back to the queue (`scripts/real_use_proof.py --parked` lists them). A reproduced bug is yours to fix.

**To another session**: never ask the owner to pass a message, paste text, or check on another thread. Message the coordinator instead.

## 6. Threads on the owner's Mac

A `where:mac` issue (Mac hardware, signed-in Mac accounts or a physical device), a ready issue no cloud thread can finish, or anything the owner asks for on the Mac goes to a thread on the owner's Mac. Check #337 first. That thread:

1. Works in its own worktree: `cd ~/Documents/GitHub/spoken-margins-native && git fetch origin && git worktree add .claude/worktrees/<slug> -b ws/<issue>-<slug> origin/main`, then `scripts/setup-worktree.sh`.
2. Builds only through `scripts/xcodebuild-lane`, with memory pressure normal and at least 10 GB free plus 4 GB per running build.
3. Never boots a simulator.
4. After the merge, deletes the worktree's `.build` folder and removes the worktree (see "Your own worktree" below).
5. Takes the next Mac-only ready issue after arming. The headless Claude Mac worker (`ops/claude/`, #1599) does the same unattended.
6. **Ends its own Claude Code session (Cole, 2026-11-22: no idle sessions).** Once its work is merged or handed off, it posts the stop note (section 7) and then exits its session, so it never sits idle holding a session on his computer. The long-lived Mac finisher is the only exception. This is about the session on the Mac; nothing here closes or resolves a thread in the project.

The project instructions' pointer to "Threads on the owner's Mac" means this section.

## Your own worktree

Any thread that makes a git worktree removes it. Make it under `.claude/worktrees/<slug>` of the main checkout and nowhere else: never `../sm-*`, `../smn-*` or `../spoken-margins-native-*` beside the repo (Cole, 2026-11-22; 39 of those piled up and were never cleaned). Remove it once its PR has merged, or when you hand the work off or stop, whichever comes first:

1. `git status --porcelain` is empty and the branch is pushed. If not, commit and push, or leave the worktree and say so in the stop note.
2. Delete its `.build` folder, then `git worktree remove <path>`. Never `--force`.
3. Don't touch a worktree you didn't make: the Test Desk's, the finisher's, `.codex/` ones.

The Mac tick also removes merged, clean worktrees outside `.claude/worktrees/` (docs/scheduled-jobs.md), but that is the backstop, not the plan.

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
