---
name: journey
description: How the Spoken Margins Test Desk runs a journey from docs/journeys.md (or a one-off scenario from a lane request) on a simulator with real taps and screenshots, and reports it on the PR. Use only in the Test Desk session (opened on the spoken-margins-native-test-desk folder) when handling a T4 or T5 lane request.
---

# Running a journey for a lane request

The journeys themselves are in [docs/journeys.md](../../../docs/journeys.md), and the report format is in [docs/workstreams/test-lane.md](../../../docs/workstreams/test-lane.md). Read both before the first run in a session.

## Who can do this

Only the Test Desk: a Claude Code session opened on the `spoken-margins-native-test-desk` folder, the worktree next to the main checkout (in the desktop app, or a terminal `claude` started there), or a terminal session started with `SM_LANE_ROLE=test-desk`. The lane guard hook in `~/.claude/settings.json` blocks simulator commands in every other session, and `cd` into that folder doesn't count. If a simulator command is blocked here, this session wasn't opened as the Test Desk. Stop and say so; don't try to get around it.

That worktree is the desk's home, not a test subject: keep it detached at `origin/main` (`git fetch` then `git checkout --detach origin/main` there) and test each request in its own worktree.

## Setup for one request

The Test Desk takes **T4 and T5** requests. T2 and T3 go to the self-hosted runner (`.github/workflows/lane.yml`), so skip those even when they carry `lane:queued`.


1. **Worktree at the requested commit.** Never test in a stream's worktree or the owner's checkout:
   `git worktree add --detach .claude/worktrees/lane-<id> <sha>`
2. **Install a ready-made build when there is one; build only when there isn't.** The integration run keeps a Debug simulator build of each tip it tests, so most desk starts need no build. When it runs on a GitHub-hosted Mac (`LANE_HOSTED_APP`), `scripts/sim-build-latest` downloads that run's build with `gh` (about 290 MB, a minute or two) the first time and says so on stderr; `--no-download` skips that:
   - **A request pinned to a commit** (a PR head, a named SHA): `scripts/sim-build-latest --for <sha>`. It prints the app path, then the SHA, and exits 1 when there is no build of exactly that commit; then build.
   - **A check of the base branch's tip** (no commit named, or "test main"): `scripts/sim-build-latest`. It also says on stderr how many commits it is behind `origin/main` as last fetched, so `git fetch origin` first. Behind 0: use it. Behind more: run `git diff --stat <its sha> origin/main -- App Packages project.yml Contracts`; if nothing the request checks changed, use it. Either way, name the SHA you installed in the report.
   - **Otherwise, build** in the worktree with the wrapper. It queues for a Mac-wide build slot and uses `.build/dd` there:
     `scripts/xcodebuild-lane -project SpokenMarginsNative.xcodeproj -scheme SpokenMarginsApp -destination 'generic/platform=iOS Simulator' build`
     The app is then at `.build/dd/Build/Products/Debug-iphonesimulator/SpokenMarginsApp.app`.
   - The kept build is the same app target in Debug, with the app-hosted test bundle in its `PlugIns` folder. It installs with `xcrun simctl install <udid> <app path>`. Don't delete or edit it: other desks share it, and the integration run replaces it. Without a build here, the worktree in step 1 is still where you read the journey docs and the code.
3. **Simulator: a pool device, erased for every request.**

   ```bash
   UDID=$(scripts/lane-sim-boot --pool)
   ```

   This takes the least recently used free device from the desk pool (up to three iPhone 17s on iOS 26.5 named `SM Lane Desk pool N`), erases it and boots it under the lane's boot rules. It returns once the device is ready; the first boot after an erase migrates data for 3–6 minutes. The owner approves each pool device once in the simulator panel and the approval survives an erase, so reusing devices spares them a click per run (#688). It creates a device only when none is free and the pool has room: say so on #184, because the owner has to approve that one the first time you drive it. Two SpringBoard crash floods came from retrying a boot that had failed on the same device (#184), and iOS 27's Apple Intelligence services crash-flood on this Mac; a device that fails or crashes is retired, never reused (see below). The old standing device 1330F268 stays retired.
   - **At most two simulator jobs on this Mac, the second only while memory pressure is normal.** The helper first takes a Mac-wide simulator slot. If the runner's T3 or another job already has a simulator, it joins only while pressure is normal and the second slot is on (`scripts/lane-sim-boot --second-slot status`); otherwise it waits. The device's watcher then holds the slot until `--done`. Two simulators plus builds once pushed this 16 GB Mac's load to about 690 and filled swap (#184). While any slot is held, builds get one slot instead of two, so **always finish with `--done`**.
   - The boot rules (`scripts/lane_sim.py`) are shared with the runner and `verify-tests.py`: one boot at a time, no builds while a simulator boots, no retry, and a crash watch.
   - **If the helper prints `STOP`, stop.** A failed boot or a crash during boot shuts the device down and marks it unsafe. Don't retry it, and don't boot it any other way; the guard blocks every command that names it except delete and shutdown. The pool retires it for you: the next `--pool` deletes it, drops it from the pool and creates a replacement when no other device is free (the guard blocks `scripts/lane-sim-boot --done` on a device marked unsafe, so don't run it). Report on #184 before taking another device if it happens twice. If the watcher marks a device unsafe after the boot (a late crash report), the device keeps running and keeps its simulator slot, and the next `--pool` would wait for that slot: run `xcrun simctl shutdown <udid>` (the guard allows it), wait until the watcher has exited (`ps -p $(cat ~/Library/Caches/SpokenMarginsLane/watch-<udid>.pid)` lists no process; the file stays behind after the watcher exits, so don't wait for it to disappear), and the next `--pool` deletes the device. A device that merely fails to erase stays in the pool and is passed over; a `STOP` that says `simctl erase failed` means no pool device would erase, so report that too.
   - J5 needs two devices. Run them one after the other, so the second slot stays free for the runner: run the sender, keep its packet, `--done` it, then take the recipient's device; or mark J5 for the owner's device pass.
   - Only run `xcodebuild` or `verify-tests.py --device` against a device the helper booted. The guard sends a raw `simctl boot` to the helper.
   - After the boot, a background watcher checks the device's SpringBoard process every second. At the first SpringBoard crash it shuts the device down and marks it unsafe. Crash report files arrive about 80 s late, so they can't catch a flood in time. **If the device shuts down on its own, stop and report**; its reason is in `~/Library/Caches/SpokenMarginsLane/watch-<udid>.log`.
   - When the request is done: `scripts/lane-sim-boot --done "$UDID"`, once. It stops the watcher first, so the shutdown isn't counted as a crash, then shuts the device down, erases it and keeps it in the pool (a device marked unsafe is deleted instead).
4. **Install the build.** An erased device starts with an empty Library, so a lane journey builds the history it needs within the job (J2, J3 and J5 do this). J4 installs the previous shipped build first. Journeys over real long-lived history belong to the owner's device pass.
5. Evidence goes in `artifacts/lane/<id>/` in the main checkout. It is git-ignored, so the PR gets paths, not images.

## Driving: the desk leads, one helper agent per journey

The desk session stays a lean lead. It finds the build, holds the device and writes the report; each journey is driven by a helper agent (the Agent tool) in a context of its own. Why: on 2026-10-16 the Build 34 baseline desk reached the 250k-token line after two steps of J1 plus the scripted journeys (#184). Every screenshot (about 2.5k tokens at full size) stays in the context that took it and is read again on every later turn, so one long run of journeys in one context costs far more than the same screenshots spread over short ones. The lead keeps only each helper's short answer. The target is about 10 journeys per desk session.

**The simulator tool, never computer use or Device Hub.** Lead and helpers drive the simulator with the iOS simulator tool (`mcp__Claude_Code_iOS_Simulator__control`), passing the pool device's UDID as `device`. Never use computer use for the simulator, and never open Device Hub or Simulator.app: on 2026-10-16 opening Device Hub booted a pool device outside the lane (no watcher, no slot), held up `--pool` for about 15 minutes, and quitting it shut down another pool device. Don't inject state or use test-only launch arguments in an agent-driven journey.

**Unattended desks drive through AXe instead of the panel.** The simulator panel detaches on every boot, and only the owner can re-attach it, so a desk that runs while he is away can't use the simulator tool across a reboot or a crash (2026-10-18, #184). AXe (`axe`, MIT, installed at `~/.local/bin/axe`) taps, types and swipes through the simulator's own input and accessibility layer. It needs no panel, no macOS permission and no approval per device or per boot: checked on 2026-10-18 on a pool device, before and after a `--done` and a fresh `--pool`. It is a plain shell command, so the lane guard lets it through; boots still go through `scripts/lane-sim-boot`. A helper driving with AXe uses Bash instead of the simulator tool, under the same rules.
- Read the screen with `scripts/ax-look <udid>`: one line per control with its centre point, role, label, value and identifier, about 4k characters a screen. `axe describe-ui` alone prints about 500k. The OCR reader `artifacts/desk-operator/look`, if present, is smaller (about 1k) and shows only what is visible.
- Tap with `axe tap --id <identifier> --tap-style physical --udid <udid>`, or `--label '<label>'`, or `-x <x> -y <y>` from ax-look. **Always pass `--tap-style physical`**: the default style reports success and does nothing in this app.
- Type with `axe type '<text>' --udid <udid>` after tapping the field. Scroll with `axe swipe --start-x 200 --start-y 750 --end-x 200 --end-y 250 --duration 0.3 --udid <udid>`.
- Confirm every step by reading the screen again. AXe confirms only that the touch was sent.
- Pitfalls are in docs/journeys.md under "Driving with AXe".

**What the lead does**

1. **Build once, if at all.** Use the ready-made build from Setup step 2 when it fits. Else reuse a kept desk build of the same commit: a `.claude/worktrees/lane-*` worktree whose `git -C <worktree> rev-parse HEAD` is the commit and which holds `.build/dd*/Build/Products/Debug-iphonesimulator/SpokenMarginsApp.app`. Otherwise build as in Setup step 2.
2. **Take the device and install once** (Setup steps 3 and 4). Only the lead runs `scripts/lane-sim-boot`, installs and gives the device back; helpers never boot, erase, install or `--done`.
3. **Hand out journeys one at a time.** One helper per journey, in order, with `run_in_background: false`: there is one device, so two helpers never drive it at once. Journeys share the install, so J2, J3 and J5 build their history as they go; when a journey needs a clean start, the lead reinstalls between helpers. Use the brief below.
4. **After each helper:** note its verdict, its screenshot path and its `subagent_tokens` (the Agent tool's usage line), and run one crash check. A FAIL stops that journey, not the batch: go on to the next journey unless the app no longer launches or a crash flood stopped the run.
5. **If a helper reports its simulator call was blocked by the lane guard**, drive that journey yourself under the same screenshot budget, and say so on #184. (Checked 2026-10-16: helpers see the simulator tool, and the guard trusts them through the session's `CLAUDE_PROJECT_DIR`, which a helper shares with the desk. Its fallback, the transcript folder, would not match a helper's `…/subagents/` transcript, so a desk without `CLAUDE_PROJECT_DIR` would be blocked; widening that is the owner's call, in `scripts/lane_guard.py`.)

**Brief for a helper** (fill in the angle brackets; paste the journey's steps from docs/journeys.md, or the request's numbered `scenario:`):

```text
You are a Test Desk helper for Spoken Margins. Drive one journey on one simulator and report.
Device UDID: <udid> (already booted, app installed: <app path>). Evidence folder: <artifacts/lane/<id>/<journey>/>.
Use only mcp__Claude_Code_iOS_Simulator__control with device=<udid>, plus Bash for the crash check.
(Unattended desk: instead use Bash with axe and scripts/ax-look <udid>, always with --tap-style physical.)
Never use computer use, Device Hub or Simulator.app; never boot, erase, install, shut down or
run scripts/lane-sim-boot. If a simulator call is blocked, stop and say "blocked by the lane guard".
Rules: .claude/skills/journey/SKILL.md, "Screenshot budget" and "Simulator pitfalls".
Crash check after each step: find ~/Library/Logs/DiagnosticReports -name '*.ips' -newer <marker>.
Stop at the first failed step. You cannot hear audio: mark audible content "owner to confirm".
Journey <Jn>: <steps>
Reply in at most 150 words: PASS | FAIL | INCONCLUSIVE; the failing step with expected and observed;
what each step showed, one line each; crashes; one screenshot path; screenshots used.
```

## Screenshot budget

A screenshot is the main cost of a journey. Each helper (and the lead, if it drives) keeps to this:

- **Half scale by default:** `scale: 0.5` on every `screenshot`. It costs about a quarter of a full one and is enough to find controls and read normal text.
- **Zoom only to read small text** (a clock, a timestamp, a badge): `zoom` on that region, at `scale: 0.5` unless the text is still unreadable.
- **Full size only as evidence for a FAIL:** one full screenshot of the failing state, saved under the evidence folder.
- **About 15 screenshots per journey**, counting zooms. At the budget, stop and report INCONCLUSIVE ("screenshot budget") with the step reached, rather than going on. A journey that keeps hitting the budget gets split into two helper runs next time; say so in the report.
- **Don't screenshot to confirm a tap** that has no visible doubt; screenshot after the step, when its result should show.
- **Keep the mis-tap rule.** Before tapping near the bottom edge (keyboard tips, the tab bar), take a screenshot first, half scale; it counts toward the budget.

## Simulator pitfalls

From docs/journeys.md, which wins if they differ:

- After each step, record what the screen shows, which item or Margin is playing, and whether its clock advanced.
- After typing, take a screenshot and confirm the whole value arrived before tapping submit. Keystrokes and taps travel separately, and a truncated URL looks like a 404 or `-1011`, not a real bug.
- The app's Paste button doesn't see `xcrun simctl pbcopy`. Type values instead.
- Keyboard tips can swallow the next tap. Take a screenshot before tapping near the bottom of the screen.
- A cold Debug launch can be blank for about 5 s. Wait before the first tap.
- The first listen on a fresh install opens the Terms of Use sheet. Its buttons are at the very bottom of the scrolling text: swipe until nothing changes, then tap "Use iOS Voice". It is not a bug.
- Before a FAIL that says a control is missing or a step is blocked, grep the app source for the control's label and go where the code puts it. Quote the file and line in the report.
- You can't hear audio. A moving clock shows the app thinks it's playing. Mark audible content "owner to confirm".

## Keep bulk out of the lead's context

- `scripts/desk-batch.py` without `--print` or `--json`: read its GO/STOP line, then the work list file it names.
- Send `scripts/verify-tests.py` output to a file (`> artifacts/lane/<id>/verify.log 2>&1`) and read back only counts from its manifest:
  `python3 -c 'import json,sys; m=json.load(open(sys.argv[1])); print(m["status"]); [print(s.get("name"), s.get("counts"), {k: v for k, v in s.get("probation", {}).items() if v != "passed"}) for s in m["steps"] if "counts" in s]' <run>/manifest.json`
- Never print an `.xcresult` summary or a build log into context; `grep` it for the first `error:` or failing test, or `tail -20`.

## Crash flood

If one process crashes three or more times within a minute (a helper that sees this stops and reports INCONCLUSIVE; the lead does the rest):

1. Stop.
2. `scripts/lane-sim-boot --retire <udid> "crash flood: <process>"`. It marks the device unsafe first, so the pool never erases and boots it again, then shuts it down at once (it doesn't wait for another run's erase), stops its watcher and deletes it. (A flood that `verify-tests.py` catches does the same for a pool device by itself.)
3. Report INCONCLUSIVE with the crash names, and notify the owner.

Don't reboot in a loop or switch devices. A single crash is noted in the report and the run continues.

## Report and clean up

1. Post the report on the PR in the test-lane.md format (PASS / FAIL / INCONCLUSIVE, per-step observations, evidence paths, crashes, what's not verified, and the `tokens:` line: each journey's helper `subagent_tokens` and the lead's context at the end), then change the label from `lane:queued` to `lane:done`.
2. Give the pool device or devices back with `scripts/lane-sim-boot --done <udid>`, once each (not one marked unsafe: the next `--pool` retires it). Pool devices are reused, so a repeated `--done` on one that another run has since taken would shut that run down.
3. Remove the worktree with `git worktree remove .claude/worktrees/lane-<id>`, which also deletes its DerivedData. Disk space on this Mac is tight.
