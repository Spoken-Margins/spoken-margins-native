# Dispatch backstop (#4866)

GitHub drops most `schedule:` ticks on a busy day (2026-11-21, last 24 hours: `claude-audit` 4 of 96, `merge-stall` 3 of
96, `merge-queue-label-bridge` 4 of 96, `lane-conflicts` 3 of 24, `main-t3` 6 of 8). Each of those workflows now starts on
an event where one exists (the comment at the top of each file names which event replaces which cron), and this timer on
the VPS, next to the Dial gate, is the backstop for the time-based part.

Every 15 minutes `sm_dispatch_backstop.py` reads the newest run of each workflow (any event) and fires
`workflow_dispatch` only when that run is older than the workflow's interval less 2 minutes (the timer's own jitter). A run
whose conclusion is `skipped` (every job's `if:` was false, as for a merge group's check or an unarmed PR's push) does not
count, so a busy queue cannot hold the backstop off. For `merge-queue-label-bridge` only a `schedule` or `workflow_dispatch`
run counts: its PR-event runs check one PR, and only the sweep queues a PR armed by a token-made label. The interval is 15 minutes for `claude-audit`,
`merge-stall` and `merge-queue-label-bridge`, 60 for `lane-conflicts`, 180 for `main-t3`. A workflow that an event started
a few minutes ago is skipped.

Each tick logs one line per workflow (`journalctl -u sm-dispatch-backstop`):

```
2026-11-21T23:52:03Z merge-stall.yml dispatched: last run 41m ago (schedule), past 15m
2026-11-21T23:52:03Z claude-audit.yml skipped: last run 6m ago (workflow_run), inside 15m
```

## Deploy

`ops/dispatch-backstop/deploy.sh <ssh-host> --dry-run`, then `--install-only`, then `--enable` (same flow as
`ops/dial/deploy.sh`). The token is read from `/etc/sm-dispatch/github-token`, or from the Dial's
`/etc/sm-dial/github-token` when that file is absent. It must be able to dispatch workflows: fine-grained `actions: write`
on this repository, or a classic token with `workflow` scope. If the Dial's token lacks it, the one step that is not
scriptable is the owner placing a token that has it in `/etc/sm-dispatch/github-token`. Check with
`sudo python3 /opt/sm-dispatch/sm_dispatch_backstop.py --dry-run` (reads only) and then one real tick: a 403 shows as
`FAILED` on the workflow's line.

## Cost and catch

- Cost per tick: five GitHub API reads, and one dispatch call for each workflow that is overdue. No Actions minutes until a
  dispatched job starts, and each of these jobs is a seconds-long Linux job except `main-t3` (a hosted Mac, at most every
  3 hours, and its own `decide` job skips a SHA that already has a status).
- How often: every 15 minutes. At most one dispatch per workflow per interval.
- What it catches: a stall that waits for a dropped cron. Evidence: five "Merging has stalled" issues in three days (#4693,
  #4740, #4758, #4786 and others) and #4666 stuck 37 hours.
- Waste signal: a month in which dispatches start no run that an event had not already started (every line says
  `skipped`), or the log shows `dispatched` lines for a workflow whose events keep it inside its interval.

## Tests

`python3 -m unittest ops/dispatch-backstop/test_sm_dispatch_backstop.py`. The workflow side is held by
`scripts/tests/test_scheduled_workflows.py`.
