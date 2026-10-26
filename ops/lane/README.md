# Lane open ping

`sm_lane_open.py` wakes the coordinator when a Mac lane runner is left idle (#1215). The coordinator acts only when something wakes it, and nothing told it when a lane slot freed up, so armed PRs, stale "waiting on you" items and idle threads sat until some other wake.

Two last jobs of `.github/workflows/lane.yml`, `lane-open-lane` and `lane-open-automerge`, each run after its Mac job (so the notice comes when either one frees its runner), on the VPS runner (never a Mac runner). It takes `sm_lane_open.py` from the base branch's tip and reads two facts from GitHub:

1. Which online runners labelled `sm-lane`, `sm-lane-build` or `sm-lane-priority` are idle.
2. Which jobs of any workflow's active runs are queued for a runner and ask for a lane label. That includes `compat` in `shipped-build-compat.yml`, which uses the main runner. Each takes one idle runner that has all its labels. A job that waits on its PR's own concurrency group (`pending`) is not counted.

If an idle runner is left over, it POSTs `Lane open-<UTC time>: <free> free, <queued> queued` to the Dial relay routine, which posts it into the project chat like a Dial fire. At most one ping goes out per 10 minutes (`~/.sm-lane-open/state.json` on the VPS runner's user), so a burst of finishes is one message. If the runner still reads busy for a moment after its job ended, it re-reads up to three times, 5 seconds apart.

It fails toward quiet and never turns a lane run red: no relay secrets, an unreadable runner list or queue, more than one page of runners or runs, or a failed POST sends nothing. The step has `continue-on-error`, and the Mac jobs don't wait for it.

What a ping means: a runner is idle. It does not mean RAM, disk or the Mac's one simulator slot are free, so a T3 may still wait. A lane that sits idle with nothing finishing sends no further ping; the Dial and the dispatch still cover that.

## Turn it on (once, by the owner)

The job runs on merge but sends nothing until two repo secrets exist. They are the Dial relay's own URL and token, piped from the VPS so neither is shown or typed (replace `<vps>` with the SSH host that runs the Dial gate):

```zsh
ssh <vps> 'cat /etc/sm-dial/relay-url' | gh secret set SM_LANE_OPEN_URL -R Spoken-Margins/spoken-margins-native
```

```zsh
ssh <vps> 'cat /etc/sm-dial/relay-token' | gh secret set SM_LANE_OPEN_TOKEN -R Spoken-Margins/spoken-margins-native
```

Turn it off by deleting either secret; remove it by deleting the two `lane-open-*` jobs. Any lane job on a PR can read these secrets (as it can `SM_LANE_RUNNERS_TOKEN`); the token can only post text into the project chat.

## Check what it would do

```zsh
GH_REPO=Spoken-Margins/spoken-margins-native RUNNERS_TOKEN=$(gh auth token) SM_LANE_OPEN_URL=x SM_LANE_OPEN_TOKEN=x python3 ops/lane/sm_lane_open.py --dry-run
```

It prints the decision and sends and writes nothing.

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

### Simulator-tool preflight (#2591)

On 2026-10-24 an overnight Xcode update left CoreSimulator older than Xcode expected, so every `xcrun simctl` call waited on an admin-password prompt, and the tick's own `simctl list devices booted` hung. `scripts/simctl_preflight.py` reads the two versions the `simctl` wrapper compares and answers at once. `lane_sim.py` and the integration run already call it. For the tick, replace the simulator-slot check in step 2 (SIGNALS) with this:

```text
   - Simulator slot: first run `cd ~/Documents/GitHub/spoken-margins-native && python3 scripts/simctl_preflight.py`. If it prints anything but a line starting with OK, put that line, in bold, as the first line of this tick's #337 comment, skip every `simctl` command this tick, and report the slot from a running Simulator process instead. If it prints OK, check whether any simulator is booted, and its name (a read-only check the lane guard allows, such as `xcrun simctl list devices booted`; if that is blocked, look for a running Simulator process). Don't run `scripts/lane-sim-boot`;
```

### Owner-tap alert backstop (#2047)

`scripts/owner_tap_alert.py` pushes the owner's phone (a `github-actions[bot]` comment that @mentions him) when a PR only he can merge is ready for his tap. It runs in the last job of `hosted-portable.yml` (`linux-t1.yml` until #2442) and `shipped-build-compat.yml`, so it decides as a PR's checks finish. It also needs the `workflow files parse` check (the workflow guard tests) green on the head and run as a `pull_request` run that merged with a base that has not since changed `.github/workflows/` or the guard test (compared by what those paths hold at the tested commit and now); a push to the trunk touching those re-runs the sweep from `owner-tap-alert.yml`, so a PR that went stale loses `needs-owner-tap` and gets one warning (#2714). The audit script asks for a check after auditing such a PR, by re-adding the `owner-tap-check` label, whose labeled run in `owner-tap-alert.yml` posts as the bot. A lane run that finishes last starts nothing, so this tick step is an optional backstop. On the Mac, `gh` is the owner, whose comment would notify nobody, so the step only re-adds the label on PRs that are ready and not yet alerted. To add it, paste this after step 2a:

```text
2c. OWNER-TAP ALERT. Run `cd ~/Documents/GitHub/spoken-margins-native && GH_REPO=Spoken-Margins/spoken-margins-native python3 scripts/owner_tap_alert.py --via-label owner-tap-check` and keep going. For each PR ready for the owner's merge tap and not yet alerted on its head, it re-adds the `owner-tap-check` label, and GitHub Actions posts the alert. Running it every tick never repeats an alert. If it prints "skipped", note that line in this tick's #337 comment.
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

1. **On power, lid open** (or closed with an external display), **or an Amphetamine session holds the Mac awake** (above 10% battery, and with lid-closed running on if the lid is shut; see `ops/power/README.md`): it starts the runners it paused. A runner stopped some other way, by hand for a lane freeze or after a session conflict, is left alone.
2. **Otherwise, on battery or lid closed, runner idle:** it stops that runner and notes it in `~/SpokenMarginsOps/lane-power-guard/paused`. Queued jobs wait on GitHub until the Mac is back on power.
3. **Otherwise, on battery or lid closed, job running:** it lets the job finish and holds a `caffeinate` assertion until the job ends. That keeps idle sleep away while the lid is open; `caffeinate` can't keep a closed lid awake. When the job ends it checks again at once, so the runner is paused before it takes the next queued job. A job counts as running from the moment the runner's log says it took one, before its worker process starts, so a stop never cancels a job it just missed.

It asks Amphetamine only when the power and lid alone say no, and never opens it. macOS still reports that closing the lid causes sleep while Amphetamine holds it, so the guard asks Amphetamine instead of trusting that reading. The first time, macOS asks whether `python3` may control Amphetamine; choose **Allow**.

It finds the runners from their launchd plists in `~/Library/LaunchAgents` and logs only changes to `~/SpokenMarginsOps/lane-power-guard/log.txt`. Only one guard acts at a time (a lock in the same folder). A runner it fails to restart stays marked paused, so the next check tries again. Just before pausing a runner, it looks once more, and leaves it running if it has taken a job.

While the runners are paused, GitHub shows them offline. After 2 hours the lane stall check above says STALL. That's correct: plug the Mac in.

## Check what it would do

```zsh
python3 ~/Documents/GitHub/spoken-margins-native/ops/lane/sm_lane_power_guard.py --dry-run
```

## Install

The PR doesn't install it. After it merges into `main` and the main checkout has it:

```zsh
mkdir -p ~/SpokenMarginsOps/lane-power-guard
```

```zsh
/usr/bin/python3 ~/Documents/GitHub/spoken-margins-native/ops/install-launchd.py --install lane-power-guard
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

# Lane tools refresh

`sm_lane_tools_refresh.py` keeps the lane's tools copy on `main` (#2536). The runners take `.venv` and `node_modules` from that copy (`SM_LANE_TOOLS`, default `~/Library/Caches/SpokenMarginsLane/tools`) because macOS denies their `node` access to `~/Documents` (#2493). Lane scripts come from each PR's own checkout, so the copy only has to supply the two install folders; they go stale when `requirements-dev.txt` or `package-lock.json` changes.

Hourly (launchd label `com.spokenmargins.lane-tools-refresh`, run from the copy itself so it never reads `~/Documents`) it:

1. fetches `main` at depth 1 and resets the copy to it (the copy is a throwaway clone; nobody edits it);
2. runs `scripts/bootstrap-python-tools.sh` if `requirements-dev.txt` differs from the copy in `.venv/.requirements-dev.txt`, and `npm ci` if `package-lock.json` differs from the stamp `node_modules/.sm-package-lock.sha256`. Installs wait while a `lane-runner.py` process runs, so a test never sees a half-installed `.venv`;
3. checks that `.venv/pyvenv.cfg` and the two folders do not point into `~/Documents`;
4. comments on #337, at most once a day per problem, when a fetch, install or check fails, or when a needed install has waited more than 6 hours.

Run it by hand: `python3 ~/Library/Caches/SpokenMarginsLane/tools/ops/lane/sm_lane_tools_refresh.py --no-post`. Install: `python3 ops/install-launchd.py --install lane-tools-refresh` (not installed by the PR). Tests: `python3 -m unittest ops/lane/test_sm_lane_tools_refresh.py`.

**Cost and catch.** One `git fetch --depth 1` an hour (a few KB when nothing changed), no tokens, no owner clicks; an install only when inputs changed. It catches the 2026-10-23 situation: the copy built for #2493 sat at `0a9743f` while `main` moved, and a changed requirement or lockfile would have failed host tests on the Mac only. Waste signal: it logs "tools copy is current" for weeks while neither input file changes in `main`; then drop it to daily.
