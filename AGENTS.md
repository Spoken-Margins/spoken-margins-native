# Agent guide

Spoken Margins is a native iPhone/iPad listening app (iOS/iPadOS 26+). Listeners play articles, PDFs and podcasts, record spoken or written **Margins** anchored to the source, and share Margins as `.spokenmargins` packets that another listener can import and hear at the right place in their own copy. The product owner is a systems engineer, not an iOS developer: explain trade-offs plainly and bring decisions, not options lists.

## Current focus

Replace this section when the focus changes; do not append to it.

- **Baseline:** Build 29, tag `testflight/0.1-build-29` (`fcc4974`), is the last shipped build (internal TestFlight, 2026-09-25). `main` stays there; only the owner moves it.
- **Integration:** `next` carries the Build 30 work, including the new PDF reader and the voice fixes. It goes to testers only after it passes the owner's own use: "working means not being riddled with bugs."
- **Build 30 freeze (owner, 2026-10-06), until Build 30 is tagged.** The target: the owner can use Build 30 for a week of their own listening, and do one co-op round on a two-hour podcast, without hitting a bug that makes them stop. The scope is exactly the open issues in the `Build 30` milestone: co-op works, listening basics, and fixes waiting on the owner's phone check.
  - Only two kinds of PR get `automerge`: one that fixes or advances a `Build 30` issue, and one that changes nothing under `App/`, `Packages/` or `Contracts/` (pipeline, ops, docs, server). Other app PRs stay open without the label and are re-armed after the tag.
  - Threads, dispatch and the Codex worker take `Build 30` issues first. Outside the milestone, take only work that touches no app code.
  - Don't add issues to the `Build 30` milestone yourself. A new bug that would stop the owner using the build goes to them as a one-line question; everything else goes to `Build 31`.
- **Parallel workstreams:** streams and briefs are in [docs/workstreams/](docs/workstreams/README.md). Streams branch `ws/<id>-…` from `next`, one branch per PR, and open PRs into `next`. The owner's Claude Code project hands out work, one thread per `ready` issue, dispatches lane results every hour, and triages new issues in its daily routine (21:30 Eastern). On the Mac, the lane runner merges the `automerge` PRs it passes, the Mac tick reports the machine and runner on #337 every two hours, a scheduled Codex audit reviews sharing, persistence, audio and lane PRs, and the standing Test Desk tests each new tip of `next`. There is no standing triage desk ("The lead session" in [kickoff.md](docs/workstreams/kickoff.md) says who does what).
- **Codex runs the project while Claude is paused (2026-10-02, until Claude's reset Sat 07:00 EDT and the owner restarts the Claude project).** Hand-off: the newest "Codex hand-off" comment on #337.
  - **Codex worker** (`ops/codex/sm_codex_worker.py`, launchd, `gpt-6.1-sol` high, up to 3 slots from the Dial #589). It first finishes stalled PRs (newest lane report on the head is FAIL, or `needs-mac`), then takes `ready` issues, `priority` first. It opens `automerge` PRs into `next`. It skips issues labelled `in-progress`, `where:mac`, `regression` or `blocked`, so file work for it as `ready` (plus `priority`, plus `bug` for failures).
  - **Codex Test Desk** (`ops/codex/sm_codex_testdesk.py`, launchd): `--plan app` plus scripted journeys on each new tip of `next`, reports on #184, files real failures as `ready,priority,bug`.
  - **Codex journey desk** (a Codex app automation with computer use, set up by the owner per #693): hands-on journeys on the tip, reports on #184.
  - **Codex audit** (`ops/codex/sm_codex_audit.py`, launchd, `gpt-6-astra` high): audits risky and lane PRs; the runner merges those only after "No blocking findings" on the head.
  - **Rules for Codex app threads:** build only with `scripts/xcodebuild-lane`, boot simulators only with `scripts/lane-sim-boot` (one simulator Mac-wide; Claude's lane guard does not cover Codex), never boot 1330F268, and stop on a crash flood. Don't push to a PR that carries `automerge`; never force-push; don't touch `main`, releases or the owner's data.
- **Owner's standing calls (2026-09-29).** Don't ask again:
  - **Use the token allowance.** The subscriptions are paid for. Aim for roughly linear use of each weekly allowance, Claude and Codex, by its reset. Waste means little working output per token, not high spend.
  - **The design direction is not changing.** Build on the current look. Where the stream plan says a stream waits on D1, that gate is gone.
  - **The server on the owner's VPS is approved.** App features that use it go ahead. Any "waits on the owner's hosting call" gate is gone.
  - **No off switches for new features.** The way back is reverting the merge.
  - **Merge finished work on host tests plus both builds.** The Test Desk tests the merged tip end to end, instead of per-PR simulator gating.
- **Owner's standing calls (2026-10-05).** Don't ask again:
  - **"Post-MVP" is a legacy label.** The app is past MVP. The `phase:` labels and `[Post-MVP]` title prefixes were removed on 2026-10-05; if one turns up, or `parked` does, it never stops work on an issue. Judge the issue on its merits.
  - **Default on only when it costs the listener nothing.** A background or sharing feature may be opt-out only if both are true:
    - It's no burden on the device: no noticeable battery drain, heat or interface stutter.
    - It's airtight on privacy: nothing that links the data to a listener is stored anywhere, and even someone with full access to our systems and live logs couldn't tell whose data it is.
    - Otherwise it's opt-in.
  - **Keep no user data that could identify someone unless the feature needs it.** Where a feature needs it (a voice Margin is traceable by voice alone), encrypt it end to end so the server holds only unreadable bytes, as share links do (#805).
  - **Owner ideas are challenges, not directives.** When the owner suggests a solution, solve the challenge it serves. Treat the suggestion as one example and pick whatever works best.
- **Podcast anchors** continue as stream C4: [docs/podcast-anchor-plan.md](docs/podcast-anchor-plan.md).
- **Parked, reference only:**
  - `park/co-op-2026-09-24`: failed co-op attempt plus in-progress anchor work. Do not merge it; port pieces by hand. Its packets use a Margin kind this build can't read.
  - `codex/desktop`: macOS companion prototype.
- **Background:** why the repo was reset is in [docs/repo-review-2026-09-24.md](docs/repo-review-2026-09-24.md).

## Repository map

- `App/SpokenMarginsApp/`: the iOS app. `Gate1AppModel.swift` (~16k lines) is the app's central model and `Gate1RootView.swift` its main view.
- `App/SharedSources/`, `App/*Extension*/`: code shared with the Safari, share and widget extensions.
- `Packages/SessionKit/`: Swift package holding the domain logic. It is testable on macOS without a simulator.
  - `SessionKit`: sessions, Margins, models.
  - `SessionKitAudio`: playback adapters, podcast anchor evidence.
  - `SessionKitPersistence`: SQLite store.
  - `SessionKitSharing`: packets, import/export.
- `Contracts/`: JSON schemas, fixtures and product docs bundled with the app. `Contracts/docs/recovery-mvp.md` is the product boundary.
- `docs/`: durable product and architecture notes. `docs/archive/` holds historical process documents; don't treat them as instructions.
- `project.yml`: XcodeGen spec. The `.xcodeproj` is generated from it with `xcodegen generate`, and both are committed.

## How to work

- **One agent per stream, one change at a time within it.** Streams run in parallel only as laid out in [docs/workstreams/](docs/workstreams/README.md). Don't spawn manager, implementer and auditor chains: one owner per change, and one writer per set of files. Sub-agents and workflows are fine for exploration, reviews, critics, and tests in their own worktrees, as long as they don't edit the files you're changing.
- **A PR is done when it's armed; the session keeps going.** One issue per PR. Never stop mid-PR: work until the PR is open, has the `automerge` label and, if the diff needs simulator tests, its `/lane T3` request with `lane:queued` ([lane-request skill](.claude/skills/lane-request/SKILL.md)). Then take the next `ready` issue yourself (project threads check the usage breaker and dispatch advice on #337, and claim the issue first). Stop earlier only to hand an issue back that you can't finish.
  - **Above about 250,000 tokens at that point, stop instead.** Post a short note on the issue (what's done, what's next, what you learned) and let a fresh thread take the next issue. A big context makes every turn expensive, and compaction drops detail at a point nobody chose.
  - **No timers on your own PRs.** Don't set polling timers, reminders or check-ins to watch the lane or the merge. The lane merges on PASS. A lane FAIL on a PR's own code goes to whoever is free, through the project's hourly dispatcher; a runner fault gets one more run (a new `/lane T3` comment with the same `tests:` line plus `lane:queued` for an INCONCLUSIVE T3, or `automerge` removed and re-added for a host-test or build fault), and becomes an issue labelled `ready` and `regression` only if it fails the same way again.
  - **Build on your own unmerged branch only if you must, one level deep.** Branch the next issue from `next`. If it truly depends on your armed PR, branch from that PR's branch, but never from a branch that itself sits on another unmerged branch.
- **Small, verified commits.** Each commit is one logical change with a message that says what was wrong and why the change fixes it. The commit message and PR description are the record, so don't write separate handoff, audit or status files for routine work.
- **Branches.** Each PR gets its own branch, off `next` or, one level deep, off your own armed branch (project threads: `ws/<issue>-<slug>`). Don't push new work to a branch whose PR is armed: the runner could merge it half done. Merging to `main`, pushing `main`, archiving, uploading and distributing are the owner's decisions; ask first.
- **Decide reversible things yourself.** When a choice can be undone later, post it on your stream's tracking issue under a **Default taken** heading (the options, your pick, why) and keep going on your pick; the owner vetoes by number. Stop and ask only when the choice touches the owner's data, packet or database compatibility, money, anything public, `main` or a release, or taste (design, voice).
- **Don't grow `Gate1AppModel`.** Put new logic in a focused type, in SessionKit when it can be host-tested, and call it from the model. In particular, don't add another "should the source resume" flag or another playback state machine.
- **Keep packets compatible.** Packets exported by a new build must import into the last shipped build unless the owner explicitly accepts a break. Only require a new manifest capability when the packet actually uses the feature.
- **Protect owner data.** Never reset, reseed or delete the owner's Library or recordings. Storage changes must let the previous build still open the database.
- **Keep evidence local.** `artifacts/` is git-ignored. Test output, logs, screenshots and recordings stay there or on the external drive. Summarize results in the commit or PR.
- **Don't record instructions as documents.** Owner direction lives in the conversation, issues and this file's Current focus. Don't append directive logs to docs.
- **Use GitHub issues** for bugs and feature requests: one issue per problem, with steps, expected and actual behavior, and the build number.

## Verification

Tests that pass while the app is broken usually fake the exact boundary that broke: audio sessions, players, file paths across app containers, network responses. Verify in three layers, and don't let a lower layer stand in for a higher one.

While parallel streams are running, pick the lowest tier that covers your change from [docs/workstreams/test-lane.md](docs/workstreams/test-lane.md). Anything that boots a simulator (`--plan app`, journeys) goes through the test lane, not your own session.

1. **Component tests (host, fast).** This is the default loop for every change: `.venv/bin/python scripts/verify-tests.py --plan fast`. It runs the SessionKit suite, contract validators and browser suites.
   - In a new worktree, run `scripts/setup-worktree.sh` once first. It links the main checkout's `.venv` and `node_modules`, which git doesn't carry.
   - Write tests that can fail for the bug they name. Run a new regression test once without the fix and confirm it fails.
   - For a matching, sanitizing or page/title parsing bug, write a table of neighbouring inputs before fixing: case, whitespace, Unicode normalization, punctuation, empty, very long, the same item from another source, and lookalike items. Fix every row that fails in the same commit.
   - Prefer real temporary files, real SQLite and real AVFoundation decoding on macOS over hand-written fakes at the boundary being tested.
2. **App compile and app-hosted unit tests.**
   - Every app change: build for the simulator and device:
     - `scripts/xcodebuild-lane -project SpokenMarginsNative.xcodeproj -scheme SpokenMarginsApp -destination 'generic/platform=iOS Simulator' build-for-testing`
     - `scripts/xcodebuild-lane -project SpokenMarginsNative.xcodeproj -scheme SpokenMarginsApp -destination 'generic/platform=iOS' build`
   - `scripts/xcodebuild-lane` takes xcodebuild's arguments. It waits for one of two Mac-wide build slots and uses this worktree's `.build/dd`. A hook blocks raw `xcodebuild` builds in this repo.
   - After switching branches, use a fresh `-derivedDataPath`. Stale SessionKit modules in the shared DerivedData produce false "does not conform" errors.
   - App orchestration changes: run `--plan app` (app-hosted XCTest in one simulator). If it stalls before XCTest connects, stop and report it; don't retry in a loop.
   - `--plan app` uses its own `SpokenMargins Test Runner` simulator, never the journey one. It removes the app's data there before testing and shuts the simulator down afterwards if it booted it.
3. **Journey checks.** Before calling anything ready, run the affected journeys in [docs/journeys.md](docs/journeys.md) against the built app.
   - The agent drives the simulator with computer use (real taps and screenshots) and reports what was observed at each step, including clocks advancing and which item or Margin is playing.
   - An agent cannot hear audio. Audible content, Bluetooth, the Lock Screen and background behavior belong to the owner's pass on a physical device.

The scripted UI route plans (`--plan ui`, `speech-canary`, `release`) are retired from routine use. They were slow, prone to crashing the simulator, and missed the failures the owner found. Use journeys instead.

**Scripted journeys** are different: short UI tests that each follow one journey in [docs/journeys.md](docs/journeys.md), run by the Test Desk in the integration run on `next`'s merged tip, never as a per-PR gate and never by a stream session (owner, 2026-09-30).

- A thread that changes a listener's flow may add or update the script for the journey it affects, and names that journey in the PR. The script must compile in the PR's T2 build; `scripts/test-scope.py` treats `App/SpokenMarginsAppUITests/` as compile-only.
- A new or changed script goes on probation in `TestPlans/scripted-journeys.json`. It can't turn the integration run red until the Test Desk has seen it pass twice on the simulator, and one that flakes twice goes back on probation.
- The Test Desk runs new scripts, fixes them, and keeps the "Writing scripted journeys" guide in [docs/journeys.md](docs/journeys.md).
- Scripts don't cover audible content, the Lock Screen, Bluetooth, or anything that only looks wrong. Agent-driven journeys and the owner's phone keep those.

**Simulator crashes: use judgment.** The real hazard is a crash flood: many identical system-process crashes within a minute, which spam the owner's screen with dialogs (once about 20 in 10 seconds).

- **Stop for a flood.** If you see three or more crashes of the same process within a minute, stop, shut that simulator down, and report. Don't reboot in a loop, and don't switch devices to get around it.
- **Continue after a lone crash.** A single system-process crash can be noted and work can continue. Keep going on the same simulator or another one, and mention the crash in the report.
- **Automated handling.** `scripts/verify-tests.py` records isolated crashes as warnings and stops only on a flood.

Status words:

- `implemented`: code exists.
- `verified`: tests and builds pass and the agent ran the journeys.
- `human_validated`: the owner used it on a device and accepted it.

Only the owner sets `human_validated`.

## Releasing a build

The owner decides when a build goes to testers. Once they say to upload, the agent may archive and upload to internal TestFlight testing:

1. Bump `CURRENT_PROJECT_VERSION` in `project.yml` (every target), run `xcodegen generate`, and commit.
2. Verify through layer 3 and list anything not verified.
3. Archive (`artifacts/` is git-ignored):
   `scripts/xcodebuild-lane -project SpokenMarginsNative.xcodeproj -scheme SpokenMarginsApp -configuration Release -destination generic/platform=iOS -archivePath artifacts/SpokenMargins-<build>.xcarchive -allowProvisioningUpdates archive`
   Check the archive's `CFBundleVersion` is the new build number.
4. Upload to internal testing only:
   `PATH="/usr/bin:/bin:/usr/sbin:/sbin:$PATH" xcodebuild -exportArchive -archivePath artifacts/SpokenMargins-<build>.xcarchive -exportOptionsPlist scripts/TestFlightUploadOptions.plist -exportPath artifacts/export-<build> -allowProvisioningUpdates`
   The PATH prefix matters: Homebrew's rsync breaks Xcode's packaging step. A warning that onnxruntime.framework has no dSYM is expected and harmless.
5. Tag the archived commit `testflight/0.1-build-N`, push the tag, and fast-forward `main` to the release (ask before merging if it isn't a fast-forward).
6. Delete the archive and export folders unless the owner wants them kept.

Give the owner a short test checklist: the journeys to try, what changed, and known issues.
