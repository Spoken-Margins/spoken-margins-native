# Test lane: sharing one Mac between many streams

The Mac is the bottleneck. It is the only place that can build the app, boot simulators and drive journeys, and it can't run many simulators at once. The test lane is how streams share it, and the test tiers below are how streams avoid testing more than a change needs.

This page is the contract. Stream A1 (`lane`) builds the machinery behind it.

## Tiers: test what the change could have broken

Pick the **lowest tier that exercises what the diff could break**, and run it once. A tier doesn't include the tiers below it unless the row says so.

| Tier | What runs | Where | Typical cost | Use it for |
| --- | --- | --- | --- | --- |
| **T0** | Nothing, or a doc/link check | anywhere | 0 | Docs, research notes, charters, server code with its own tests |
| **T1** | The tests for the touched module only: `swift test --filter <Suite>` for SessionKit, or the stream's own Python/Node/server suite | Mac host; or Linux for `SessionKitCoreTests` (Core, Persistence, AI, EPUB, Feeds): `scripts/run-sessionkit-linux-tests.sh`, also run on every PR into `next` by `linux-t1.yml` | 1–3 min | Pure logic: parsers, ranking, packet merge, text cleanup, resolvers |
| **T2** | Compile the app for simulator **and** device (the two `xcodebuild` commands in `AGENTS.md`), no simulator boot | Mac, build semaphore | 4–10 min | Any change to `App/`, `project.yml`, or a SessionKit public API |
| **T3** | Targeted app-hosted XCTest (`-only-testing:` the touched test classes) in the Test Runner simulator | Mac, via the lane | 5–15 min | App orchestration: model/coordinator wiring, persistence through the app |
| **T4** | Named journeys from `docs/journeys.md`, or a one-off scenario the request spells out, driven with real taps and screenshots | Mac, via the lane (Test Desk) | 10–40 min each | A one-off scenario a PR asks for; the named journeys run in the integration run |
| **T5** | Full regression: `--plan fast`, `--plan app`, every journey | Mac, via the lane | 1–3 h | The integration run on `next`'s merged tip (see Three test levels) |
| **T6** | Owner on the phone | owner | owner time | Audible content, Bluetooth, Lock Screen, background, thermal. Batched per TestFlight build |

**Three test levels** (owner's decision, 2026-09-29). These replace per-milestone T3 and T4 and "T5 once per candidate":

1. **Per PR:** host tests plus both builds (`--plan fast` and T2), before merge. T3 only for audio session, storage and packet changes.
2. **Per batch:** the integration run on `next`'s merged tip: `--plan app`, a screen tour for the critics, the scripted journeys (below), and every journey on a library shaped like the owner's and upgraded from Build 29. The standing Test Desk runs it on each new tip (Starting the Test Desk). A real failure is reverted first: the desk opens a "Revert #N" PR for the culprit merge and files a `ready` + `regression` issue to re-land the change. Persistence, migration, packet-format and lane changes aren't reverted; the desk reports those to the owner on #184.
3. **Per candidate:** the owner's phone. The latest green integration run is the candidate.

**Rules of thumb**

- A change you could describe in one sentence, in one module, with a test that fails without it, stops at **T1**, or **T2** if it touched the app.
- Most PRs stop at T1 or T2. T3 per PR only for the escalations below; T4 per PR only for a one-off scenario the PR needs. Journeys and full regression run on the merged tip, not per PR or per milestone.
- **Escalate one tier** for anything touching the audio session, players, playback state, persistence/migrations, or packet import/export. These are where Build 28 → co-op went wrong.
- **Never escalate to T5 on a stream branch.** Full regression runs on `next`'s merged tip, in the integration run.
- A new regression test must be run once **without** the fix and seen to fail (`AGENTS.md`). That run counts as T1, not an extra tier.
- When unsure, ask the lane for the tier (A1 ships `scripts/test-scope.py`, which maps a diff to its minimum tier and suggested test filters). If the tool and your judgment disagree, take the higher tier and say why in the request.

## Scripted journeys

Scripted journeys are UI tests in `App/SpokenMarginsAppUITests/` that each follow one journey from `docs/journeys.md` (owner's decision, 2026-09-30, #445). Threads draft them, the Test Desk proves them, and they count only after probation.

- **Where they run.** Only in the integration run on `next`'s merged tip, never as a per-PR gate. Per PR, a script only has to compile: `scripts/test-scope.py` puts `App/SpokenMarginsAppUITests/` at T2 and never adds its classes to a T3 request.
- **Who writes them.** A thread that changes a listener's flow may add or update the script for the journey it affects, and names that journey in the PR.
- **Probation.** `TestPlans/scripted-journeys.json` is the one list the integration run reads. A new or changed script goes under `probation` in the same PR. It runs and is reported, but can't turn the integration run red. The Test Desk moves it to `gating` after seeing it pass twice on the simulator, and moves a gating script that flakes twice back to `probation`. `scripts/test_inventory.py` rejects an entry that names no real UI test or no journey.
- **What they don't cover.** Audible content, the Lock Screen, Bluetooth, and anything that only looks wrong. Agent-driven journeys and the owner's phone keep those.
- **How this differs from the retired plans.** `--plan ui`, `speech-canary` and `release` ran a broad route suite as a gate and stay retired (`AGENTS.md`). Scripted journeys are one short script per journey, each earning its place on probation.

A week after the first script gates, the desk's daily hand-off on #184 counts two things: regressions a script caught that the owner would otherwise have found on the phone, and simulator crashes or flakes the scripts caused. If the scripts caught nothing, or cost more desk time than they saved, that is the sign this was a mistake.

## The lane

**Endpoint A1 must reach.** Any stream, cloud or Mac, can request T2–T5 against a pushed commit without the owner doing anything, and gets a report on its PR. The Mac never runs more than **one** simulator job at a time (it has 16 GB; two simulators plus builds filled swap, #184). It never runs more than **two** `xcodebuild` invocations at once *in total*, and only one while a simulator job runs: one Mac-wide semaphore shared by the lane and every stream session. A crash flood stops the lane and notifies the owner.

**Recommended shape** (A1 may change it if the endpoint holds):

- **Intake is the PR.** A stream opens a draft PR into `next` and comments a request (format below) with the label `lane:queued`. Mac streams may also message the Test Desk session directly as a doorbell, but the request itself always lives on the PR so the owner can see it from the phone.
- **Deterministic tiers run without an agent.** A self-hosted GitHub Actions runner on the Mac, with a single concurrency group, runs T2 and T3 (and T1 for Swift) and posts the result. Cheap, repeatable, no tokens.
- **Journeys run with an agent.** The standing Test Desk session on the Mac runs in a loop on `next`'s tip, works in its own worktrees and DerivedData, drives the simulator, and posts its reports on #184. It runs a one-off scenario for a PR only when the owner or the coordinator asks it directly.
- **Coalesce.** If a newer commit lands on the same PR while a request is queued, test the newest only. Identical requests against the same commit run once.
- **Order.** Gate streams (A2 `seams`, anything blocking others) first, then oldest request first.
- **Evidence stays local.** Screenshots and logs go under `artifacts/lane/<request-id>/` (git-ignored). The request id is `pr<PR>-r<run id>`, plus `-a<N>` when a job is re-run, so a re-run never reuses a folder. The PR comment carries the observations and file paths, not images.

Note for whoever builds the Test Desk: Claude Desktop's iOS Simulator pane currently doesn't work with Xcode 27 ([docs](https://code.claude.com/docs/en/desktop-ios-simulator)). This repo builds with Xcode 27, so drive the simulator through computer use from the CLI, as the journeys do today, until the pane supports Xcode 27.

## Guard rails (deterministic, not advisory)

- **Only the lane boots simulators.** A1 installs a `PreToolUse` hook in the Mac's **user-level** settings (`~/.claude/settings.json`), so it applies to every session whatever branch it started on. It blocks `xcrun simctl boot|install|launch`, `xcodebuild test`, and `verify-tests.py --plan app|adapters|ui|release` unless the session is the Test Desk. Stream agents then *can't* start a simulator flood by accident. `AGENTS.md` sends `--plan app` through the lane for this reason.
- **Build semaphore.** Every `xcodebuild` on the Mac, from streams and from the lane, goes through one wrapper that allows two at a time and queues the rest.
- **Host-test slots.** Every `verify-tests.py --plan fast` run holds one of two Mac-wide host-test slots, or the one slot while a simulator job runs. So does a full `swift test` through `scripts/host-test-lane swift test`, and `run-sessionkit-tests.sh` uses it. They are separate from the build slots. Single-suite `swift test --filter` runs stay ungated: after the first build they are incremental and short. Three ungated runs at once pushed the load to 471 (#350).
- **Fresh DerivedData per worktree** (`AGENTS.md`: stale SessionKit modules give false "does not conform" errors).
- **Crash-flood rule** as in `AGENTS.md`: three crashes of one process within a minute stops the lane, shuts that simulator down and notifies the owner. A lone crash is noted in the report and work continues.

## Request format

Post as a PR comment. Keep it short; the Test Desk needs intent, not narrative.

**A finished PR needs no request comment.** Label it `automerge` when its "Done when" is met. The runner then runs what the diff needs, by the base branch's `scripts/test-scope.py`, and runs again on every push while the label stays:
- T0 (docs, research, the server): nothing.
- T1: `--plan fast`. Besides `scripts/tests`, it runs the tests in each `ops/` folder (`ops/dial`, and `ops/codex` once it has tests), so a diff that only touches `ops/` stops here, with no app build.
- T2 or higher: `--plan fast` and both builds.
Simulator tests (T3) still need a request. The lane check is green only on PASS.

Every lane job that posts a report and doesn't merge the PR, T2, T3 or automerge, ends by removing and re-adding `lane:done`, after its last report (the released automerge run's, when a T3 PASS starts one). Each job then makes a new `labeled` event, which is what the Hourly dispatch wakes on. An automerge run leaves `lane:queued` and `lane:running` alone.

A PR with a T3 request merges only on a T3 PASS (#410). While its newest T3 report is FAIL or INCONCLUSIVE, or its newest T3 request has no report yet, the automerge run reports FAIL or INCONCLUSIVE and doesn't merge, even when its own checks pass. A FAIL on an earlier commit holds later commits too, until a newer T3 passes. When a T3 then passes on the PR's current head, the lane job that reports it runs the held automerge run itself, in the same job (#421), and posts its report as `<id>-auto`; nobody needs to push or re-label. It runs there because a label the runner re-added with the workflow's token would start no new run.

While a `/lane T3` request whose `commit:` names the PR's head is still waiting (`lane:queued` or `lane:running`, no report yet), the automerge run doesn't run its own host tests and builds: it reports INCONCLUSIVE, held for T3, straight away, because the lane job that reports the T3 PASS runs them on the merge commit before it merges. A T3 request for an older head, or one with no `commit:` line, doesn't count, so a push after the request still gets the automerge checks.

A T3 run covers at least the app test classes the diff calls for. The runner adds every class the base branch's `scripts/test-scope.py` suggests for the PR's diff to the request's `tests:`, and the report lists what it added, with the test count and how long each plan took. A method you name inside an added class runs with its class. A diff touching `Gate1AppModel.swift` therefore runs all of `Gate1AppModelWorkflowTests` (151 tests), about 15 minutes with the boot.

Before any build, the runner checks the hot-file ratchet (`scripts/hot_file_ratchet.py`). A PR may not grow `Gate1AppModel.swift` or `Gate1RootView.swift` above the smallest size each has had on `next` since the ratchet started. Move lines out, or ask the desk for the `hot-file-ok` label. Run the script yourself to see where a branch stands.

```text
/lane T4
commit: <sha>
changed: <one line: what the diff changes, from the listener's side>
run: J1, J7            # T4: the journeys to run
tests: SourceLinkImportTests/testSubstackCustomDomain, Gate1AppModelWorkflowTests   # T3: app test classes or methods
scenario: <only for a one-off check: numbered steps + what passing looks like>
watch for: <the specific risk, e.g. "chunk boundary flips play/pause">
not needed: <what you already covered, e.g. "T1 green, T2 green on this sha">
```

## Report format

The Test Desk (or the runner) replies on the PR:

```text
Lane report <request-id> — PASS | FAIL | INCONCLUSIVE
commit <sha> · tier T4 · simulator <model, iOS version> · <duration>
ran: J1 (pass), J7 (fail at step 1)
J7 step 1 — expected: "Downloaded on…" stamp not read. observed: transcript shows it in paragraph 1 of page 2. evidence: artifacts/lane/<id>/j7-step1.png
crashes: none | 1 isolated SpringBoard crash (noted, continued)
not verified: audible content (owner), Lock Screen (owner)
```

`INCONCLUSIVE` is not a pass: no simulator available, XCTest never connected, a flood stopped the run. Say which.

## Starting the Test Desk

The Test Desk is a standing Claude Code session opened on the `spoken-margins-native-test-desk` folder, which sits next to the repo checkout (a git worktree). The lane guard lets only that session boot simulators. It runs as a loop and compacts itself at 300,000 tokens; after a compaction, its SessionStart hook prints this section, so this section is the desk's rulebook. Restart it from this prompt only when it starts contradicting what's recorded here or on #184, so that no rule lives only in a session's context.

```text
You are the Test Desk for Spoken Margins: the only session on this Mac allowed to boot
simulators. You run as a standing loop. Read AGENTS.md, docs/workstreams/test-lane.md,
docs/journeys.md, the journey and lane-request skills in .claude/skills/, and the last few
comments on #184, starting with the newest "Test Desk hand-off".

Setup: this folder is a worktree. Run git fetch origin && git switch --detach origin/next,
then scripts/setup-worktree.sh. Never create branches here. Build each job in a worktree of
its own: .claude/worktrees/lane-integration-<sha7> for next's tip, and lane-build29 (kept)
for Build 29. The understudy's worktrees are intrun-<sha7>; never touch them, and it never
touches yours. Build through scripts/xcodebuild-lane.

What wakes you: next's tip moving. Check #184 and next about every 45 minutes (waits of 20 s
or less at a time, or a background wait: a foreground sleep of 30 s or more is blocked).
When next's tip has no integration report on #184, run one job on that tip, in this order:
1. The app tests: erase and boot the standing device (below), then
   scripts/verify-tests.py --plan app --device <udid>. Post "Lane report
   integration-<sha7> — PASS | FAIL | INCONCLUSIVE" on #184, with the line
   "run by: Test Desk".
2. Only after a PASS: the screen tour, if the repo has one, then the scripted journeys in
   TestPlans/scripted-journeys.json (gating, then probation). They launch with --ui-testing,
   which resets the app's library, so they run before step 3 builds the journey library. A
   probation failure goes in the report but doesn't make it FAIL. Move a script to gating
   after two passes, and back to probation after two flakes, in a PR into next. Run them
   with scripts/verify-tests.py --plan journeys --device <udid>; its manifest's gating and
   probation maps give each script's result.
3. Then the journeys in docs/journeys.md. Erase the standing device again first, because the
   app tests wrote to its app data, and build a library shaped like the owner's and upgraded
   from Build 29 (lane-build29) before installing the candidate over it. Post
   "Lane report journeys-<sha7> — …" on #184.
A tip that lands mid-job waits for the next job. If the understudy has already posted the
integration report for a tip, start that tip at step 2.

Taking turns: the scheduled "SM integration run" is the understudy. It runs only when this
desk has posted nothing on #184 for three hours, works in its own intrun-<sha7> worktree,
and stays off the simulator while the standing device is booted.

A real FAIL: first rule out a flake (run the failing tests again, twice) and a lane fault
(no test ran, a missing VFS overlay or XCFramework, a boot that failed). Then find the
culprit merge, open a revert PR titled "Revert #N" into next with the automerge label, and
file the re-land issue, labeled ready and regression. Don't revert persistence, migration
or packet-format changes, or lane changes: report those on #184 for the owner.

Per-PR /lane requests are not your queue: the runner answers T2 and T3, and journeys run
on next's tip. Run a one-off scenario for a PR only when the owner or the coordinator asks
this session for it directly, on the standing device between jobs, and post its report on
that PR.

Simulators:
- The standing device is "SM Lane Desk erase-approval"
  (1330F268-5467-4421-9D55-1FCC3FF5CF8A), iOS 26.5. The owner approved it once in the
  simulator panel, and the approval survives an erase. Erase it before the app tests and
  again before the journeys, in this order, so the watcher doesn't read the shutdown as a
  SpringBoard crash:
    echo released > ~/Library/Caches/SpokenMarginsLane/watch-<udid>.stop
    xcrun simctl shutdown <udid>, then wait until the watcher (watch-<udid>.pid) exits
    xcrun simctl erase <udid>
    scripts/lane-sim-boot <udid>
  When the job ends, shut it down the same way (stop flag, then shutdown) and leave it. Don't
  use --done on it: --done deletes the device.
- A fresh device only when the standing one is marked unsafe or gone:
  UDID=$(scripts/lane-sim-boot --fresh "SM Lane Desk <name>"), while the owner is awake to
  approve it in the simulator panel. Name the new standing UDID in a hand-off on #184. Never
  a fresh device per job. Stay on iOS 26.5: iOS 27's Apple Intelligence services crash-flood
  on this Mac (#184).
- If scripts/lane-sim-boot prints STOP, stop and report. Never retry a failed boot or boot a
  device another way; the guard blocks devices marked unsafe.
- On 26.5, unlocking after a lock sometimes freezes the display. Mark lock-and-unlock
  steps "not verified" and leave them for the owner's phone pass.
- At most two simulator jobs on this 16 GB Mac, and the second only while memory pressure is
  normal (two plus builds filled swap before the owner freed memory, #184). The helper holds a
  Mac-wide simulator slot from boot until its watcher stops (the stop flag above, or --done). The runner's T3 takes the other slot or waits.
  `scripts/lane-sim-boot --second-slot status` says whether a second job may start. A journey
  that needs two devices (J5) still runs them one after the other, so the runner keeps its slot.
- Never touch any other simulator, other projects' simulators, the owner's iPhone,
  their Library, or main.

Crashes: after every journey step, check ~/Library/Logs/DiagnosticReports for new .ips
files. Three crashes of one process within a minute is a flood: stop, shut that
simulator down, report on #184, and wait for the owner.

Disk: check df -h / before each build or journey. Below 10 GB free, report
INCONCLUSIVE ("disk below 10 GB") on #184 and stop. After posting each report, delete
that run's .xcresult bundles and raw build logs. Keep only the screenshots and short
logs the report names, under artifacts/lane/<id>/. Shut the simulator down whenever
the queue is empty.

Reports: post in the report format above, on #184 (a one-off scenario's on its PR). There
is no lead session to message; the project reads reports on GitHub. Before you step down, or
when a fresh desk may have to take over, post a "Test Desk hand-off" on #184: the state of
the standing device and your worktrees, what's half-done, and lessons for this section.

Decisions: for reversible lane choices, post them on #184 under "Default taken" and keep
going. Stop only for owner data, the phone, money, anything public, main or releases.
```

## The Mac's runners

Two self-hosted GitHub Actions runners on the owner's Mac run `.github/workflows/lane.yml`. Each is a LaunchAgent in its own folder.

| | Main runner | Build runner |
|---|---|---|
| Name | `sm-lane-mac` | `sm-lane-mac-2` |
| Folder | `~/actions-runner-spoken-margins` | `~/actions-runner-spoken-margins-2` |
| LaunchAgent | `actions.runner.uncomposed-spoken-margins-native.sm-lane-mac` | `actions.runner.uncomposed-spoken-margins-native.sm-lane-mac-2` |
| Labels | `self-hosted, macOS, ARM64, sm-lane, sm-lane-build` | `self-hosted, macOS, ARM64, sm-lane-build` |
| Jobs | `lane` (/lane T2, T3, simulators) and `automerge` | `automerge` only (host tests and builds) |
| `.env` | `SM_LANE_EVIDENCE_DIR`, `SM_LANE_TOOLS` | the same, plus `SM_LANE_RUNNER_ROLE=build` |

- **Build runner gate.** With `SM_LANE_RUNNER_ROLE=build`, an automerge job waits up to 90 minutes for three things: no simulator job running, normal memory pressure, and 20 GB of free disk. Otherwise it reports INCONCLUSIVE and says why.
- **Check both:** `gh api repos/uncomposed/spoken-margins-native/actions/runners --jq '.runners[] | "\(.name) \(.status) busy=\(.busy)"'`. On the Mac, `./svc.sh status` in a runner's folder.
- **Restart one:** `./svc.sh stop`, then `./svc.sh start`, in its folder. Its logs are in `_diag/`, and the job workspace is `_work/spoken-margins-native/spoken-margins-native`.
- **Remove one:** `./svc.sh uninstall`, then `./config.sh remove --token <token>`. Get the token from `gh api -X POST repos/uncomposed/spoken-margins-native/actions/runners/remove-token --jq .token`.
- **Runner simulators.** A T3 job creates its own `SM Lane Runner <run>` device and locks that name in the lane state folder until it deletes the device. Every job first sweeps leftover runner devices but skips a locked one, so one runner's sweep can't delete the other's live T3 device (#440, #411). A crashed job's lock ends with its process, so its leftover is swept. If a plan's device disappears or its readiness step fails, the run stops there and reports INCONCLUSIVE as a lane fault, not FAIL.
- **Evidence:** each job writes to `SM_LANE_EVIDENCE_DIR`, which is `artifacts/lane/<request-id>/` in the owner's main checkout.
- **Git LFS:** both jobs check out with `lfs: true`, because the Supertonic models are LFS files and the contracts check reads them. The LFS cache is in the workspace's `.git`, so each runner downloads the models once.
- **Warm build folders.** A job links the tree's `.build` and `Packages/SessionKit/.build` to `~/Library/Caches/SpokenMarginsLane/warm-build/checkout-<checkout path hash>/sk-<SessionKit tree hash>-<project file hash>/`.
  - A SessionKit change starts a new cache, because stale SessionKit modules give false "does not conform" errors. An Xcode project change does too.
  - Each runner has its own caches. DerivedData and SwiftPM's state record absolute paths, and a cache shared by both runners lost Xcode's VFS overlay and the onnxruntime binary (#405).
  - A cache whose SwiftPM state lists a binary artifact that isn't on disk is emptied, and the job builds cold. Its report says which artifact was missing.
  - The T2 simulator and device builds each have their own DerivedData (`.build/dd-simulator`, `.build/dd-device`). When they shared one, the warm simulator build after a device build failed on a missing `all-product-headers.yaml` (#405).
  - At most two caches are kept per runner. Below 15 GB of free disk the job builds cold, and its report says so.
  - If a build error disappears on a cold rebuild, delete `warm-build/` while no job runs.
- **Merging.** An `automerge` PASS is merged by the runner itself (`scripts/lane-runner.py`, `run_auto`):
  - It tests the exact merge commit (next first), posts "**Merge check (triage desk)", then does a plain push. A push refused because next moved leads to a re-test, up to 3 times, unless next's commits since the tested one touch none of the PR's files and no build inputs (`project.yml`, any `.xcodeproj` or `.xcconfig`, `Config/`, `Package.swift` and `Package.resolved`, `package.json` and its lock, `.github/`, `scripts/`, `Contracts/schemas/`). Then it merges onto the new next and pushes without testing again, the owner's standing call being that the Test Desk tests next's merged tip end to end. The report says which way it went and lists the commits it didn't re-test against, and that merge check doesn't say "Pushing `<sha7>`", so `scripts/phone-build` runs its own checks on that tip.
  - It never merges `.github/` or `scripts/lane*` changes; those need a person.
  - An audio, persistence or packet diff merges only when the newest Codex audit that names the PR's head commit (the heading "**Codex audit (Astra) on `<sha7>`**") opens its verdict (the first line after the heading) with "No blocking findings" (#441). An audit of an older commit, or one with findings, holds it, and the report says which. It reads the comments again after testing, so an audit that lands during the run counts. An older manual "## Codex audit" counts only if its heading names the head commit.
  - After each merge it runs `merge_audit.py --sweep-hours 2`, because pushes made with the workflow token start no workflow. `merge-audit.yml`'s hourly schedule runs only once that file is on the default branch (`main`).
- **Stale merge refs.** GitHub builds a PR's run from its merge ref, and a label event doesn't refresh it. A PR opened before a `lane.yml` change keeps the old jobs until it merges next and pushes (#221).
- **Mac-wide state** is in `~/Library/Caches/SpokenMarginsLane/`: the slot locks, `boot-events.log`, `unsafe-simulators.json`, and the lane guard's `guard.log`. The guard hook is `~/.claude/hooks/spoken-margins-lane-guard.py`; reinstall it with `scripts/install-lane-guard.py`, and use `--check` to see drift.

## What the owner sees

- Each stream's PR shows its requests and reports in order, so the phone view of GitHub is the dashboard.
- The owner gets a notification only for: a crash flood, a FAIL on a gate stream, a TestFlight candidate that passed T5 and is ready for T6, or an owner decision a stream is blocked on.
