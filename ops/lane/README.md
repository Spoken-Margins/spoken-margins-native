# Lane stall check

`sm_lane_stall.py` notices a lane runner that has gone quiet. A change to the lane can stop the self-hosted runner from starting at all. A stopped runner posts no lane reports, so a guard that counts runner-fault reports (the planned auto-revert, #640) never fires.

This check looks from the outside. It reads two facts with `gh`:

1. When the newest "Lane report" comment appeared on any issue or PR. It reads only the newest comments (the last 24 hours, newest first) and stops at the first report.
2. How many runs of `.github/workflows/lane.yml` are queued, pending or in progress.

It prints one line:

- `OK: …` and exits 0 when no lane jobs are waiting, or a report appeared within the last 2 hours.
- `STALL: no lane report for Xh Ym while N lane jobs are queued (newest report: <url>)` and exits 1 when jobs are waiting and no report has appeared for 2 hours or more.
- `ERROR: …` and exits 2 when GitHub couldn't be read. That is not an OK.

It is read-only: it never comments, labels, or touches a run.

## Run it

```zsh
python3 ~/Documents/GitHub/spoken-margins-native/ops/lane/sm_lane_stall.py
```

Change the limit with `--hours 3`. `--lookback-hours` (default 24) sets how far back it looks for a report.

## Known limit

One T3 can run for up to four hours. If the queue holds only that one run and no other PR reports in the meantime, the check can say STALL while the runner is fine. With several PRs reporting each hour this is rare. A STALL line means "look at the runner", not "revert".

## Text for the Mac tick

Paste this into `~/.claude/scheduled-tasks/sm-mac-tick/SKILL.md`, right after step 2 (SIGNALS) and before step 2b:

```text
2a. LANE STALL. Run `cd ~/Documents/GitHub/spoken-margins-native && python3 ops/lane/sm_lane_stall.py` and keep its one line. If it starts with STALL or ERROR, put that line, in bold, as the first line of this tick's #337 comment, above the time heading, and add after it: "Check the runner: `gh run list --workflow lane.yml --limit 5` and the newest lane change merged into next." Don't revert anything, comment /lane, or touch labels yourself. If it says OK, add nothing. It only reads GitHub, so a failure to run it is an ERROR line, never a reason to skip the rest of the tick.
```

## Tests

```zsh
python3 -m unittest discover -s ~/Documents/GitHub/spoken-margins-native/ops/lane
```

`scripts/verify-tests.py --plan fast` runs them too, as the `ops-lane` step.
