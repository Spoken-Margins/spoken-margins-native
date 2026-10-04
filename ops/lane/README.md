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

# Lane power guard

`sm_lane_power_guard.py` stops the lane runners from taking jobs they can't finish (#762).

On battery, or with the lid closed and no external display, the Mac sleeps and wakes for only a few seconds at a time. A runner that picks up a job during one of those wakes falls asleep with it. GitHub cancels the job 10 minutes after it started, with no log, no tidy-up and no lane report. From 2 to 4 October the Mac was unplugged for 42 hours and lost about ten runs this way.

Every 15 seconds the guard checks the power source and the lid:

1. **On power, lid open** (or closed with an external display): it starts the runners it paused. A runner stopped some other way, by hand for a lane freeze or after a session conflict, is left alone.
2. **On battery or lid closed, runner idle:** it stops that runner and notes it in `~/SpokenMarginsOps/lane-power-guard/paused`. Queued jobs wait on GitHub until the Mac is back on power.
3. **On battery or lid closed, job running:** it lets the job finish and holds a `caffeinate` assertion until the job ends. That keeps idle sleep away while the lid is open. Nothing can keep a closed lid awake. When the job ends it checks again at once, so the runner is paused before it takes the next queued job. A job counts as running from the moment the runner's log says it took one, before its worker process starts, so a stop never cancels a job it just missed.

It finds the runners from their launchd plists in `~/Library/LaunchAgents` and logs only changes to `~/SpokenMarginsOps/lane-power-guard/log.txt`.

While the runners are paused, GitHub shows them offline. After 2 hours the lane stall check above says STALL. That's correct: plug the Mac in.

## Check what it would do

```zsh
python3 ~/Documents/GitHub/spoken-margins-native/ops/lane/sm_lane_power_guard.py --dry-run
```

## Install

The PR doesn't install it. After it merges into `next` and the main checkout has it:

```zsh
mkdir -p ~/SpokenMarginsOps/lane-power-guard
```

```zsh
cp ~/Documents/GitHub/spoken-margins-native/ops/lane/com.spokenmargins.lane-power-guard.plist ~/Library/LaunchAgents/
```

```zsh
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.spokenmargins.lane-power-guard.plist
```

To turn it off:

```zsh
launchctl bootout gui/$(id -u)/com.spokenmargins.lane-power-guard
```

```zsh
rm ~/Library/LaunchAgents/com.spokenmargins.lane-power-guard.plist
```

If the guard paused the runners when you turned it off, start them again:

```zsh
launchctl kickstart gui/$(id -u)/actions.runner.uncomposed-spoken-margins-native.sm-lane-mac
```

```zsh
launchctl kickstart gui/$(id -u)/actions.runner.uncomposed-spoken-margins-native.sm-lane-mac-2
```

## Tests

```zsh
python3 -m unittest discover -s ~/Documents/GitHub/spoken-margins-native/ops/lane
```
