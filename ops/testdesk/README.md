# Integration script

`sm_integration_run.py` tests each new tip of `main` with `--plan app` from launchd, with no model session and no owner click (#1178). It replaces the scheduled "SM integration run" task once it has posted a real report.

## What a tick does

launchd starts it every 10 minutes. It stops at the first reason to wait:

1. The tip already has a result here, or any runner's `Lane report integration-<sha7>` is on #184.
2. Memory pressure isn't normal.
3. Free disk is under 10 GB plus 4 GB per running `xcodebuild`.
4. The Mac-wide simulator slot is busy (the lane's own lock, taken without waiting).
5. A `/lane` request of T3 or above is waiting for a lane runner. Those decide what merges, so they go first. This holds only while `main` has had an integration report, or a start here, in the last 3 hours, so a busy lane can't starve it.

There is no fixed spacing: when the lane is quiet, each new tip is tested within about 10 minutes, and tips that land during a run are tested together at the newest one.

Otherwise it tests the tip in its own detached worktree (`~/SpokenMarginsOps/integration-run/worktree`):

- It runs `--plan app`, then re-runs any failing tests twice on the same build. A test that passes in any re-run that completed is reported as `flaky:` (with a note when it failed in the other re-run), and the verdict is PASS. A re-run that never ran a test (the simulator would not boot) counts for nothing either way.
- It keeps the tip's simulator app for desks, pass or fail, when the build of exactly that tip passed `bundle-contracts`: only `SpokenMarginsApp.app` (about 690 MB on 2026-10-18 while Supertonic is still bundled), copied to `~/SpokenMarginsOps/sim-builds/<sha7>/` with a `latest` link, before any culprit search rebuilds older commits. It keeps the newest two and copies nothing under 10 GB free. `scripts/sim-build-latest [--for <sha>]` prints the app and its SHA (`scripts/sim_builds.py`; the journey skill's Setup step 2).
- It runs the scripted journeys, which only change the verdict once one is on `gating`. It counts each script's passing and bad runs in `state.json`, and the report says when one is due to move (`journeys due to move:`); `journey_promotion.py --state ~/SpokenMarginsOps/integration-run/state.json [--apply]` lists or makes the move in `TestPlans/scripted-journeys.json`, for a PR into `main`. The phone-candidate line counts passed, failed, skipped and not-run scripts, and says "passed" only when every listed script passed.
- It frees the simulator, then posts one `Lane report integration-<sha7>` on #184 in test-lane.md's format, with `run by: integration script`. `scripts/phone-build` reads it unchanged.

On a confirmed FAIL it also (owner's "revert first" rule, #1180):

- builds the commits since the last PASS and re-runs only the failing tests, while it still holds the simulator slot. It bisects (about log2 of the number of merges, at most 8 builds), so the culprit is the first commit where the tests fail and the commit before it passes. A test that is missing or a build that stops at some commit gives no answer, and then there is no culprit;
- opens `Revert #N: <title> (integration-<sha7> FAIL)` from branch `revert/pr<N>` with the `automerge` label (plus `hot-file-ok` when the revert makes `Gate1AppModel.swift` or `Gate1RootView.swift` longer, saying why in the PR), and files `Re-land #N after an integration revert` labelled `ready,regression`, with the Claude diagnosis as its prose. It files no separate failure issue then;
- does not revert, and comments on #184 (naming the owner) instead, then files the failure issue as before, when: the revert doesn't apply cleanly or changes nothing; the culprit touches persistence, a migration or a packet format; the culprit touches `.github/` or `scripts/lane*`; the culprit changes only docs, ops, research or scripts outside the app build and its tests (it can't have changed an app test result; #1417); no single culprit is found, or it isn't a merged PR or is itself a revert; another revert PR is open, or `main` already reverts it.

## Hosted integration (#1389)

When the repository variable `LANE_HOSTED_APP` is `on`, `.github/workflows/hosted-integration.yml` runs this script with `--hosted --sha <tip>` on a GitHub-hosted Mac for each push to `main` (newest tip wins; a running test is never cancelled). It runs the same `--plan app`, re-runs and scripted journeys, posts the same report with `run by: hosted integration`, and uploads the logs and manifests (no `.xcresult` bundles) as the run's artifact. It never searches for the culprit, reverts, files issues or calls Claude: a PR opened with the job's token starts no workflows, and there is no Claude token there. The job is red unless the verdict is PASS: an INCONCLUSIVE run, including one that executed 0 tests, fails it after the report is posted (#2590).

While the variable is `on`, the Mac's tick tests no new tip (`hold: hosted integration is on`). It acts only when the newest hosted report is a FAIL it hasn't handled (`hosted_handled` in `state.json`): it re-runs the failing tests at that tip on the Mac, and only if they fail there too does it run the culprit search, revert, diagnosis and issues below. A failure that doesn't reproduce on the Mac gets a note on #184 and nothing else, because the search assumes the tip fails and would otherwise blame the newest merge. Each hosted FAIL is handled once. Reading the variable fails safe: any error counts as off, and the Mac tests as before.

The hosted run zips the tip's simulator app with `ditto` into `artifacts/sim-app/` under the same rule as the Mac (exactly that SHA, `bundle-contracts` passed), and the workflow uploads it as `sim-app-<full sha>` for 2 days. `scripts/sim-build-latest` downloads it with `gh` when no local build matches (`--for <sha>`, or `origin/main`'s tip as last fetched) and keeps it in `~/SpokenMarginsOps/sim-builds` like a local one, marked `built_by: hosted integration`.

Lost while hosted is on: no journey streaks toward gating (`journey_promotion.py` reads only the Mac's `state.json`), and no catch-ledger rows for hosted tips.

The diagnosis is `claude -p` with only Read, Grep and Glob, `--permission-mode dontAsk`, structured JSON output and a $10 cap. Anything else is refused at once rather than waiting for a click. A missing token or a bad answer gives template text instead. A tip is tested at most once: a run cut off part-way is closed as INCONCLUSIVE, not repeated.

State and log: `~/SpokenMarginsOps/integration-run/`. Evidence: `artifacts/integration-run/` in the ops checkout; the newest 20 runs are kept, and a PASS run's `.xcresult` bundles are deleted.

```zsh
/usr/bin/python3 ops/testdesk/sm_integration_run.py --dry-run
```

prints today's decision and changes nothing.

## Claude token

The diagnosis reads a long-lived token from the login Keychain (service `claude-code-oauth`), made once with `claude setup-token`. It is passed only in the child's environment, never on a command line or in a file.

## Install (owner's call)

The job runs from the `~/SpokenMarginsOps/repo` checkout, which the phone-build job keeps on `main`. After this merges and that checkout has the folder:

```zsh
mkdir -p ~/SpokenMarginsOps/integration-run
```

```zsh
/usr/bin/python3 ~/SpokenMarginsOps/repo/ops/install-launchd.py --install integration-run
```

The first tick runs at load. Watch `~/SpokenMarginsOps/integration-run/log.txt` and #184. Once it has posted a report, switch off the "SM integration run" scheduled task. To stop the job:

```zsh
launchctl bootout gui/$(id -u)/com.spokenmargins.integration-run
```
