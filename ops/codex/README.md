# Codex worker

A Mac-side worker that finishes PRs before taking `ready` issues with Codex (`gpt-6.1-sol`, reasoning effort `high`), paced by the Dial (#589), so spare Codex allowance gets used. Nothing here is installed by default.

## What it does

launchd runs `sm_codex_worker.py` every 10 minutes. Each run (a tick) reads:

1. The Dial's `**Codex workers**` group (0 to 3). No group, no tick, or Mode Off means 0. Two ticks take the lower.
2. Codex usage (`codex app-server`, `account/rateLimits/read`). It holds at the Codex stop line minus 3, or when usage is more than 5 points ahead of a straight line from the Codex window's start to its finish-by time, scaled to the stop line. With no Codex pacing ticks, it uses the Dial's Stop line and Codex's reset. It also holds when the read fails or no readable stop line is ticked.
3. Free disk. It holds below 30 GiB.
4. Live slots: `~/SpokenMarginsOps/codex-worker/slot-N.lock` files whose pid is still a worker.

If a slot is free and nothing holds, it picks one job and starts one detached child, then exits. It starts at most one child per tick. PR finishing and issue runs share the same slots, Dial and pacing.

**PR finishing comes first:** open non-draft PRs into `next`, with a branch in this repo and either `needs-mac`, a newest lane report that names the current head and reports a test or compile FAIL, or a newest ``**Codex audit (Astra) on `<sha7>`**`` comment that names the head and does not open with "No blocking findings". An older-head FAIL, a newer PASS or INCONCLUSIVE, and runner faults do not qualify as code failures. PRs touching `LANE_PREFIXES`/`LANE_FILES` in `scripts/test-scope.py` qualify only for audit findings on the head. Protected branches and live-slot PRs are skipped. Each `Thread "Codex worker N" finishing #PR` comment counts as a round, including failed attempts and earlier heads: at most two rounds per PR in a rolling 24 hours. At the limit the worker comments once in that window and leaves the PR for a human. Oldest eligible PR goes first; the child rechecks before claiming.

**The finisher** posts that finishing comment, removes `automerge`, and checks it is gone. It checks out the PR head in a detached worktree (leaving the author's local branch alone), merges `origin/next` with `--no-commit --no-ff`, and gives Codex the lane report, current-head audit findings and a summary of failures, evidence paths and merge conflicts. For each audit finding the prompt asks for a fix with a regression test shown to fail first, or an evidence-backed explanation in `.codex-out/pr-body.md` of why the finding is wrong. The wrapper posts that explanation as a PR comment even if no code changes are needed; without a push it leaves `automerge` removed. Codex uses the same sandbox and output files as issue jobs. The wrapper runs `--plan fast` outside the sandbox. On a pass it commits the fix and merge, rechecks that the PR has neither moved nor been re-armed, and pushes `HEAD` to the existing PR branch with an ordinary push. A rejected push stops; there is no force retry. It comments the change, removes `needs-mac`, repeats the newest `/lane T3` request with its original `tests:` line and `lane:queued` when applicable, then adds `automerge`. The audit script audits the new head on its next tick. Queueing precedes arming so the runner sees the pending T3 immediately. On any stop it posts why and leaves the original labels except `automerge`; failed work is not pushed. Finisher evidence stays in `codex-worker/runs/pr-<PR>-<time>/`.

**Issue choice:** open, labelled `ready`, and not labelled `in-progress`, `where:mac`, `regression` or `blocked`. No `Claimed by project thread "` comment in the last 24 hours. Issues labelled `priority` go first; within that, issues that name SessionKit paths or host tests go first, then oldest first. The child checks again just before it claims.

**The child** claims the issue (label `in-progress` and a claim comment as "Codex worker N"). It makes the worktree `codex-worker/wt-N` on `ws/<issue>-codex-<slug>` from fresh `origin/next`, resolves SessionKit's packages (the sandbox has no network), then runs `codex exec` (workspace-write, 60-minute cap). The sandbox may also write the lane's slot folder and the clang module cache. Codex sets `CODEX_SANDBOX` there, and `verify-tests.py --plan fast` then skips `runner-tests` (the sandbox refuses `ps`), reports the known real-audio SessionKit tests without failing on them, and ends as `verified_in_codex_sandbox`, which no gate accepts. Then:

- Codex gave up, failed, or changed nothing: it posts a stop note and removes `in-progress`.
- Otherwise the wrapper runs `--plan fast` itself:
  - If the plan fails, it commits and pushes the branch for a human, opens no PR, posts a stop note and removes `in-progress`.
  - If the plan passes, it commits (with a Codex co-author line), pushes, opens the PR with `automerge`, and posts `stopping: PR #X armed · done`.

The worktree, the local branch and the lock are always removed. Codex's transcript, answer, diff and the fast-plan output stay in `codex-worker/runs/<issue>-<time>/`. The log is `codex-worker/log.txt`.

## Dial text to paste into #589

Paste this above the `---` line:

```text
**Codex workers** (Codex runs on the Mac; holds 3 points below the stop line and when ahead of the Codex trend)
- [x] 0
- [ ] 1
- [ ] 2
- [ ] 3

**Codex stop line** (Codex weekly usage; Codex holds 3 points below it)
- [ ] 70%
- [ ] 80%
- [ ] 90%
- [ ] 97%

**Codex finish by** (Codex follows a straight line from its window's start to its stop line at this time)
- [ ] Fri noon
- [ ] Sat 7 AM
- [ ] Codex reset
```

The Codex pacing groups leave Claude's Dial unchanged. Two stops take the lower; two finish times take the later, resolved as the next occurrence after the Codex window's start in Eastern time. After that time the trend stays at the stop line. An unrecognized checked stop holds work; an unrecognized checked finish includes Codex reset among the choices. Each tick and dry run reports the chosen stop and resolved finish time. The worker never edits the Dial body.

## Try it

Run a dry run. It prints the Dial read, Codex usage, slots and the PR or issue it would pick, and changes nothing:

```zsh
/usr/bin/python3 ~/SpokenMarginsOps/repo/ops/codex/sm_codex_worker.py --dry-run
```

Run the host tests:

```zsh
/usr/bin/python3 -m unittest ops/codex/test_sm_codex_worker.py
```

## Install (owner's call)

The tick runs from the `~/SpokenMarginsOps/repo` checkout, so that checkout needs this folder (pull `next` there after this merges). Then:

```zsh
mkdir -p ~/SpokenMarginsOps/codex-worker
```

```zsh
cp ~/SpokenMarginsOps/repo/ops/codex/com.spokenmargins.codex-worker.plist ~/Library/LaunchAgents/
```

```zsh
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.spokenmargins.codex-worker.plist
```

To stop it, untick to `0` on the Dial (running children finish), or remove the job:

```zsh
launchctl bootout gui/$(id -u)/com.spokenmargins.codex-worker
```

## Known limits

- A child that is killed (for example, by a reboot) leaves its issue labelled `in-progress`. The next tick clears the dead lock and logs the issue number, but leaves the label for a human.
- New issue PRs get no `/lane T3` request from the worker. Finishers repeat an existing newest T3 request; they do not invent test selectors. The prompt keeps Codex to host-testable work, and the runner's own tier rules still apply.

## Codex audit

`sm_codex_audit.py` is the mechanical Codex (`gpt-6-astra`) audit of PRs into `next`. launchd runs it every 20 minutes (`com.spokenmargins.codex-audit.plist`). Its docstring has the full gating rules. In short, it audits an open PR when:

1. The PR has no Codex audit comment naming its head.
2. Its newest lane report is a PASS on the head.
3. It touches a risky area (sharing, persistence, audio, or the lane itself: `.github/workflows/`, `scripts/lane*` and the runner's helpers), or the runner says it is waiting on an audit, or a comment asks for one.

After a clean audit ("No blocking findings") it removes and re-adds `automerge` once, so the runner's automerge job runs again and can merge.

`codex_limits.py` reads Codex usage for it. The audit holds when usage is used up or the read fails. The log, lock and kept Codex outputs are in `artifacts/ops/` (`codex-audit.log`, `codex-audit.lock`, `codex-audit-outputs/`).

Keep the `lane` patterns in step with `LANE_PREFIXES` and `LANE_FILES` in `scripts/test-scope.py`.

Try it. A dry run prints each PR's decision and the re-arm check, and runs no Codex and posts nothing:

```zsh
/usr/bin/python3 ~/SpokenMarginsOps/repo/ops/codex/sm_codex_audit.py --dry-run
```

Run the host tests:

```zsh
/usr/bin/python3 -m unittest ops/codex/test_sm_codex_audit.py
```

### Switch over from artifacts/tools (owner's call)

Until 2026-10-01 the job ran an unversioned copy at `~/SpokenMarginsOps/repo/artifacts/tools/sm_codex_audit.py`. To move it to this folder, first update the ops checkout after this merges:

```zsh
git -C ~/SpokenMarginsOps/repo pull --ff-only
```

Then replace the job:

```zsh
launchctl bootout gui/$(id -u)/com.spokenmargins.codex-audit
```

```zsh
cp ~/SpokenMarginsOps/repo/ops/codex/com.spokenmargins.codex-audit.plist ~/Library/LaunchAgents/
```

```zsh
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.spokenmargins.codex-audit.plist
```

Check that it points at the new path:

```zsh
launchctl print gui/$(id -u)/com.spokenmargins.codex-audit | grep ops/codex
```

Both copies share the same lock in `artifacts/ops/`, so an old run still going can't overlap a new one. The old files in `artifacts/tools/` can stay as a fallback; nothing runs them after the switch.

## Codex Test Desk

`sm_codex_testdesk.py` tests fresh `origin/next` at most once per SHA and once every two hours. Its 20-minute tick holds on the worker's Dial and pacing rules, under 30 GiB free disk, or any busy simulator slot. It reserves the existing simulator and decision locks without waiting; `verify-tests.py` inherits the reservation for `--plan app` followed by `--plan journeys` (gating and probation). Both plans use the dedicated Test Runner. It never selects the journey simulator or boots a device itself.

It posts PASS / FAIL / INCONCLUSIVE with test counts and evidence on #184. Completed non-probation test failures get a read-only Codex diagnosis, grouped by root cause. It searches open issues for each failing method, comments on a match, or files `ready,priority,bug` for the worker. Probation failures do not turn a run red. Per-SHA journey results and the last start time live in `~/SpokenMarginsOps/codex-testdesk/state.json`; two consecutive passes are reported for the owner/Test Desk to promote, never promoted automatically. Class selectors count as passing only if every expected method passed. A flood or interrupted/stalled runner is INCONCLUSIVE and never retried on the same SHA.

Evidence survives worktree removal in `~/SpokenMarginsOps/repo/artifacts/codex-testdesk/<time>-<sha7>/`. The log is `~/SpokenMarginsOps/codex-testdesk/log.txt`. A result is saved before posting or diagnosis; a GitHub error therefore requires a human to post the saved report or issue bodies, rather than another simulator run. After an abrupt process termination, the next eligible tick removes only this job's scratch worktree. Agent-driven journeys, audible content and the Lock Screen remain unverified.

Dry run (reads Dial, usage and cached `origin/next`; no fetch, tests, worktree or posts):

```zsh
/usr/bin/python3 ~/SpokenMarginsOps/repo/ops/codex/sm_codex_testdesk.py --dry-run
```

Host tests:

```zsh
/usr/bin/python3 -m unittest discover -s ops/codex -p test_sm_codex_testdesk.py
```

The owner must install this autonomous job after the ops checkout has the change; agents cannot install it:

```zsh
mkdir -p ~/SpokenMarginsOps/codex-testdesk ~/Library/LaunchAgents
cp ~/SpokenMarginsOps/repo/ops/codex/com.spokenmargins.codex-testdesk.plist ~/Library/LaunchAgents/
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.spokenmargins.codex-testdesk.plist
```

Stop new runs with Codex workers `0` on the Dial. To remove the job:

```zsh
launchctl bootout gui/$(id -u)/com.spokenmargins.codex-testdesk
```
