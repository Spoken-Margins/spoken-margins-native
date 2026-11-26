# Retiring CI from the owner's Mac (plan for #2476)

Status: plan, not built. Written 2026-11-21 on the owner's call in #2476 ("nothing runs under my own user, and ideally my computer is not used for CI at all, only hosted Mac runners"). It changes #2476 from "wait until only T3 remains" to "retire the Mac lane runners". Nothing in this file changes behaviour; each step below is its own PR or its own owner action.

## Where this starts

The merge move already did most of the work. Read from GitHub on 2026-11-21:

- **The lane is off.** `lane.yml` is `disabled_manually` since 2026-11-20 04:02Z, the merge queue switch-over (#4693). The queue's required checks all run on GitHub's own machines: `hosted fast: scope`, `portable`, `Mac rest`, `hosted web`, `merge policy` (`scripts/ci_model.py` SNAPSHOT, taken 2026-11-20).
- **The Mac runners were already idle.** In the last 500 `lane.yml` runs (2026-11-18 17:15Z to 2026-11-20 03:56Z) every job that asked for a self-hosted label was skipped, or cancelled before a runner took it: 0 Mac minutes. No other workflow names a self-hosted label (`grep self-hosted .github/workflows`). `shipped-build-compat.yml` says "Mac" in its header but runs on `xcode-27`.
- **Hosted Macs are free here.** `xcode-27` is a standard GitHub-hosted arm64 Mac (3 CPU, 7 GB). Standard runners are free and unlimited on a public repository, and a hosted run's billing record is empty (#2596, 2026-10-24). No larger runners exist on the org. This is the assumption the whole plan rests on: it holds while the repo is public.

So "retire the Mac lane runners" is mostly finishing and deleting, not moving. What still depends on his Mac is below.

## What runs on the Mac today, what it caught, and what to do

**Not checked:** the Mac itself (`launchctl list`, which runners are registered). The runners and secrets endpoints are blocked from a cloud session. Everything below comes from the repo, from GitHub's workflow and run data, and from the reports on #184. The first step has the owner read the Mac.

| # | Check | Where it runs now | What it caught (source) | Proposal |
|---|---|---|---|---|
| 1 | The three self-hosted runners and `lane.yml` (`lane` T2/T3, `automerge`, `automerge-mac`, `release`) | Mac; the workflow is disabled | Per-PR T3, week of 2026-11-11: about 240 reports, 149 PASS, 64 ran no test (runner faults), 22 FAIL on 17 PRs. Of those 17: 4 mutation PRs, 4 real app bugs, 9 failed because of the test itself (#2048, 2026-11-18). A scheduled main run would have found all 4 real bugs a few hours later. Per-PR app builds: 0 catches in 132 (October), and 140 runs in a week with none (#1196). | **Drop.** Merge queue and `main-t3` replaced it. Remove the runners (step 1), then delete `lane.yml`, `lane-runner.py` and its helpers (step 6). |
| 2 | Per-PR compile and fast checks | Hosted since 2026-11-01; in the merge queue since 2026-11-20 (`app compile` joins a group that touches build inputs, #4759) | Not measured per catch here. | **Keep hosted.** No change. |
| 3 | `shipped-build-compat` (the previous build can still open the database) | Hosted `xcode-27` | Guards packet and database compatibility; no recorded catch. | **Keep hosted.** Fix its stale "Mac" header in step 6. |
| 4 | `main-t3`: all app tests on `main` | Hosted `xcode-27`, every 3 hours when `main` moved, plus 6:30 and 15:30 Phoenix | 14 runs since 2026-11-18, none green on a run that tested. Real finds: a stale bound (#4682), two stale tests (#4737, #4738), a compile error from #4602. Faults: the onnxruntime download failed twice on 2026-11-21 (the 02:29Z run, and the 16:06Z dispatch recorded `error`, "Could not resolve package dependencies"). Median 42 min per run that did work (12 such runs, 867 min in total). | **Keep, and make it reliable** (see "GitHub's schedule" below). |
| 5 | Integration run: `ops/testdesk/sm_integration_run.py` from launchd every 10 minutes | Mac. Hosted `main-t3` is meant to cover tips, but the Mac still tests when hosted has not. | 12 revert PRs from 2026-10-09 to 2026-11-20, 10 "Re-land" issues (search `Revert #` and `Re-land` titles). Most recent: on 2026-11-20 `main-t3` had not run since 03:35Z, the Mac run built `1c7a790` at 10:47Z, found `FollowListsScreen.swift:33` (no `return`), bisected to #4602 and opened revert #4751. Since 2026-11-20 23:04Z the lane guard refuses its commands on a bogus "U is marked unsafe" mark, and the 2026-11-21 00:43Z run was INCONCLUSIVE (report `integration-7c8c2aab6`). | **Move the revert and bisect to hosted, then turn the Mac job off** (steps 3 and 5). Hosted `main-t3` never reverts today, so this is the one duty the Mac does that nothing else does. #4574 designed it. |
| 6 | Scripted journeys at a phone-build cut or an upload | Mac, requested by `scripts/phone-build`; hosted `hosted-integration.yml` can run them by dispatch | About 50 min each on the Mac (reports 2026-11-19 to 2026-11-21: 5 runs in 3 days). Through 2026-11-07: the one gating journey was in 8 of 53 integration FAILs and opened no revert; of 17 "red at two cuts" issues, about 14 were fixed in the script only and 2 found listener bugs (#3669, `test-lane.md`). A median hosted run spends about 67 of its 110 plan minutes on them. | **Run on hosted, at an upload only** (step 4). A phone build keeps its app tests via `main-t3`. Scripts red at two cuts still end, as the 2026-11-09 rule says. |
| 7 | Phone build | Hosted `phone-build.yml`, 12:00 and 21:30 UTC, fired on 7 of 7 days (2 a day). The Mac downloads the artifact and installs it (`scripts/phone-build --source hosted`) | Delivery, not a check. | **Keep.** Installing on his own phone is not CI. Archive and upload also run on the Mac when he says "upload" (AGENTS.md, Releasing a build). Moving both to a hosted, owner-triggered workflow is possible later, and is his call. |
| 8 | Test Desk: T4/T5 agent-driven journeys, the screen tour's captures, `agent-verify` | Mac, attended (owner-started) or managed (started by the coordinator on a `Test Desk: GO` tick line) | Different from the automated runs. The 2026-11-13 desk found two real UX gaps no test asserted (the Discard confirm has no Cancel; no Done bar on Write a Margin, #4240) and filed the J12 script bug (#4253). | **Keep only as owner-started and attended.** Stop the managed desk and the `Test Desk: GO` line. This is a person-driven tool, not CI. |
| 9 | Mac finisher (interactive) and Claude Mac worker (launchd `claude -p`) | Mac | 127 PRs carry a "Handing to the Mac finisher" comment, all time. Today 14 PRs carry `needs-mac` (1 opened since 2026-11-14), and 22 `where:mac` issues are open (177 carry the label, open and closed). | **Stop both.** What they gave cloud threads, a way to run app tests on a branch, comes back as `branch-t3` (step 2). Re-triage the 22 open `where:mac` issues: drop the label where a simulator is enough. |
| 10 | Supporting jobs: `lane-power-guard`, `lane-tools-refresh`, the lane guard hook, `disk-relief`'s lane-folder prune, `runner-guard` | Mac | They exist only to keep the runners and Mac builds healthy. The guard hook is what blocks the integration run on the bogus mark today. | **Delete with the runners** (step 6). `keep-awake` and the rest of `disk-relief` serve his own agent sessions: leave them. |
| 11 | Not CI, but on his Mac: the Mac tick on #337 (usage breaker and pacing), `sm-gh`, the away check, the daily phone plan | Mac | The breaker and pacing depend on the tick. | **Out of scope.** Listed so nobody thinks they went. Moving the tick is a later question. |

The Dial gate and the share-link server run on the VPS, not his computer, and are not touched.

## What the evidence says about his doubt

His doubt is right for the per-PR runs: they blocked far more than they caught (row 1), and the app-build gate caught nothing for weeks. It is only half right for tip-level runs. Row 5 is a real catch: a compile error landed on `main` after the per-PR build was removed, and the Mac found it. But it is a catch by a run on a tip, and a hosted Mac can do that if its trigger is reliable. It was the Mac only because GitHub did not start the hosted run. Nothing here needs his machine for the app tests themselves.

## GitHub's schedule has been dropping runs

Scheduled runs started per day, 2026-11-14 to 2026-11-21, from `gh api .../runs?event=schedule`:

| Workflow | Cron | Nominal per day | Started per day |
|---|---|---|---|
| `claude-audit` | every 15 min | 96 | 2 to 4 |
| `merge-stall` | every 15 min | 96 | 2 to 5 |
| `merge-queue-label-bridge` | every 15 min | 96 | 2 (since 2026-11-20) |
| `main-t3` | every 3 h plus 2 fixed ticks | about 10 | 3 to 5; the 13:30, 14:17 and 15:30Z ticks on 2026-11-21 all missed |
| `phone-build` | 12:00 and 21:30 UTC | 2 | 2, on 7 of 7 days |
| `pipeline-dashboard` | daily | 1 | 1, on 8 of 8 days |

Frequent crons fire a small fraction of the time. Twice-a-day and daily ones fire. `ci_model.py` records the same (audit gaps of 4 to 9 hours). Two consequences: `main-t3` as scheduled cannot be the only safety net, and the 15-minute audit and queue sweep run far less often than their comments say.

Fix, in this order of preference:

1. **Start `main-t3` from a push to `main`**, not only from the clock. GitHub makes the queue's merge, not the workflow token, so it should start `push` workflows (step 2 proves it). A Linux `decide` job (already there) skips the run when the head already has a `main-t3` status or when the last run began under 3 hours ago, so cost stays at 8 runs a day or fewer. The cron stays as a backstop. Needs a `.github/` change: his merge tap.
2. **A watchdog outside GitHub's scheduler**: a timer on the VPS (the Dial gate's timer already fires on schedule there) that dispatches `main-t3` when `main` has no status after 3 hours. Needs an Actions-write token on the VPS, a new secret. Only if step 1 is not enough.
3. Cache or mirror the two onnxruntime packages. Both `main-t3` faults on 2026-11-21 were a package download failing. The same kind of fault stalled 68 armed PRs on 2026-11-18 (#4512, Microsoft's onnxruntime repository went 404).

## Cost per run and per month

All hosted, all free while the repo is public. Hours are estimates from the 14 `main-t3` runs and #3669's journey sample, not measurements of the final design.

| Piece | Cost per run (hosted Mac) | How often | Per month |
|---|---|---|---|
| `main-t3` | median 42 min (12 runs: 3 to 259 min) | at most 8 a day | up to about 170 h |
| `branch-t3` (new, on request) | 15 to 25 min for a targeted class list (per-PR T3 averaged about 25 min, #2596) | when a thread or the owner asks | not forecast: zero when nobody asks |
| Journeys, at an upload | about 67 min | 1 to 2 a week | about 5 to 9 h (about 67 h if kept at every phone-build cut) |
| Bisect on a red `main` | about 5 builds, about 20 min each on hosted | about 2 reds a week | about 15 h |
| Phone build | 9 to 13 min | 2 a day | about 11 h |
| Merge queue's Mac jobs | unchanged | per merge group | unchanged |
| **Total added or kept** | | | **about 200 h, $0** (about 260 h if journeys stay at every phone-build cut) |
| His Mac, after step 5 | 0 unattended minutes | | 0 |

Today's Mac cost is not billable, but it is real: the Mac must be awake, plugged in and cool; the lane folder is capped at 16 GiB; the load reached about 228 on 8 cores during a cluster run (2026-11 decisions). What would break the "$0" claim: the repo going private, or GitHub charging for standard macOS minutes. Then the free limit, not this plan, is the problem.

## Risks the cutover must name

- **iOS 26 coverage.** The hosted image ships iOS 27 only (27.0, 27.1 and, since about 2026-11-23, 27.2; `scripts/lane_sim.py:230`). The app targets iOS 26 and iPadOS 26, and his Mac stays on 26 because iOS 27's services crash-flood there (#184). After the Mac retires, no automated run tests on iOS 26. **Default taken:** accept iOS 27-only for app tests now, and run a spike on adding the iOS 26 runtime to a hosted job (size and minutes). A layout test that failed only on iOS 26.5 (#3984, a button 43.99 points against 44) is the kind it could miss. His phone is the check for iOS 26 behaviour either way.
  - **Spike result (#4842, 2026-11-23): go.** One run on `xcode-27` ([run 45285363085](https://github.com/Spoken-Margins/spoken-margins-native/actions/runs/45285363085), from a throwaway workflow on `claude/project-thread-dpx9ye`, since removed). `xcodebuild -downloadPlatform iOS -buildVersion 26.5 -architectureVariant arm64` under Xcode 27.0 installed iOS 26.5 (23F77): an 8.52 GB download, 132 s, and 8.0 GiB of disk (36 GiB free before, 28 GiB after, 16.5 GiB after the build and tests). The image is 3 CPU and 7 GiB of memory as before, and it now also ships Xcode 27.1 and 27.2 and iOS 27.2. The lane's own choice (`SM_LANE_IOS_MAJOR`, which prefers 26 when present) then picked a cloned iPhone 17 on iOS 26.5, and `branch_t3.py` ran `KeychainStoreTests` and `PinnedMarginCardLayoutTests` (the #3984 kind of layout check): 5 passed, no crashes, after one startup stall that the first retry cleared (the lane's usual rule, logged on #1802). The step took 26 min with a cold compilation cache: build 11.5 min, template and clone 5.5 min, boot 1.8 min, the rest the tests and the retry.
  - **Cost per `main-t3` run.** Testing on iOS 26 instead of 27 adds only the install, about 2.5 min. Testing on both adds the install plus a second pass of both plans on the same build (about 30 min: the 42 min median of a `main-t3` run that tested, less this run's 11.5 min build). Hosted minutes are free while the repo is public. Turning it on is a `.github/` change, so it is the owner's tap: #5221.
- **No physical device, Bluetooth, Lock Screen or real audio.** These were never in CI. They stay on his phone pass (AGENTS.md). BlackHole runs on hosted (`audio-loopback-probe.yml`, `mac-rest`).
- **The revert depends on a token.** A PR opened with the workflow token starts no workflows (`test-lane.md`, #4693), so a hosted revert PR would never merge. The bisect job needs `MERGE_QUEUE_TOKEN` or a narrower one. Scope decision at step 3; findings on it go to the owner.
- **Fork and PR-supplied workflows.** While runners stay registered, any PR in this repo that adds `runs-on: [self-hosted, macOS, sm-lane]` can run on his Mac, because a PR's workflow files come from its merge commit. The runner guard blocks forks only. This is why step 1 comes first and does not wait for anything.

## Order of the cutover

Each step lists what must be true before it, and what undoes it.

1. **Owner, about 10 minutes, today.** Remove the three runners: on the Mac, in each runner folder, `./svc.sh stop`, `./svc.sh uninstall`, then `./config.sh remove --token <token>` (the token: `gh api -X POST repos/Spoken-Margins/spoken-margins-native/actions/runners/remove-token --jq .token`), or remove them under Settings, Actions, Runners and boot out the three `actions.runner.*` LaunchAgents. Delete the secret `SM_LANE_RUNNERS_TOKEN` (runner discovery, now unused). Needs: `lane.yml` stays disabled. Undo: re-register (`test-lane.md`, "The Mac's runners"). Closes the blast radius of #2476 and makes #2479's runner-group step moot. #2479's second half (the Mac login's `workflow` scope) stays until step 5.
2. **`branch-t3` and the `main-t3` trigger** (one `.github/` PR, owner's tap). `branch-t3.yml`: `workflow_dispatch` with a same-repo branch and test classes, hosted Mac, posts PASS or FAIL on the PR. It replaces `/lane T3`, which now has nothing listening. `main-t3.yml` gains the push trigger from "GitHub's schedule". Prove it: a dispatch on a branch posts a result; the next push to `main` starts a run.
3. **Bisect and revert on hosted** (#4574, extended). After a red `main-t3`: a hosted job builds the merges since the last green SHA by bisection, runs only the failing classes, opens the revert PR and the re-land issue with a token that starts workflows. Keep the Mac's refusal rules (persistence, packet, `.github/`, two culprits go to the owner). Needs step 2's trigger.
4. **Journeys on hosted, at an upload.** A hosted dispatch (the `--hosted --journeys` path in `sm_integration_run.py`) writes `Lane report scripted-journeys-<sha7>` on #184; `scripts/release_gate.py` reads it; `phone-build.yml` and `scripts/phone-build` stop requesting journeys on the Mac. Needs `.github/` and `scripts/phone-build` changes.
5. **Turn the Mac jobs off.** Gate: for 7 days every `main` tip older than 3 hours has a `main-t3` status, and one real red has been bisected on hosted. Then: boot out `integration-run` and the Claude Mac worker, stop the Mac finisher and the managed desk, remove `needs-mac` and the finisher steps from dispatch, redefine `where:mac` as "needs a physical device" and re-triage the 22 open ones. Undo: `ops/install-launchd.py --install integration-run`. If the gate is not met, this step waits, and nothing else does.
6. **Delete the dead code** (several PRs, each its own issue, the `.github/` ones for his tap): `lane.yml`, `scripts/lane-runner.py` and the `lane_*` helpers and their tests, `ops/lane/` (power guard, tools refresh; keep `sm_lane_open.py` only if the Dial still uses it), `ops/runner-guard/`, the lane-folder prune, `install-lane-guard.py` and the guard hook, the integration-run launchd template, `runner_queue.py`; fix the stale headers (`shipped-build-compat.yml`, `hosted-integration.yml`).
7. **Rewrite the rules** in the same PRs as steps 5 and 6, so no document describes a lane that is gone. See below.

Order rationale: step 1 closes the risk with no dependency. Steps 2 to 4 build what the Mac still does for the project before step 5 takes it away. Deletion comes last because nothing is lost by leaving dead code for a week.

## What changes in the rules

**`AGENTS.md` (public).** Edit, not add:
- "How to work": the "No Mac is never a reason to skip" and "No per-PR app build and no T3 hold" bullets are merged into one that names what exists now (merge queue, `main-t3`, `branch-t3`) and drops "the hosted Mac workflow builds every app PR" and "a requested `/lane T3`". The `main` merge refresh bullet drops `lane.yml` and the lane runner.
- "A stop note names a real blocker": `where:mac` now means a physical device, not a Mac.
- Verification layer 2: `scripts/xcodebuild-lane` and the build-slot text go (that is for one Mac shared by many agents); layer 3: "lets the lane or the Test Desk run them" becomes "lets a hosted dispatch or an owner-started desk run them".
- `docs/contributing/automation.md`: names the merge queue and `main-t3` instead of the lane.

**Private overlay and project instructions.** They carry their own Mac rules (the owner overlay, the coordinator's instructions, the Dial and dispatch routines). The edits they need are listed in the private repo, not here, and land in the same PRs as steps 5 and 6.

**Docs.** `docs/workstreams/test-lane.md` (474 lines) shrinks to the merge queue, `main-t3`, `branch-t3` and journeys; `docs/scheduled-jobs.md`, `docs/workstreams/finisher.md`, `ops/claude/README.md` and `ops/testdesk/README.md` lose the Mac jobs; `docs/decisions.md` records the call.

**Skills.** `lane-request` and `journey` (the Test Desk skill) are rewritten or removed in step 5 (the `lane-request` skill points at a lane that no longer answers).

## Cost and catch (of this plan)

- **Cost per run:** see the table above; the plan adds no recurring cost beyond `main-t3`'s existing 8 runs a day, an on-request `branch-t3`, and bisect on a red; it removes every unattended minute on his Mac.
- **How often:** as in the table.
- **What it is meant to catch, with evidence:** the same breaks the Mac integration run found (12 reverts, 2026-10-09 to 2026-11-20), but on a machine and a trigger that does not depend on his Mac being awake or on GitHub starting a cron.
- **Waste signal:** `branch-t3` unused for 30 days (delete it); `main-t3` red on more than one run in four for real bugs (back to a batch before merge, #2048); a month where bisect never finds a culprit.

## Decision for the owner

Retire every unattended job on his Mac in the order above. Pick **A** (recommended): go. Step 1 is his; the rest are PRs, and the two `.github/` ones wait for his tap. Step 5, the Mac integration run switching off, waits for the 7-day gate, so the Mac stays as the safety net until `main-t3` proves it can be. **B:** go, but keep the Mac integration run indefinitely as the backup for dropped schedules (the Mac then stays awake for CI). **C:** keep things as they are (the Mac then stays a CI machine, and #2476 reverts to "wait").
