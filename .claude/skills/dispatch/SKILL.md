---
name: dispatch
description: The Spoken Margins coordinator's hourly dispatch - what to do with lane reports, audits, merges, the Mac finisher and Test Desk batches on automerge PRs. Use only in the hourly dispatch scheduled task or when the coordinator is asked to run dispatch by hand.
---

# Hourly dispatch

Runs at 20 past each hour as a scheduled task in the project. If there is nothing to do, end without posting.

## 0. Gates

1. Read the Dial on #589. Off, or Paced and Holding: start nothing. Paced: if the latest Mac tick on #337 says `HALT (usage breaker: Claude)` (or an unscoped `HALT (usage breaker)`) with no later `RESUMED`, start nothing and tell running threads to finish their commit, push, post their stop note and stop. Cloud max: the breaker does not stop dispatch.
2. Follow the latest "advice for dispatch" line on #337 for pacing, unless the Dial is Cloud max.
3. Run `python3 scripts/sm_sweep.py` and act on what it prints; `--apply` releases stale claims. It looks for free Claude slots, the Mac idle while `where:mac` ready issues exist (start a Mac thread), `in-progress` claims quiet for 6+ hours, armed PRs red on their head, T4 requests waiting over an hour with no desk running (start a Test Desk), `needs-mac` PRs untouched for an hour, and draft PRs (into any base) with no commit for 24 hours. A stalled draft goes to a free thread to finish, test and arm, or is closed with a line saying why; nobody else watches drafts, and an owner session that built one may be archived. Before any status line, run `python3 scripts/sm_status.py` and name what you checked.

4. **Resolve threads waiting on non-decisions (Cole, 2026-11-22).** List the project's threads in the `blocked` state. For each, read its last ask. It is a real wait only if it is a decision only the owner can make and the thread can't go on without it. If it is a phone check, a by-ear check, a Diagnostics export, an "after the next build" step, a check of merged work, or "keep working under a HALT?", then: make sure the issue carries an `**Owner check**` comment with the steps and `needs-owner` (write the comment yourself from the thread's ask if it didn't), then resolve the thread. Under Cloud max the answer to a HALT question is always "keep going": message the thread to continue if its PR isn't armed, else resolve it. Never message the owner about it.

   Read the thread's own last message, not only its PR's checks. A red check on a thread's PR very likely puts the thread in "Waiting on you" too (all three rows of Cole's sidebar on 2026-11-22 had one; inferred, not isolated), and `list_threads` state is not the sidebar's group, so don't clear a thread because that state says `done`. A change under #4986 makes a PR that only waits on its audit or the owner's tap leave `merge policy` pending instead of red; once it has merged, a red `merge policy` is a real hold or a fault, and until then it can be either. If the thread's last turn is a wake turn that ended on a comment about a check, a status, or a promise of its own next step ("until the limit clears", "waiting on the audit"), the system's summary reads that as needing input: message the thread to end on exactly `Nothing needed from Cole.`, and add the thread and what its last turn said to `/mnt/project-files/notes/waiting-state-findings-2026-11-22.md`. A thread that stays waiting after that, with a last turn ending on exactly that line, is evidence against the rules in [thread-workflow](../thread-workflow/SKILL.md) section 8: record it there too, and don't guess.

5. **Proof and parked issues (Cole, 2026-11-22).** Run `python3 scripts/real_use_proof.py --sweep --apply`: it reopens any listener-facing issue closed as completed without a `**Real-use proof**` on the issue or on the PR that closed it, and comments why. Then run `python3 scripts/real_use_proof.py --parked`: each open `bug` or `found-on-phone` issue it lists is parked on `needs-owner` with neither a `**Repro attempt**` nor an `**Owner check**`. Take `needs-owner` off, comment that a repro attempt comes first (thread-workflow skill, section 5), and put it back to `ready` if it has the five headings (else complete it). Report nothing to the owner unless a sweep read failed twice running.

## 1. Work through new lane reports and Codex audits on `automerge` PRs

1. **"Revert #N" PRs and `regression` issues first.**
2. **Lane fault** (no test ran, runner offline, INCONCLUSIVE for a lane reason): one rerun. For T3, a new `/lane T3` with the same `tests:` line plus `lane:queued`; for host tests, remove and re-add `automerge`. File a `ready,regression` lane issue only if it fails the same way again. "Fails on main too: not this PR" is not a lane fault: the runner has filed that test's issue, so don't rerun.
3. **The PR's own FAIL:** hand it to the Mac finisher (format in the [thread-workflow skill](../thread-workflow/SKILL.md), section 5). A conflict with `main`, a failing cloud test, confirmed audit findings or a finisher hand-back: give it to a free thread, else a fresh one.
4. **A clean Codex audit naming a held PR's head:** remove and re-add `automerge`.

## 2. Merged PRs

For each PR merged into `main`, on each issue it closes: remove `in-progress` and comment naming the PR. Close internal work (groundwork: model-split moves, test fixes, lane, pipeline or ops fixes) with `sm-gh close-issue` against the merged PR. **Never close a listener-facing issue (any area but groundwork) by hand until `python3 scripts/real_use_proof.py --issue N --pr M` exits 0** (M is the merged PR); a merged fix without proof stays open as `agent-verify` or `status: needs-human-validation` below, and any status line says "merged, not yet shown working", never "fixed" (docs/workstreams/real-use-proof.md).

For a listener-facing fix, don't add `status: needs-human-validation` by default. Pick one:

- `agent-verify` when an agent can show it working (host test, real file, Diagnostics). Dispatch it as verification work, one thread per issue, ahead of new feature work.
- `validate-by-use` when the owner will meet it in ordinary listening, and only once the work is merged. Comment "Owner check: none. Leave this off the owner's plans.", take it out of any release milestone, and close it when Diagnostics, or his use with no complaint, show it working.
- `status: needs-human-validation` only for ears, hands on the phone, or taste: audio, Bluetooth, Lock Screen, background, design.
- When unsure, `agent-verify`.

## 3. The Mac finisher and the Test Desk

1. **Finisher watchdog:** if the Mac finisher has done nothing for over 45 minutes and no pause applies (a HALT outside Cloud max, disk under 20 GB, Dial Off), message its thread to restart. If the Mac is offline, tell the owner once, with the steps to wake it.
2. **Stuck hand-offs:** any `needs-mac` PR with no finisher comment or commit an hour after its hand-off gets a direct question to the finisher's thread asking why it hasn't taken it, even while a pause is on. Ask the finisher before ever asking the owner.
3. **Test Desk batches:** if the latest Mac tick on #337 has a `- Test Desk: GO` line and no desk is running, start one managed desk on the work list it names. Start nothing during a Claude HALT in Paced or Off mode; Cloud max ignores it.

## 4. Fill free slots

Start threads from the ready queue up to the Dial's thread count, in the queue order in the project instructions, one thread per issue. The thread builds the whole issue in one PR and keeps it until that PR is armed, even when the issue or its Design comment plans several steps; two PRs only when a database or packet change must ship first, and then the same thread writes both (Cole, 2026-11-23, [thread-workflow skill](../thread-workflow/SKILL.md)). An issue whose `Part of #N` first PR merged while its thread still holds the claim is not stale and not free. SessionKit issues first; one `hot-file` thread at a time. If an issue's files likely overlap a running thread, say so in a comment and in the new thread's first message. Start nothing else unless the owner asks. Never report the queue empty while `ready` issues remain; name each stuck one and its real reason instead. When a thread reports "nothing left", check the ready list yourself and dispatch what it skipped.
