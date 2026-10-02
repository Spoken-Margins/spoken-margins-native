# Codex worker

A Mac-side worker that takes `ready` issues with Codex (`gpt-6.1-sol`, reasoning effort `high`) and opens `automerge` PRs into `next`, paced by the Dial (#589), so spare Codex allowance gets used. Nothing here is installed by default.

## What it does

launchd runs `sm_codex_worker.py` every 10 minutes. Each run (a tick) reads:

1. The Dial's `**Codex workers**` group (0 to 3). No group, no tick, or Mode Off means 0. Two ticks take the lower.
2. Codex usage (`codex app-server`, `account/rateLimits/read`). It holds at the Codex stop line minus 3, or when usage is more than 5 points ahead of a straight line from the Codex window's start to its finish-by time, scaled to the stop line. With no Codex pacing ticks, it uses the Dial's Stop line and Codex's reset. It also holds when the read fails or no readable stop line is ticked.
3. Free disk. It holds below 30 GiB.
4. Live slots: `~/SpokenMarginsOps/codex-worker/slot-N.lock` files whose pid is still a worker.

If a slot is free and nothing holds, it picks one issue and starts one detached child, then exits. It starts at most one child per tick.

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

Run a dry run. It prints the Dial read, Codex usage, slots and the issue it would pick, and changes nothing:

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
- PRs that need a simulator test get no `/lane T3` request from the worker. The prompt keeps Codex to host-testable work, and the runner's own tier rules still apply.

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
