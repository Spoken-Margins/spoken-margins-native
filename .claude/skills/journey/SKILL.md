---
name: journey
description: How the Spoken Margins Test Desk runs a journey from docs/journeys.md (or a one-off scenario from a lane request) on a simulator with real taps and screenshots, and reports it on the PR. Use only in the Test Desk session (started with SM_LANE_ROLE=test-desk) when handling a T4 or T5 lane request.
---

# Running a journey for a lane request

The journeys themselves are in [docs/journeys.md](../../../docs/journeys.md), and the report format is in [docs/workstreams/test-lane.md](../../../docs/workstreams/test-lane.md). Read both before the first run in a session.

## Who can do this

Only the Test Desk: a Claude Code session started from a terminal with `SM_LANE_ROLE=test-desk claude`. The lane guard hook in `~/.claude/settings.json` blocks simulator commands in every other session. If a simulator command is blocked here, this session wasn't started as the Test Desk. Stop and say so; don't try to get around it.

## Setup for one request

1. **Worktree at the requested commit.** Never test in a stream's worktree or the owner's checkout:
   `git worktree add --detach .claude/worktrees/lane-<id> <sha>`
2. **Build** there with the wrapper, which queues for a Mac-wide build slot and uses `.build/dd` in that worktree:
   `scripts/xcodebuild-lane -project SpokenMarginsNative.xcodeproj -scheme SpokenMarginsApp -destination 'generic/platform=iOS Simulator' build`
   The app is then at `.build/dd/Build/Products/Debug-iphonesimulator/SpokenMarginsApp.app`.
3. **Simulator.** Use the Test Desk's own device. Never use the owner's journey simulator, and never `SpokenMargins Test Runner`, which `--plan app` erases. At most two simulators may run on the Mac at once, so check `xcrun simctl list devices booted` first.
4. **Install over the existing app, and don't erase it.** Journeys need a Library with history (docs/journeys.md). Erase only if the request asks for a fresh install.
5. Evidence goes in `artifacts/lane/<id>/` in the main checkout. It is git-ignored, so the PR gets paths, not images.

## Driving

- Drive with computer use: real taps and screenshots. Claude Desktop's simulator pane doesn't support Xcode 27 yet. Don't inject state or use test-only launch arguments.
- Follow docs/journeys.md step by step. After each step, record what the screen shows, which item or Margin is playing, and whether its clock advanced.
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
