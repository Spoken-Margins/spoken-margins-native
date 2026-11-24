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

**Fixed daily slots (#5154).** `phone-build` (12:00 and 21:30 UTC) has no interval: it must run near a time of day. It and
`main-t3`'s two pre-phone-build ticks (13:30 and 22:30 UTC) are listed in `SLOTS`. Each tick finds the newest slot that is
more than an hour past and dispatches when no run was created from 30 minutes before that slot onwards. On 2026-11-23 the
12:00 phone build never ran and the 21:30 one started 1h48m late; replayed against the real run list, the backstop would
have dispatched it at 13:00. `main-t3` dispatches when either its 3-hour interval or a slot says so, once. Both workflows
skip a commit they already handled (`main-t3` by its commit status, `phone-build` by an unexpired build), so a dispatch that
finds nothing new costs one short Linux job.

Each tick logs one line per workflow (`journalctl -u sm-dispatch-backstop`):

```
2026-11-21T23:52:03Z merge-stall.yml dispatched: last run 41m ago (schedule), past 15m
2026-11-21T23:52:03Z claude-audit.yml skipped: last run 6m ago (workflow_run), inside 15m
```

## Deploy

`ops/dispatch-backstop/deploy.sh <ssh-host> --dry-run`, then `--install-only`, then `--enable` (same flow as
`ops/dial/deploy.sh`). The tokens are read from `/etc/sm-dispatch/github-token` and the Dial's
`/etc/sm-dial/github-token`, and when GitHub refuses one (401 or 403) the next is tried (#4937). One of them must be able
to dispatch workflows: fine-grained `actions: write` on this repository, or a classic token with `workflow` scope. If
neither can, the one step that is not scriptable is the owner placing a token that can in `/etc/sm-dispatch/github-token`.
Check with `sudo python3 /opt/sm-dispatch/sm_dispatch_backstop.py --dry-run` (reads only) and then one real tick: a refusal
shows as `FAILED: HTTP 403 <GitHub's message>: the token needs ...` on the workflow's line.

Nobody reads journald. The coordinator's wake sweep (`scripts/sm_sweep.py`, rule 15) reports any of these workflows with
no run for twice its interval, so a backstop that has stopped, lost its token or never been enabled shows up within an
hour (#4937). A run still queued or running is not dispatched over.

## Cost and catch

- Cost per tick: seven GitHub API reads (one per workflow), and one dispatch call for each workflow that is overdue. No Actions minutes until a
  dispatched job starts, and each of these jobs is a seconds-long Linux job except `main-t3` (a hosted Mac, at most every
  3 hours, and its own `decide` job skips a SHA that already has a status).
- How often: every 15 minutes. At most one dispatch per workflow per interval. For a slot, at most one dispatch per missed slot (the dispatched run covers it).
- What it catches: a missed or hours-late phone build (#5154: no 12:00 run on 2026-11-23, 21:30 runs 1h48m to 4h late on
  2026-11-21 to 23). A stall that waits for a dropped cron. Evidence: five "Merging has stalled" issues in three days (#4693,
  #4740, #4758, #4786 and others) and #4666 stuck 37 hours.
- Waste signal: a month in which dispatches start no run that an event had not already started (every line says
  `skipped`), or the log shows `dispatched` lines for a workflow whose events keep it inside its interval.

## Tests

`python3 -m unittest ops/dispatch-backstop/test_sm_dispatch_backstop.py`. The workflow side is held by
`scripts/tests/test_scheduled_workflows.py`.
