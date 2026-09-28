---
name: journey
description: How the Spoken Margins Test Desk runs a journey from docs/journeys.md (or a one-off scenario from a lane request) on a simulator with real taps and screenshots, and reports it on the PR. Use only in the Test Desk session (opened on the spoken-margins-native-test-desk folder) when handling a T4 or T5 lane request.
---

# Running a journey for a lane request

The journeys themselves are in [docs/journeys.md](../../../docs/journeys.md), and the report format is in [docs/workstreams/test-lane.md](../../../docs/workstreams/test-lane.md). Read both before the first run in a session.

## Who can do this

Only the Test Desk: a Claude Code session opened on the `spoken-margins-native-test-desk` folder, the worktree next to the main checkout (in the desktop app, or a terminal `claude` started there), or a terminal session started with `SM_LANE_ROLE=test-desk`. The lane guard hook in `~/.claude/settings.json` blocks simulator commands in every other session, and `cd` into that folder doesn't count. If a simulator command is blocked here, this session wasn't opened as the Test Desk. Stop and say so; don't try to get around it.

That worktree is the desk's home, not a test subject: keep it detached at `origin/next` (`git fetch` then `git checkout --detach origin/next` there) and test each request in its own worktree.

## Setup for one request

The Test Desk takes **T4 and T5** requests. T2 and T3 go to the self-hosted runner (`.github/workflows/lane.yml`), so skip those even when they carry `lane:queued`.


1. **Worktree at the requested commit.** Never test in a stream's worktree or the owner's checkout:
   `git worktree add --detach .claude/worktrees/lane-<id> <sha>`
2. **Build** there with the wrapper, which queues for a Mac-wide build slot and uses `.build/dd` in that worktree:
   `scripts/xcodebuild-lane -project SpokenMarginsNative.xcodeproj -scheme SpokenMarginsApp -destination 'generic/platform=iOS Simulator' build`
   The app is then at `.build/dd/Build/Products/Debug-iphonesimulator/SpokenMarginsApp.app`.
3. **Simulator.** Journeys run on the lane's standing simulator, on **iOS 26.5**. That is the same device the Test Desk uses for its own T3 runs. Don't use iOS 27: its Apple Intelligence services crash-flood on this Mac (#184).
   - A second device, when a journey needs one (J5), is a temporary simulator created for the job and deleted afterwards. Never create another long-lived simulator; that's the owner's disk rule.
   - The lane runner's T3 jobs use their own temporary simulator (named `SM Lane Runner …`), so at most two lane simulators run at once. Before booting a second device, run `xcrun simctl list devices booted`, and wait if two are already booted.
   - **Boot only with `scripts/lane-sim-boot <udid>`.** It waits for the Mac-wide simulator-boot lock, which the runner and `verify-tests.py` also hold while they boot. Two simulators booting at once crash-flooded SpringBoard onto the owner's screen (#184). It then waits until the device is ready; a first boot migrates data for several minutes.
   - Never let `xcodebuild` or `verify-tests.py --device` start from a shut-down device you haven't booted this way: boot it first. The guard sends a raw `simctl boot` to the helper.
4. **Install the build.** `--plan app` wipes the app's data on the standing device, so a lane journey starts from an empty Library and builds the history it needs within the job (J2, J3 and J5 do this). J4 installs the previous shipped build first. Journeys over real long-lived history belong to the owner's device pass.
5. Evidence goes in `artifacts/lane/<id>/` in the main checkout. It is git-ignored, so the PR gets paths, not images.

## Driving

- Drive with computer use: real taps and screenshots. Claude Desktop's simulator pane doesn't support Xcode 27 yet. Don't inject state or use test-only launch arguments.
- Follow docs/journeys.md step by step. After each step, record what the screen shows, which item or Margin is playing, and whether its clock advanced.
- **After each step, check for new crash reports**, so a flood is caught at its first step: `find ~/Library/Logs/DiagnosticReports -name '*.ips' -newer <marker file touched before the step>`. Record any you find.
- **Stop at the first failure.** Record the step, the expected and the observed behavior, and a screenshot path.
- You can't hear audio. A moving clock shows the app thinks it's playing. Mark audible content "owner to confirm".

Simulator pitfalls (from docs/journeys.md, which wins if they differ):

- After typing, take a screenshot and confirm the whole value arrived before tapping submit. Keystrokes and taps travel separately, and a truncated URL looks like a 404 or `-1011`, not a real bug.
- The app's Paste button doesn't see `xcrun simctl pbcopy`. Type values instead.
- Keyboard tips can swallow the next tap. Take a screenshot before tapping near the bottom of the screen.
- A cold Debug launch can be blank for about 5 s. Wait before the first tap.

## Crash flood

If one process crashes three or more times within a minute:

1. Stop.
2. `xcrun simctl shutdown <udid>`.
3. Report INCONCLUSIVE with the crash names, and notify the owner.

Don't reboot in a loop or switch devices. A single crash is noted in the report and the run continues.

## Report and clean up

1. Post the report on the PR in the test-lane.md format (PASS / FAIL / INCONCLUSIVE, per-step observations, evidence paths, crashes, what's not verified), then change the label from `lane:queued` to `lane:done`.
2. Shut down any simulator you booted.
3. Remove the worktree with `git worktree remove .claude/worktrees/lane-<id>`, which also deletes its DerivedData. Disk space on this Mac is tight.
