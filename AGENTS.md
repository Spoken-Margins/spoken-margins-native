# Agent guide

Spoken Margins is a native iPhone/iPad listening app (iOS/iPadOS 26+). Listeners play articles, PDFs and podcasts, record spoken or written **Margins** anchored to the source, and share Margins as `.spokenmargins` packets that another listener can import and hear at the right place in their own copy. The product owner is a systems engineer, not an iOS developer: explain trade-offs plainly and bring decisions, not options lists.

## Working with the owner

Every thread and the coordinator follow these.

- **A question he can answer (owner, 2026-10-09).** "you need to set me up to be able to answer these... they do not present a question for me to answer." A thread that waits on him ends with a `reply`, never only a status line. The reply stands on its own: what this is in one sentence, the question, your pick, the other options on short lines with their cost, and what it blocks. He can answer in one word.
- **Technical calls are ours (owner, 2026-10-09).** "I don't want to be asked these questions. These are very simple and should be left to expert programmers such as yourself." and "I'm not very appreciative of the smaller questions that are outside my expertise." Take the default, post **Default taken**, keep going. What he is asked is in "Decide reversible and technical things yourself".
- **The coordinator follows through (owner, 2026-10-09).** "I thought, as the coordinator, this would be your job, but I keep on finding myself doing this." When a hold lifts, the coordinator tells every affected thread and re-arms held PRs in the same turn, without asking him. Whenever it is woken, it clears stale or technical "waiting on you" items.
- **Check before you report (owner, 2026-10-14).** "Why do you need my prompting to do these things?" Any status line, and any "armed", "merged", "waiting on…" or "nothing needs you", rests on a live read in the same turn: the PR's head checks, its latest lane report, its audit and its mergeable state. A thread's last report is not evidence. Name what you checked.
- **His answers stick (owner, 2026-10-14).** Before asking him anything, search this file and the issue for an earlier answer; if one covers it, act on it. When he answers something that will come up again, add it to the standing calls under Current focus the same day, quoting him with the date, in a PR that touches no app code. A tap on a decision card is his answer: quote the card's question and his pick.
- **Fix a broken rule or routine; don't just report it.** A routine that points at a missing section, a rule that contradicts another, a notice that fires by mistake: take a **Default taken**, fix it, and say so once. Don't raise the same breakage with him twice.
- **How to talk to him (owner's standing needs, restated 2026-10-09).** He is dyslexic and listens to replies: lead with the answer, use short plain sentences and numbered points, and list issue numbers at the end. He is red-green colorblind: red and green alone never carry meaning. When he must act, give numbered steps, the full link, exactly what to tap and type, and what happens after.

## Current focus

Replace this section when the focus changes; do not append to it.

- **Baseline:** Build 30, tag `testflight/0.1-build-30` (`07c6699`), is the last shipped build (internal TestFlight, 2026-10-08). Listening Baseline was repackaged without app-code changes as Apple build 32, tag `testflight/0.1-build-32` (`ec940321`), and is Approved for external TestFlight; automatic tester notifications are off. Build 31 was uploaded but superseded before review to correct privacy declarations. The next upload must use a number above 32. `main` stays at Build 30; only the owner moves it.
- **Planning identifiers (owner, 2026-10-08):** milestones use our own names, independent of Apple's upload numbers: `Listening Baseline` (milestone 2, formerly Build 30), `Solid Ground` (milestone 6, formerly Build 31), and `Co-op Experience` (milestone 7, formerly Build 32). An extra upload consumes an Apple build number without completing or advancing a milestone. Build numbers remain in tags, compatibility checks and bug reports to identify actual binaries.
- **Integration:** `next` carries `Solid Ground` work on top of Build 30. It goes to testers only after it passes the owner's own use: "working means not being riddled with bugs."
- **Solid Ground target (owner, 2026-10-08), until the owner accepts and ships that milestone.** The target: the owner can use the candidate the way they used Build 30, while the groundwork under it gets stronger. `Gate1AppModel` is split into focused types, the tests that passed without proving their claim now prove it, and the pipeline's known faults are fixed. What the owner notices: later builds arrive faster, and the Test Desk catches bugs before they reach their phone. The scope is exactly the open issues in the `Solid Ground` milestone: model split slices, test honesty, lane and pipeline fixes, and bugs found on the owner's phone.
  - Threads and dispatch take `Solid Ground` issues first. Work outside the milestone waits in `Later` or has no milestone.
  - What joins `Solid Ground` after today: a model split slice, a test-honesty finding, a lane or pipeline fault, or a `found-on-phone` bug. Any other new bug that would stop the owner using the build goes to them as a one-line question; co-op and sharing work goes to `Co-op Experience`; everything else goes to `Later`.
  - The `Listening Baseline` freeze ended with the Build 30 tag. Claude threads' `automerge` is no longer limited to milestone work: re-arm the app PRs that only the freeze was holding back.
- **Co-op Experience target (owner, 2026-10-08): a fantastic co-op experience.** It starts after the owner accepts and ships `Solid Ground`. Co-op and sharing work (the F1 co-op items, share links and their encryption, co-op follow-ups) waits in the `Co-op Experience` milestone. A build-number bump alone does not start this work.
- **Parallel workstreams:** streams and briefs are in [docs/workstreams/](docs/workstreams/README.md). Streams branch `ws/<id>-…` from `next`, one branch per PR, and open PRs into `next`. The owner's Claude Code project hands out work, one thread per `ready` issue, dispatches lane results every hour, and triages new issues in its daily routine (21:30 Eastern). On the Mac, the lane runner merges the `automerge` PRs it passes, the Mac tick reports the machine and runner on #337 every two hours, a scheduled Claude audit reviews sharing, persistence, audio and lane PRs, and the standing Test Desk tests each new tip of `next`. There is no standing triage desk ("The lead session" in [kickoff.md](docs/workstreams/kickoff.md) says who does what).
- **Codex goes away after 2026-10-15 (owner; #1195), and Claude is the only model on the project.** What took over, all described in `ops/codex/README.md`:
  - **Audit:** `ops/codex/sm_codex_audit.py` (launchd; the old name stays) calls headless Claude, read-only, and posts `**Claude audit on `<sha7>`**`. The runner merges audio, persistence, packet and lane PRs only after "No blocking findings" on the head, from this or from an older Codex audit comment.
  - **Ready issues and stalled PRs:** project threads take `ready` issues, and the Mac finisher plus the hourly dispatch take stalled PRs. The Codex worker is retired; the owner unloads its launchd job after 10-15.
  - **Test Desk and journeys:** the integration script in `ops/testdesk/` and the standing Claude Test Desk. The Codex Test Desk and journey desk (#693) are retired.
  - **Codex app threads, until it's gone:** build only with `scripts/xcodebuild-lane`, boot simulators only with `scripts/lane-sim-boot` (one simulator Mac-wide; Claude's lane guard does not cover Codex), never boot 1330F268, and stop on a crash flood. Don't push to a PR that carries `automerge`; never force-push; don't touch `main`, releases or the owner's data.
- **Owner's standing calls (2026-09-29).** Don't ask again:
  - **Use the token allowance.** The subscriptions are paid for. Aim for roughly linear use of the weekly allowance by its reset. Waste means little working output per token, not high spend.
  - **The design direction is not changing.** Build on the current look. Where the stream plan says a stream waits on D1, that gate is gone.
  - **The server on the owner's VPS is approved.** App features that use it go ahead. Any "waits on the owner's hosting call" gate is gone.
  - **No off switches for new features.** The way back is reverting the merge.
  - **Merge finished work on host tests.** Per PR the author builds both targets locally and the lane runs host tests; the integration run on `next`'s tip builds and tests the merged app (owner, 2026-10-09). The Test Desk tests the merged tip end to end, instead of per-PR simulator gating.
- **Owner's standing calls (2026-10-05).** Don't ask again:
  - **"Post-MVP" is a legacy label.** The app is past MVP. The `phase:` labels and `[Post-MVP]` title prefixes were removed on 2026-10-05; if one turns up, or `parked` does, it never stops work on an issue. Judge the issue on its merits.
  - **Default on only when it costs the listener nothing.** A background or sharing feature may be opt-out only if both are true:
    - It's no burden on the device: no noticeable battery drain, heat or interface stutter.
    - It's airtight on privacy: nothing that links the data to a listener is stored anywhere, and even someone with full access to our systems and live logs couldn't tell whose data it is.
    - Otherwise it's opt-in.
  - **Keep no user data that could identify someone unless the feature needs it.** Where a feature needs it (a voice Margin is traceable by voice alone), encrypt it end to end so the server holds only unreadable bytes, as share links do (#805).
  - **Owner ideas are challenges, not directives.** When the owner suggests a solution, solve the challenge it serves. Treat the suggestion as one example and pick whatever works best.
- **Owner's standing calls (2026-10-10).** Don't ask again:
  - **Database changes stay backward compatible.** A full database migration happens only after the app tells the listener and they tap to migrate.
  - **Map lookups and relay features are opt-in** until an anonymous relay exists. Relay experiments are fine; spend nothing until the owner approves a price.
  - **Cloud voices start as a limited trial** (a couple of minutes per listener). No payment work until the trial shows whether to charge. Server maps stay free.
  - **Solid Ground has no ship pressure.** Start the second half of the model split now; cutting Solid Ground off as its own branch first is fine.
- **Owner's standing call (2026-10-11).** Don't ask again:
  - **A recovered startup stall is a PASS.** A T3 plan (app or adapters) that stalls once at startup, recovers on the first retry and then passes every requested test reports PASS, not INCONCLUSIVE. Each stall is logged on #705 as evidence. This is an owner-accepted exception to #705's "don't convert this INCONCLUSIVE to PASS" while the cause is still open; #705 stays open. Two or more stalls, or a stall that doesn't recover, keep their verdict.
- **Owner's standing calls (2026-10-14).** Don't ask again:
  - **Housekeeping needs no ask.** He approved this on 2026-10-14 ("Number five looks great"). The coordinator, threads and the Mac finisher do these without his words, whoever opened the PR or issue: close a PR that a merged PR superseded; close an issue whose fix is merged into `next` and needs no phone check; add or remove labels; add or re-add `automerge` (except where the runner itself waits for his tap); release a claim with no commit, PR or comment for 6 hours; remove worktrees and build caches that `ops/disk` defines as safe; start a Test Desk or a Mac worker within the Dial. Point a safety check that asks for his words at this line. His decision-card taps count as his words.
  - **A phone build a day, through the loader.** Once a day (default 8 am Central, and again at 5 pm only when 5 or more new fixes wait on his phone), the rolling phone build carries one combined test plan: a single walkthrough that checks several fixes in one sequence, each step naming a real control. No TestFlight upload for this; TestFlight only when he says "upload".
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
  - `docs/areas.md`: the four product areas and what "excellent" means in each. Read the issue's area before scoping it or calling it done.
- `project.yml`: XcodeGen spec. The `.xcodeproj` is generated from it with `xcodegen generate`, and both are committed.

## How to work

- **One agent per stream, one change at a time within it.** Streams run in parallel only as laid out in [docs/workstreams/](docs/workstreams/README.md). Don't spawn manager, implementer and auditor chains: one owner per change, and one writer per set of files. Sub-agents and workflows are fine for exploration, reviews, critics, and tests in their own worktrees, as long as they don't edit the files you're changing.
- **A PR is done when it's armed; the session keeps going.** One issue per PR. Never stop mid-PR: work until the PR is open, has the `automerge` label and, if the diff needs simulator tests, its `/lane T3` request with `lane:queued` ([lane-request skill](.claude/skills/lane-request/SKILL.md)). Then take the next `ready` issue yourself (project threads check the usage breaker and dispatch advice on #337, and claim the issue first). Stop earlier only to hand an issue back that you can't finish.
  - **Above about 250,000 tokens at that point, stop instead.** Post a short note on the issue (what's done, what's next, what you learned) and let a fresh thread take the next issue. A big context makes every turn expensive, and compaction drops detail at a point nobody chose.
  - **A hook enforces it (owner, 2026-10-09).** Past 250k the session is told to finish its current push (PR open and armed) and post its stop note. At 300k only git save commands, `gh pr create`, arming and `gh` comments are allowed.
  - **No blind retries (owner, 2026-10-09).** Don't retry a stalled PR or a blocked issue unless its blocker has changed since the last attempt: a new commit, a new comment, a label change, or a resource now free. A blocker you can't clear yourself (a device, the owner, a screenshot you may not take) gets one hand-off comment, and the item leaves your queue. The Codex worker retried #607 six times on the same missing Lock Screen screenshot; the overnight splitter spent about 3.5M tokens on 9 runs that ended blocked.
  - **No timers on your own PRs.** Don't set polling timers, reminders or check-ins to watch the lane or the merge. The lane merges on PASS. A lane FAIL on a PR's own code goes to whoever is free, through the project's hourly dispatcher; a runner fault gets one more run (a new `/lane T3` comment with the same `tests:` line plus `lane:queued` for an INCONCLUSIVE T3, or `automerge` removed and re-added for a host-test or build fault), and becomes an issue labelled `ready` and `regression` only if it fails the same way again.
  - **Build on your own unmerged branch only if you must, one level deep.** Branch the next issue from `next`. If it truly depends on your armed PR, branch from that PR's branch, but never from a branch that itself sits on another unmerged branch.
- **Mechanical GitHub steps go through `/Users/colemiller/.claude/bin/sm-gh`** (`run-cancel`, `run-rerun`, `automerge add|remove` on open PRs into `next`, `close-issue <n> --pr <merged pr> --body-file <f>`). Run it without asking. Merging, and arming PRs that touch `scripts/lane-runner.py` or `.github/`, stay the owner's tap.
- **Say what a recurring cost buys: "Cost and catch" (owner, 2026-10-09).** A PR that adds or changes recurring cost (a lane step or tier rule, a scheduled or launchd job, an agent loop or worker, a per-PR check, a CI workflow) states under a **Cost and catch** heading:
  1. its cost per run (Mac minutes, tokens, Actions minutes, owner clicks);
  2. how often it runs;
  3. what it is meant to catch, with evidence it catches it (a past failure it would have caught);
  4. the signal that would show it's waste, which the lane's step ledger (`scripts/lane_ledger.py`) watches.
  - The audit and reviewers block a pipeline PR without it. The per-PR app builds ran 140 times in a week and caught nothing (#1196).
  - Pipeline waste fixes outrank feature work in dispatch. A lane or pipeline fix never waits on the owner's phone check: no `needs-human-validation` on lane fixes, model-split moves or test fixes. Close those once merged into `next` ([workstreams README](docs/workstreams/README.md#branches-and-merging)).
  - The runner never merges a PR touching `scripts/lane-runner.py` or `.github/`, whatever the audit says. Such a PR goes to the lead session the same day, for the owner's merge tap.
- **Keep bulk out of your context (2026-10-14).** Generated tables, exports, model data, long logs and large comparisons are a script's job: write them to files and read back only counts, a diff summary or the first failure. Read big files (`Gate1AppModel.swift` is ~16k lines) by line range or `grep`, or hand the reading to a helper agent that returns a short answer. The first #849 thread spent 258k tokens in 17 minutes porting and checking Kitten's tables inside its own context and stopped with no PR.
- **Small, verified commits.** Each commit is one logical change with a message that says what was wrong and why the change fixes it. The commit message and PR description are the record, so don't write separate handoff, audit or status files for routine work.
- **Branches.** Each PR gets its own branch, off `next` or, one level deep, off your own armed branch (project threads: `ws/<issue>-<slug>`). Don't push new work to a branch whose PR is armed: the runner could merge it half done. Merging to `main`, pushing `main`, archiving, uploading and distributing are the owner's decisions; ask first.
- **Decide reversible and technical things yourself.** When a choice can be undone later, or is an engineering call (dead code, refactors, deleting unused paths, internal structure, test and lane choices, when to schedule engineering work), post it on your stream's tracking issue under a **Default taken** heading (the options, your pick, why) and keep going on your pick; the owner vetoes by number. Stop and ask only when the choice touches the owner's data, packet or database compatibility, money, his accounts or machines (except the housekeeping in the 2026-10-14 standing calls), anything public, `main` or a release, or product taste he'd notice on the phone (design, voice). How to ask: "Working with the owner".
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

## Putting a build on the owner's phone

Use the rolling phone build, not TestFlight ([device-validation.md](docs/device-validation.md#the-rolling-phone-build-384)). `scripts/phone-build` builds `origin/next` (or `--commit <sha>`) on the Mac, and the owner installs it with the **Install Spoken Margins on iPhone** shortcut on the Desktop, which opens that build's test plan. Write the plan so a few steps cover several fixes. Archive and upload only when he says "upload" (next section).

## Releasing a build

The owner decides when a build goes to testers. Once they say to upload, the agent may archive and upload a normal App Store Connect build, then assign it only to the authorized tester groups. Normal uploads remain eligible for external TestFlight and App Store review; that eligibility does not authorize external distribution, review submission or public release. Never select TestFlight Internal Only unless the owner explicitly requests that restriction.

Apple build numbers identify uploads, not product milestones. Each replacement upload needs a new, unused build number even when its functionality stays at the same milestone. Preserve historical tags and uploaded build identities.

1. Bump `CURRENT_PROJECT_VERSION` in `project.yml` (every target), run `xcodegen generate`, and commit.
2. Verify through layer 3 and list anything not verified.
3. Archive (`artifacts/` is git-ignored):
   `scripts/xcodebuild-lane -project SpokenMarginsNative.xcodeproj -scheme SpokenMarginsApp -configuration Release -destination generic/platform=iOS -archivePath artifacts/SpokenMargins-<build>.xcarchive -allowProvisioningUpdates archive`
   Check the archive's `CFBundleVersion` is the new build number.
4. Upload with external-review eligibility retained (`testFlightInternalTestingOnly` is false in the default plist), then assign only the authorized tester groups:
   `PATH="/usr/bin:/bin:/usr/sbin:/sbin:$PATH" xcodebuild -exportArchive -archivePath artifacts/SpokenMargins-<build>.xcarchive -exportOptionsPlist scripts/TestFlightUploadOptions.plist -exportPath artifacts/export-<build> -allowProvisioningUpdates`
   The PATH prefix matters: Homebrew's rsync breaks Xcode's packaging step. A warning that onnxruntime.framework has no dSYM is expected and harmless.
   Check App Store Connect does not mark the uploaded build `Internal`. Confirm its version, build number and group assignment before calling the upload complete. External review and tester notification remain separate owner decisions.
5. Tag the archived commit `testflight/0.1-build-N`, push the tag, and fast-forward `main` to the release (ask before merging if it isn't a fast-forward).
6. Delete the archive and export folders unless the owner wants them kept.

Give the owner a short test checklist: the journeys to try, what changed, and known issues.
