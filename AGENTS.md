# Agent guide

Spoken Margins is a native iPhone/iPad listening app (iOS/iPadOS 26+). Listeners play articles, PDFs and podcasts, record spoken or written **Margins** anchored to the source, and share Margins as `.spokenmargins` packets that another listener can import and hear at the right place in their own copy. The owner is a systems engineer, not an iOS developer: explain trade-offs plainly and bring decisions, not options lists.

## Current focus

Replace this section when the focus changes; do not append to it.

- **Builds.** Build 30 (tag `testflight/0.1-build-30`, `07c6699`) is the last shipped build (internal TestFlight, 2026-10-08). Listening Baseline was repackaged without app-code changes as Apple build 32 (tag `testflight/0.1-build-32`, `ec940321`): Approved for external TestFlight, automatic tester notifications off. Build 31 was superseded before review (privacy declarations). The next upload must use a number above 32. `main` stays at Build 30; only the owner moves it.
- **Milestones have our own names** (owner, 2026-10-08), separate from Apple build numbers: `Listening Baseline` (milestone 2, formerly Build 30), `Solid Ground` (milestone 6, formerly Build 31), `Co-op Experience` (milestone 7, formerly Build 32). An extra upload uses a build number without advancing a milestone. Tags, compatibility checks and bug reports still use build numbers.
- **`next`** carries `Solid Ground` work on top of Build 30. It goes to testers only after it passes the owner's own use: "working means not being riddled with bugs."
- **Solid Ground (owner, 2026-10-08), until the owner accepts and ships it.** The owner can use the candidate the way they used Build 30 while the groundwork gets stronger: `Gate1AppModel` split into focused types, tests that passed without proving their claim made to prove it, and the pipeline's known faults fixed. The owner should notice builds arriving faster and the Test Desk catching bugs before their phone does. Scope is exactly the open issues in the milestone: model split slices, test honesty, lane and pipeline fixes, and bugs found on the owner's phone.
  - Threads and dispatch take `Solid Ground` issues first; other work waits in `Later` or has no milestone.
  - What joins it: a model split slice, a test-honesty finding, a lane or pipeline fault, or a `found-on-phone` bug. Any other new bug that would stop the owner using the build goes to them as a one-line question. Co-op and sharing work goes to `Co-op Experience`; everything else to `Later`.
  - No milestone freeze limits Claude threads' `automerge`. The Codex worker's scope is the Dial's **Codex focus** group (#589), which the owner sets.
- **Co-op Experience (owner, 2026-10-08): a fantastic co-op experience.** Starts only after the owner accepts and ships `Solid Ground`; a build-number bump alone doesn't start it. Co-op and sharing work (the F1 co-op items, share links and their encryption, co-op follow-ups) waits in that milestone.
- **How work flows.** Streams and briefs: [docs/workstreams/](docs/workstreams/README.md). Branch `ws/<id>-…` from `next`, one branch per PR, PRs into `next`. The Claude Code project hands out one thread per `ready` issue, dispatches lane results hourly, and triages new issues daily (21:30 Eastern). On the Mac, the lane runner merges the `automerge` PRs it passes, the Mac tick reports the machine and runner on #337 every two hours, a scheduled Codex audit reviews sharing, persistence, audio and lane PRs, and the standing Test Desk tests each new tip of `next`. There is no standing triage desk; who does what is in "The lead session" in [kickoff.md](docs/workstreams/kickoff.md).
- **Codex works beside Claude** (details in [ops/codex/README.md](ops/codex/README.md)).
  - The Codex worker first finishes stalled PRs, then takes `ready` issues, `priority` first, and opens `automerge` PRs into `next`. It skips `in-progress`, `where:mac`, `regression` and `blocked`, so file work for it as `ready` (plus `priority`, plus `bug` for failures).
  - The runner merges risky and lane PRs only after a Codex audit says "No blocking findings" on the head.
  - The Codex journey desk (a Codex app automation the owner set up, #693) runs hands-on journeys on the tip and reports on #184. The Codex Test Desk launchd job is retired.
  - Codex app threads: build only with `scripts/xcodebuild-lane`, boot simulators only with `scripts/lane-sim-boot` (one simulator Mac-wide; Claude's lane guard doesn't cover Codex), never boot 1330F268, stop on a crash flood. Don't push to a PR that carries `automerge`, never force-push, and don't touch `main`, releases or the owner's data.
- **Owner's standing calls.** Don't ask again.
  - **Use the token allowance.** Aim for roughly linear use of each weekly Claude and Codex allowance by its reset. Waste means little working output per token, not high spend.
  - **The design direction is not changing.** Build on the current look. The D1 gate in the stream plan is gone.
  - **The server on the owner's VPS is approved.** Features that use it go ahead; no "waits on the owner's hosting call" gate remains.
  - **No off switches for new features.** The way back is reverting the merge.
  - **Merge finished work on host tests plus both builds.** The Test Desk tests the merged tip end to end, instead of per-PR simulator gating.
  - **The app is past MVP.** "Post-MVP", `phase:` labels, `[Post-MVP]` title prefixes and `parked` are legacy and never stop work on an issue. Judge the issue on its merits.
  - **Default on only when it costs the listener nothing.** A background or sharing feature may be opt-out only if it's no burden on the device (no noticeable battery drain, heat or interface stutter) and airtight on privacy (nothing stored anywhere links the data to a listener, even for someone with full access to our systems and live logs). Otherwise it's opt-in.
  - **Keep no identifying user data unless the feature needs it.** Where it does (a voice Margin is traceable by voice alone), encrypt it end to end so the server holds only unreadable bytes, as share links do (#805).
  - **Owner ideas are challenges, not directives.** Solve the challenge the suggestion serves; treat the suggestion as one example and pick whatever works best.
- **Podcast anchors** continue as stream C4: [docs/podcast-anchor-plan.md](docs/podcast-anchor-plan.md).
- **Parked, reference only.** `park/co-op-2026-09-24` (failed co-op attempt plus in-progress anchor work; never merge it, port pieces by hand; its packets use a Margin kind this build can't read) and `codex/desktop` (macOS companion prototype). Why the repo was reset: [docs/repo-review-2026-09-24.md](docs/repo-review-2026-09-24.md).

## Repository map

- `App/SpokenMarginsApp/`: the iOS app. `Gate1AppModel.swift` (~16k lines) is the central model, `Gate1RootView.swift` the main view.
- `App/SharedSources/`, `App/*Extension*/`: code shared with the Safari, share and widget extensions.
- `Packages/SessionKit/`: domain logic, testable on macOS without a simulator: `SessionKit` (sessions, Margins, models), `SessionKitAudio` (playback adapters, podcast anchor evidence), `SessionKitPersistence` (SQLite store), `SessionKitSharing` (packets, import/export).
- `Contracts/`: JSON schemas, fixtures and product docs bundled with the app. `Contracts/docs/recovery-mvp.md` is the product boundary.
- `docs/`: durable product and architecture notes. `docs/archive/` is history, not instructions.
- `project.yml`: XcodeGen spec. Regenerate the committed `.xcodeproj` with `xcodegen generate`.

## How to work

- **One agent per stream, one change at a time within it,** as laid out in [docs/workstreams/](docs/workstreams/README.md). No manager, implementer and auditor chains: one owner per change, one writer per set of files. Sub-agents and workflows are fine for exploration, reviews, critics and tests in their own worktrees, as long as they don't edit your files.
- **A PR is done when it's armed; the session keeps going.** One issue per PR. Never stop mid-PR: work until the PR is open, has `automerge` and, if the diff needs simulator tests, its `/lane T3` request with `lane:queued` ([lane-request skill](.claude/skills/lane-request/SKILL.md)). Then take the next `ready` issue (project threads check the usage breaker and dispatch advice on #337, and claim the issue first). Stop earlier only to hand back an issue you can't finish.
  - **Above about 250,000 tokens at that point, stop instead.** Post a short note on the issue (done, next, learned) and let a fresh thread take the next issue. Big contexts make every turn expensive, and compaction drops detail at a point nobody chose.
  - **A hook enforces it (owner, 2026-10-09).** Past 250k the session is told to finish its current push (PR open and armed) and post its stop note. At 300k only git save commands, `gh pr create`, arming and `gh` comments are allowed.
  - **No blind retries (owner, 2026-10-09).** Don't retry a stalled PR or a blocked issue unless its blocker has changed since the last attempt: a new commit, a new comment, a label change, or a resource now free. A blocker you can't clear yourself (a device, the owner, a screenshot you may not take) gets one hand-off comment, and the item leaves your queue. The Codex worker retried #607 six times on the same missing Lock Screen screenshot; the overnight splitter spent about 3.5M tokens on 9 runs that ended blocked.
  - **No timers on your own PRs**: no polling, reminders or check-ins on the lane or the merge. The lane merges on PASS. A lane FAIL on a PR's own code goes to whoever is free through the hourly dispatcher. A runner fault gets one more run (an INCONCLUSIVE T3: a new `/lane T3` with the same `tests:` line plus `lane:queued`; a host-test or build fault: remove and re-add `automerge`), and becomes a `ready` + `regression` issue only if it fails the same way again.
  - **Branch the next issue from `next`.** Only if it truly depends on your armed PR, branch from that PR's branch, never from a branch that itself sits on another unmerged branch.
- **Mechanical GitHub steps go through `/Users/colemiller/.claude/bin/sm-gh`** (`run-cancel`, `run-rerun`, `automerge add|remove` on open PRs into `next`, `close-issue <n> --pr <merged pr> --body-file <f>`). Run it without asking. Merging, and arming PRs that touch `scripts/lane-runner.py` or `.github/`, stay the owner's tap.
- **Say what a recurring cost buys: "Cost and catch" (owner, 2026-10-09).** A PR that adds or changes recurring cost (a lane step or tier rule, a scheduled or launchd job, an agent loop or worker, a per-PR check, a CI workflow) states under a **Cost and catch** heading:
  1. its cost per run (Mac minutes, tokens, Actions minutes, owner clicks);
  2. how often it runs;
  3. what it is meant to catch, with evidence it catches it (a past failure it would have caught);
  4. the signal that would show it's waste, which the lane's step ledger (`scripts/lane_ledger.py`) watches.
  - The Codex audit and reviewers block a pipeline PR without it. The per-PR app builds ran 140 times in a week and caught nothing (#1196).
  - Pipeline waste fixes outrank feature work in dispatch. A lane or pipeline fix never waits on the owner's phone check: no `needs-human-validation` on lane fixes.
  - A PR touching `scripts/lane-runner.py` that the runner won't merge goes to the lead session the same day, for the owner's merge tap.
- **Small, verified commits.** One logical change each; the message says what was wrong and why the change fixes it. The commit message and PR description are the record: no separate handoff, audit or status files for routine work.
- **Branches.** Each PR gets its own branch (project threads: `ws/<issue>-<slug>`). Don't push new work to a branch whose PR is armed; the runner could merge it half done. Merging or pushing `main`, archiving, uploading and distributing are the owner's decisions; ask first.
- **Decide reversible things yourself.** Post the choice on your stream's tracking issue under **Default taken** (options, pick, why) and keep going; the owner vetoes by number. Stop and ask only for the owner's data, packet or database compatibility, money, anything public, `main` or a release, or taste (design, voice).
- **Don't grow `Gate1AppModel`.** New logic goes in a focused type, in SessionKit when it can be host-tested, called from the model. No new "should the source resume" flag or playback state machine.
- **Keep packets compatible.** Packets from a new build must import into the last shipped build unless the owner explicitly accepts a break. Require a new manifest capability only when the packet uses the feature.
- **Protect owner data.** Never reset, reseed or delete the owner's Library or recordings. Storage changes must let the previous build still open the database.
- **Keep evidence local.** `artifacts/` is git-ignored; test output, logs, screenshots and recordings stay there or on the external drive. Summarize results in the commit or PR.
- **Don't record instructions as documents.** Owner direction lives in the conversation, issues and this file's Current focus; don't append directive logs to docs.
- **Use GitHub issues** for bugs and features: one issue per problem, with steps, expected and actual behavior, and the build number.

## Verification

Tests that pass while the app is broken usually fake the boundary that broke: audio sessions, players, file paths across app containers, network responses. Verify in three layers; a lower layer never stands in for a higher one. Pick the lowest tier that covers your change from [test-lane.md](docs/workstreams/test-lane.md). Anything that boots a simulator (`--plan app`, journeys) goes through the test lane, not your session.

1. **Component tests (host).** The default loop: `.venv/bin/python scripts/verify-tests.py --plan fast` (SessionKit, contract validators, browser suites). In a new worktree run `scripts/setup-worktree.sh` once first; it links the main checkout's `.venv` and `node_modules`.
   - Write tests that can fail for the bug they name; run a new regression test once without the fix and see it fail.
   - For a matching, sanitizing or page/title parsing bug, first write a table of neighbouring inputs (case, whitespace, Unicode normalization, punctuation, empty, very long, the same item from another source, lookalikes) and fix every failing row in the same commit.
   - Prefer real temporary files, real SQLite and real AVFoundation decoding on macOS over hand-written fakes at the boundary under test.
2. **App compile and app-hosted tests.** Every app change builds for simulator and device:
   - `scripts/xcodebuild-lane -project SpokenMarginsNative.xcodeproj -scheme SpokenMarginsApp -destination 'generic/platform=iOS Simulator' build-for-testing`
   - `scripts/xcodebuild-lane -project SpokenMarginsNative.xcodeproj -scheme SpokenMarginsApp -destination 'generic/platform=iOS' build`
   - The wrapper takes xcodebuild's arguments, waits for one of two Mac-wide build slots and uses this worktree's `.build/dd`; a hook blocks raw `xcodebuild` builds. After switching branches use a fresh `-derivedDataPath` (stale SessionKit modules give false "does not conform" errors).
   - App orchestration changes: `--plan app` (app-hosted XCTest) in its own `SpokenMargins Test Runner` simulator, never the journey one. If it stalls before XCTest connects, report it; don't retry in a loop.
3. **Journeys.** Before calling anything ready, run the affected journeys in [docs/journeys.md](docs/journeys.md) against the built app, driving the simulator with real taps and screenshots and reporting what you saw at each step (clocks advancing, which item or Margin plays). An agent can't hear audio: audible content, Bluetooth, the Lock Screen and background behavior belong to the owner's pass on a physical device.

`--plan ui`, `speech-canary` and `release` are retired from routine use; use journeys. **Scripted journeys** (owner, 2026-09-30) run only in the Test Desk's integration run on `next`'s merged tip, never as a per-PR gate or by a stream session. A thread that changes a listener's flow may add or update the journey's script and names that journey in the PR. Compile, probation and coverage rules: "Scripted journeys" in [test-lane.md](docs/workstreams/test-lane.md); how to write one: "Writing scripted journeys" in [docs/journeys.md](docs/journeys.md).

**Simulator crashes.** Three or more crashes of one process within a minute is a flood: stop, shut that simulator down and report. Don't reboot in a loop or switch devices to get around it. A lone crash: note it, continue, and mention it in the report. `verify-tests.py` applies the same rule.

**Status words:** `implemented` (code exists), `verified` (tests and builds pass and the agent ran the journeys), `human_validated` (the owner used it on a device and accepted it; only the owner sets it).

## Releasing a build

The owner decides when a build goes to testers. Once they say to upload, follow "Archive and upload" in [ops/release/README.md](ops/release/README.md). Never select TestFlight Internal Only unless the owner asks; an upload's review eligibility doesn't authorize external distribution, review submission or public release. Each upload takes a new, unused build number; keep historical tags and build identities. Give the owner a short test checklist: journeys to try, what changed, known issues.
