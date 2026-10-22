# Test lane: sharing one Mac between many streams

The Mac is the bottleneck. It is the only place that can build the app, boot simulators and drive journeys, and it can't run many simulators at once. The test lane is how streams share it, and the test tiers below are how streams avoid testing more than a change needs.

This page is the contract. Stream A1 (`lane`) builds the machinery behind it.

## Tiers: test what the change could have broken

Pick the **lowest tier that exercises what the diff could break**, and run it once. A tier doesn't include the tiers below it unless the row says so.

| Tier | What runs | Where | Typical cost | Use it for |
| --- | --- | --- | --- | --- |
| **T0** | Nothing, or a doc/link check | anywhere | 0 | Docs, research notes, charters |
| **T1** | The tests for the touched module only: `swift test --filter <Suite>` for SessionKit, or the stream's own Python/Node/server suite | Mac host; or Linux for `SessionKitCoreTests` (Core, Persistence, AI, EPUB, Feeds): `scripts/run-sessionkit-linux-tests.sh`, also run on every PR into `main` by `linux-t1.yml` | 1–3 min | Pure logic: parsers, ranking, packet merge, text cleanup, resolvers; the share-link and map-upload server and the research code with tests (`research/B4`, `B2`, `D3`, `C1/tools`) |
| **T2** | Compile the app for simulator **and** device (the two `xcodebuild` commands in `AGENTS.md`), no simulator boot | Mac, build semaphore | 4–10 min | Any change to `App/`, `project.yml`, or a SessionKit public API |
| **T3** | Targeted app-hosted XCTest (`-only-testing:` the touched test classes) in the Test Runner simulator | Mac, via the lane | 5–15 min | App orchestration: model/coordinator wiring, persistence through the app |
| **T4** | Named journeys from `docs/journeys.md`, or a one-off scenario the request spells out, driven with real taps and screenshots | Mac, via the lane (Test Desk) | 10–40 min each | A one-off scenario a PR asks for; the named journeys run in the integration run |
| **T5** | Full regression: `--plan fast`, `--plan app`, every journey | Mac, via the lane | 1–3 h | The integration run on `main`'s merged tip (see Three test levels) |
| **T6** | Owner on the phone | owner | owner time | Audible content, Bluetooth, Lock Screen, background, thermal. Batched per TestFlight build |

**Three test levels** (owner's decision, 2026-09-29). These replace per-milestone T3 and T4 and "T5 once per candidate":

1. **Per PR:** the author builds both targets locally before pushing (`AGENTS.md`, layer 2), and the lane runs host tests (`--plan fast`) before merge, with no app build (owner, 2026-10-09). T3 only for audio session, storage and packet changes.
2. **Per batch:** the integration run on `main`'s merged tip, which builds the merged app, so a compile break from combined PRs shows there within minutes: `--plan app`, a screen tour for the critics, the scripted journeys (below), and every journey on a library shaped like the owner's and upgraded from Build 29. The standing Test Desk runs it on each new tip (Starting the Test Desk). A real failure is reverted first: the desk opens a "Revert #N" PR for the culprit merge and files a `ready` + `regression` issue to re-land the change. Persistence, migration, packet-format and lane changes aren't reverted; the desk reports those to the owner on #184.
3. **Per candidate:** the owner's phone. The latest green integration run is the candidate.

**Rules of thumb**

- A change you could describe in one sentence, in one module, with a test that fails without it, stops at **T1**, or **T2** if it touched the app.
- Most PRs stop at T1 or T2. T3 per PR only for the escalations below; T4 per PR only for a one-off scenario the PR needs. Journeys and full regression run on the merged tip, not per PR or per milestone.
- **Escalate one tier** for anything touching the audio session, players, playback state, persistence/migrations, or packet import/export. These are where Build 28 → co-op went wrong.
- **Never escalate to T5 on a stream branch.** Full regression runs on `main`'s merged tip, in the integration run.
- A new regression test must be run once **without** the fix and seen to fail (`AGENTS.md`). That run counts as T1, not an extra tier.
- **A change to the lane's own cost** (a new step, tier rule or per-PR check) states its "Cost and catch" in the PR (`AGENTS.md`): cost per run, how often, what it catches with evidence, and the waste signal the step ledger watches. The audit blocks it without one.
- When unsure, ask the lane for the tier (A1 ships `scripts/test-scope.py`, which maps a diff to its minimum tier and suggested test filters). If the tool and your judgment disagree, take the higher tier and say why in the request.
- **On-device transcription is not checked in the simulator (#1522).** `SpeechTranscriber.isAvailable` is false in the iOS Simulator and its supported-locale list is empty (Apple Developer Forums threads 802969 and 806765), so "Failed to initialize recognizer" there is the runtime, not the app, and not a permission problem. App tests fake the transcriber. The real one is checked on the host by `RealSpeechTranscriberTests` in SessionKitTests (it synthesizes a clip with `say` and expects the words back; it skips with a reason if the Mac has no speech model). Don't mark a simulator transcription stall a regression; sound quality on a real phone stays the owner's check.

## Scripted journeys

Scripted journeys are UI tests in `App/SpokenMarginsAppUITests/` that each follow one journey from `docs/journeys.md` (owner's decision, 2026-09-30, #445). Threads draft them, the Test Desk proves them, and they count only after probation.

- **Where they run.** Only in the integration run on `main`'s merged tip, never as a per-PR gate. Per PR, a script only has to compile: `scripts/test-scope.py` puts `App/SpokenMarginsAppUITests/` at T2 and never adds its classes to a T3 request.
- **Who writes them.** A thread that changes a listener's flow may add or update the script for the journey it affects, and names that journey in the PR.
- **Probation.** `TestPlans/scripted-journeys.json` is the one list the integration run reads. A new or changed script goes under `probation` in the same PR. It runs and is reported, but can't turn the integration run red. The integration script counts each script's passes and bad runs in its state file and names the scripts that are due in its report (`journeys due to move:`); `ops/testdesk/journey_promotion.py --apply` then moves them in the listing, and the Test Desk opens that PR into main. A script moves to `gating` after two passing runs in a row, and back to `probation` after two bad runs in a row. `scripts/test_inventory.py` rejects an entry that names no real UI test or no journey.
- **What they don't cover.** Audible content, the Lock Screen, Bluetooth, and anything that only looks wrong. Agent-driven journeys and the owner's phone keep those.
- **How this differs from the retired plans.** `--plan ui`, `speech-canary` and `release` ran a broad route suite as a gate and stay retired (`AGENTS.md`). Scripted journeys are one short script per journey, each earning its place on probation.

A week after the first script gates, the desk's daily hand-off on #184 counts two things: regressions a script caught that the owner would otherwise have found on the phone, and simulator crashes or flakes the scripts caused. If the scripts caught nothing, or cost more desk time than they saved, that is the sign this was a mistake.

## The lane

**Endpoint A1 must reach.** Any stream, cloud or Mac, can request T2–T5 against a pushed commit without the owner doing anything, and gets a report on its PR. The Mac never runs more than **one** simulator job at a time (it has 16 GB; two simulators plus builds filled swap, #184). It never runs more than **two** `xcodebuild` invocations at once *in total*, and only one while a simulator job runs: one Mac-wide semaphore shared by the lane and every stream session. A crash flood stops the lane and notifies the owner.

**Recommended shape** (A1 may change it if the endpoint holds):

- **Intake is the PR.** A stream opens a draft PR into `main` and comments a request (format below) with the label `lane:queued`. Mac streams may also message the Test Desk session directly as a doorbell, but the request itself always lives on the PR so the owner can see it from the phone.
- **Deterministic tiers run without an agent.** A self-hosted GitHub Actions runner on the Mac, with a single concurrency group, runs T2 and T3 (and T1 for Swift) and posts the result. Cheap, repeatable, no tokens.
- **Journeys run with an agent.** The standing Test Desk session on the Mac runs in a loop on `main`'s tip, works in its own worktrees and DerivedData, drives the simulator, and posts its reports on #184. It runs a one-off scenario for a PR only when the owner or the coordinator asks it directly.
- **Lane open ping.** When a lane or automerge job ends and a lane runner is left idle with no queued Mac job to take it, the last jobs of `lane.yml` (`lane-open-lane` and `lane-open-automerge`, on the VPS) sends `Lane open-<UTC time>: <free> free, <queued> queued` to the coordinator through the Dial relay, at most once per 10 minutes (`ops/lane/README.md`, #1215). The coordinator then fills the slot and clears "waiting on you" and idle threads. It sends nothing until the owner sets the two secrets.
- **Coalesce.** If a newer commit lands on the same PR while a request is queued, test the newest only. Identical requests against the same commit run once.
- **Order.** Gate streams (A2 `seams`, anything blocking others) first, then oldest request first.
- **Evidence stays local.** Screenshots and logs go under `artifacts/lane/<request-id>/` (git-ignored). The request id is `pr<PR>-r<run id>`, plus `-a<N>` when a job is re-run, so a re-run never reuses a folder. The PR comment carries the observations and file paths, not images.

The Test Desk drives the simulator with the iOS simulator tool (`mcp__Claude_Code_iOS_Simulator__control`), never with computer use, Device Hub or Simulator.app; it works with this repo's Xcode 27 (Build 34 baseline, 2026-10-16). Each journey runs in a helper agent of its own: see the journey skill, Driving.

## Guard rails (deterministic, not advisory)

- **Only the lane boots simulators.** A1 installs a `PreToolUse` hook in the Mac's **user-level** settings (`~/.claude/settings.json`), so it applies to every session whatever branch it started on. It blocks `xcrun simctl boot|install|launch`, `xcodebuild test`, and `verify-tests.py --plan app|adapters|ui|release` unless the session is the Test Desk. Stream agents then *can't* start a simulator flood by accident. `AGENTS.md` sends `--plan app` through the lane for this reason.
- **Build semaphore.** Every `xcodebuild` on the Mac, from streams and from the lane, goes through one wrapper that allows two at a time and queues the rest.
- **Host-test slots.** Every `verify-tests.py --plan fast` run holds one of two Mac-wide host-test slots, or the one slot while a simulator job runs. So does a full `swift test` through `scripts/host-test-lane swift test`, and `run-sessionkit-tests.sh` uses it. They are separate from the build slots. Single-suite `swift test --filter` runs stay ungated: after the first build they are incremental and short. Three ungated runs at once pushed the load to 471 (#350).
- **Fresh DerivedData per worktree** (`AGENTS.md`: stale SessionKit modules give false "does not conform" errors).
- **Crash-flood rule** as in `AGENTS.md`: three crashes of one process within a minute stops the lane, shuts that simulator down and notifies the owner. A lone crash is noted in the report and work continues.

## Request format

Post as a PR comment. Keep it short; the Test Desk needs intent, not narrative.

**A finished PR needs no request comment.** Label it `automerge` when its "Done when" is met. The runner then runs what the diff needs, by the base branch's `scripts/test-scope.py`, and runs again on every push while the label stays:
- T0 (docs and research notes): nothing.
- T1: `--plan fast`. Besides `scripts/tests`, it runs the tests in each `ops/` folder (`ops/dial`, and `ops/codex` once it has tests), so a diff that only touches `ops/` stops here, with no app build. It also runs `scripts/research_tests.py` (`go test` for `research/B4/server`, the research Python tests that run without heavy packages, and the Caddy privacy-filter script), so a diff that only touches that code stops here too. A suite the machine can't run (no `go` on PATH, a bash without `mapfile`, a missing Python package) is listed as skipped with its reason in the PASS report, not passed (#1033).
- T2 or higher: `--plan fast` only. 140 runs in a week (10-02 to 10-09) built both targets per PR and caught no compile failure, so the lane no longer builds the app per PR (owner, 2026-10-09). An explicit `/lane T2` request still builds both.
- Split per PR (#2160): `linux-t1.yml` runs `--plan fast-portable` (`vps fast: portable`) and SessionKitCoreTests on Linux (`sessionkit-core`) on the VPS runner `sm-vps-t1`. When both passed on the PR's head and recorded the same merge tree, the automerge run on the Mac runs only `--plan fast-mac-rest` (the Apple-tool runner tests, `ops/disk`, SessionKitTests and SessionKitTraceTests); otherwise the whole `--plan fast`. The report names which. Once the repo is public, the GitHub-hosted pair in `hosted-portable.yml` takes priority (`LANE_HOSTED_FAST`).
- **SessionKit tests are skipped when this exact tree already passed them** (#1328). A passing run records a key on its Mac: a digest of the package, everything its tests read from the repository (`Contracts/`, the app sources and app tests its source-scraping tests open, `research/B2`, `research/B4`, the catalog, `traces/`; the list is `READS` in `scripts/sessionkit_pass.py`, and a test fails if the Swift tests name a path outside it), the Swift toolchain, and the test runner's own scripts. A lane run (the only one given the PR's changed paths) with the same key skips the SessionKit build and tests, and its PASS says so. Any change to an input, or no record on that Mac, runs them. Runs without the changed-paths list (a session's own run, the release candidate's) never skip. A record older than 24 hours is not honored, so each Mac runs the whole package at least daily: the Test Desk's scheduled run on `main` is `--plan app` and never runs these tests, so that daily run is what bounds how long an input missing from the list could hide. When they do run, `SessionKitCoreTests` run with `swift test --parallel` (4 workers) and the real-time AVFoundation targets run serially; a parallel run that fails for any reason is run again serially and that result decides, and the PASS report notes it.

When the host tests fail, the runner re-runs just the failing tests (SessionKit, `scripts/tests` or an `ops/` folder) on the plain `main` commit the PR was merged with, in the same job, within 10 minutes (#1204). If they fail there too, the report is INCONCLUSIVE ("fails on next `<sha7>` too: not this PR"), and each such test gets an issue labelled `ready,priority,bug,regression` in "Solid Ground", or a comment on the open issue already named after it. If any of them passes on `main` or doesn't exist there, the FAIL stands. A failure no test name explains (a crash, a timeout, a contracts check) stays FAIL. While the Mac has no sound output (#909), real-player tests aren't filed as broken on `main`.

Simulator tests (T3) still need a request. The lane check is red only on FAIL, so a project thread wakes for a failure in its own code. INCONCLUSIVE leaves the check green with a warning: read the report, not the check mark. A job that stops before it reports is red too.

Every lane job that posts a report and doesn't merge the PR, T2, T3 or automerge, ends by removing and re-adding `lane:done`, after its last report (the released automerge run's, when a T3 PASS starts one). Each job then makes a new `labeled` event, which is what the Hourly dispatch wakes on. An automerge run leaves `lane:queued` and `lane:running` alone.

A PR with a T3 request merges only on a T3 PASS (#410). While its newest T3 report is FAIL or INCONCLUSIVE, or its newest T3 request has no report yet, the automerge run reports FAIL or INCONCLUSIVE and doesn't merge, even when its own checks pass. A FAIL on an earlier commit holds later commits too, until a newer T3 passes. When a T3 then passes on the PR's current head, the lane job that reports it runs the held automerge run itself, in the same job (#421), and posts its report as `<id>-auto`; nobody needs to push or re-label. It runs there because a label the runner re-added with the workflow's token would start no new run.

While a `/lane T3` request whose `commit:` names the PR's head is still waiting (`lane:queued` or `lane:running`, no report yet), where the automerge run lands decides what it does (#834):

- On the build runner (`SM_LANE_RUNNER_ROLE=build`), it runs its host tests under the build runner's room rules, so the T3 needn't wait for them. If they pass, it reports INCONCLUSIVE, held for T3, and the report carries a hidden `<!-- lane-checks: … -->` line naming the `main` they passed with. When the T3 then passes, the lane job on the simulator runner merges without running them again if `main`'s commits since touch none of the PR's files and no build inputs its checks read (the same rule as a refused push), and its merge check says it wasn't re-tested. Otherwise it tests the merge commit again first. It trusts only the newest automerge report on the head, posted by the runner itself.
- On any other runner it skips them and reports held straight away, as before: the T3 PASS then has them run on the merge commit before it merges. When the build runner's checks don't finish (no room, a timeout, a lane error), its report is held the same way, and still counts as a runner fault for the auto-revert.
- **When the checks have to run after a T3 PASS** (none passed, or `main` moved in ways that matter), the lane job on the simulator runner doesn't run them itself (#1209). It dispatches `lane.yml` on the base branch (`workflow_dispatch`, which, unlike a label change, starts a run from the workflow's token), posts a note starting "Lane: the automerge run held for T3 on `<sha7>` goes to the build runner", and moves on to the next T3. The `release` job then runs on a build runner under the build runner's room rules, tests the merge commit and merges on PASS; its report follows on the PR, and like any job that reports without merging, it re-adds `lane:done`. It re-reads the PR first, and again after its room wait, so a dispatch for a PR that moved on, closed, lost `automerge` or is no longer held does nothing. Its check sits on `main`'s tip rather than on the PR, so it stays green with a warning even on FAIL: the report and `lane:done` carry the verdict. A release run that starts but stops before reporting (a failed checkout or LFS fetch, a cancel, a timeout) posts "the automerge run stopped before reporting" and re-adds `lane:done` from a last step that needs only `gh`, not the checkout (#1542). A release run that never starts (cancelled or timed out in the queue) can post nothing, so the hand-off note names a time three hours on: if neither a report nor a stopped note is on the PR by then, and no `lane` run named `pr=<N> head=<sha>` is still queued or running, the hourly dispatcher removes and re-adds `automerge` once. With no room, it reports INCONCLUSIVE (a runner fault): remove and re-add `automerge`. If the dispatch itself fails (a PR whose merge ref predates the release job, or GitHub refuses), the lane job runs the checks as before. Nobody needs to push or re-label.

A T3 request for an older head, or one with no `commit:` line, doesn't count, so a push after the request still gets the automerge checks.

The audit hold works the same way (#1461). An audio, persistence, packet or lane PR whose automerge run passed its checks but waits for an audit reports PASS with `not merged by the runner: …`, and that report carries the same hidden `<!-- lane-checks: … -->` line. When the audit script re-arms `automerge` after a clean audit, the new run merges on that PASS without running the checks again, unless `main`'s commits since touch the PR's files or a build input its checks read. Its merge check says "Reuses the earlier PASS" and links the run it reuses, and its report names the `main` the checks ran with. A run that only reuses waits for no host-test room. A newer report, a different head or a report not posted by the runner brings the checks back.

A T3 run covers at least the app test classes the diff calls for. The runner adds every class the base branch's `scripts/test-scope.py` suggests for the PR's diff to the request's `tests:`, and the report lists what it added, with the test count and how long each plan took. A method you name inside an added class runs with its class. A diff touching `Gate1AppModel.swift` therefore runs all of `Gate1AppModelWorkflowTests` (151 tests), about 15 minutes with the boot.

Before any build, the runner checks the hot-file ratchet (`scripts/hot_file_ratchet.py`). A PR may not grow `Gate1AppModel.swift` or `Gate1RootView.swift` above the smallest size each has had on `main` since the ratchet started. Move lines out, or ask the desk for the `hot-file-ok` label. `verify-tests.py --plan fast` runs it as its first step against your local `origin/main` (#2175), so an author sees a ratchet FAIL before pushing.

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
tokens: J1 41k (9 screenshots), J7 38k (12) · desk 95k at the end
```

The `tokens:` line gives each journey's helper `subagent_tokens` (from the Agent tool's usage line) and its screenshot count, and the lead desk's context when it posts, so the cost per journey can be compared across desks.

`INCONCLUSIVE` is not a pass: no simulator available, XCTest never connected, a flood stopped the run. Say which.

## Starting the Test Desk

The Test Desk is a standing Claude Code session opened on the `spoken-margins-native-test-desk` folder, which sits next to the repo checkout (a git worktree). The lane guard lets only that session boot simulators. It runs as a loop and compacts itself at 300,000 tokens; after a compaction, its SessionStart hook prints this section, so this section is the desk's rulebook. Restart it from this prompt only when it starts contradicting what's recorded here or on #184, so that no rule lives only in a session's context.

```text
You are the Test Desk for Spoken Margins: the only session on this Mac allowed to boot
simulators. You run as a standing loop. Read AGENTS.md, docs/workstreams/test-lane.md,
docs/journeys.md, the journey and lane-request skills in .claude/skills/, and the last few
comments on #184, starting with the newest "Test Desk hand-off".

Setup: this folder is a worktree. Run git fetch origin && git switch --detach origin/main,
then scripts/setup-worktree.sh. Never create branches here. Build each job in a worktree of
its own: .claude/worktrees/lane-integration-<sha7> for main's tip, and lane-build29 (kept)
for Build 29. The understudy's worktrees are intrun-<sha7>; never touch them, and it never
touches yours. Build through scripts/xcodebuild-lane. A test run there, or a verify-tests
test step, that prints its final summary and then goes quiet for 2 minutes is stopped and
reports its tests' result with a "(forced, #2053)" note; don't kill it by hand.

What wakes you: main's tip moving. Check #184 and main about every 45 minutes (waits of 20 s
or less at a time, or a background wait: a foreground sleep of 30 s or more is blocked).
When main's tip has no integration report on #184, run one job on that tip, in this order:
1. The app tests: take a pool device (below), then
   scripts/verify-tests.py --plan app --device <udid>. Post "Lane report
   integration-<sha7> — PASS | FAIL | INCONCLUSIVE" on #184, with the line
   "run by: Test Desk".
2. Only after a PASS: the screen tour, if the repo has one, then the scripted journeys in
   TestPlans/scripted-journeys.json (gating, then probation). They launch with --ui-testing,
   which resets the app's library, so they run before step 3 builds the journey library. A
   probation failure goes in the report but doesn't make it FAIL. Move a script to gating
   after two passes, and back to probation after two bad runs, in a PR into main
   (ops/testdesk/journey_promotion.py). Run them
   with scripts/verify-tests.py --plan journeys --device <udid>; its manifest's gating and
   probation maps give each script's result.
3. Then the journeys in docs/journeys.md. Finish the app tests' device with --done and take one
   again first (it comes back erased, because the app tests wrote to its app data), and build a library shaped like the owner's and upgraded
   from Build 29 (lane-build29) before installing the candidate over it. Post
   "Lane report journeys-<sha7> — …" on #184.
How to run journeys: you are the lead. Build or reuse the app once, take the pool device and
install once, then give each journey to one helper agent (Agent tool, one at a time) with its
steps, the UDID and the app path; it answers in about 150 words. Drive with the iOS simulator
tool only, never computer use, Device Hub or Simulator.app. Screenshots at half scale, zoom
only for small text, full size only as FAIL evidence, about 15 per journey. The brief and the
budget are in the journey skill (Driving, Screenshot budget). Send verify-tests.py and
desk-batch.py output to files and read back only counts. Each report carries a tokens: line.
A tip that lands mid-job waits for the next job. If the understudy has already posted the
integration report for a tip, start that tip at step 2.

Taking turns: the scheduled "SM integration run" is the understudy. It runs only when this
desk has posted nothing on #184 for three hours, works in its own intrun-<sha7> worktree,
and stays off the simulator while a desk pool device is booted.

The integration script (ops/testdesk/README.md, launchd every 10 minutes) replaces the
scheduled understudy once installed. It runs --plan app on any tip with no integration
report on #184 when the Mac has room, letting waiting /lane T3+ requests go first unless
next has gone three hours untested. It re-runs failing tests twice to rule out a flake,
and calls Claude read-only only on a confirmed FAIL. Its reports say "run by: integration
script". Like the understudy, it skips a tip this desk has already reported.

Before the understudy starts inference, its `UserPromptSubmit` hook runs
`/usr/bin/python3 ~/SpokenMarginsOps/repo/scripts/integration-precheck.py --claude-hook`.
It blocks an unchanged task before the model processes its prompt. The normal CLI
prints `GO` or `STOP: ...`. `GO` means a new tip or new owner/Test Desk context
or `/integration-retry` request remains to handle, under the three-hour rule.
Git/GitHub/state errors give `GO`, preserving the existing fallback. The precheck
posts at most one blocker note on #337 per reported INCONCLUSIVE blocker; its
state is in `~/SpokenMarginsOps/integration-precheck/`. Routine Mac ticks, skip
notes and its own note do not wake it, even though they share the owner's account.
`--dry-run` fetches/reads current data but saves and posts nothing. On a hook `GO`,
the model receives the decision as context and must not call the CLI again: that
would consume its already claimed launch and incorrectly stop the fresh run.

After merge, pull the ops checkout and merge this entry into the owner's existing
`~/.claude/settings.json` hooks, preserving its `PreToolUse` lane guard:

```json
{
  "UserPromptSubmit": [{
    "hooks": [{
      "type": "command",
      "command": "/usr/bin/python3 ~/SpokenMarginsOps/repo/scripts/integration-precheck.py --claude-hook",
      "timeout": 630
    }]
  }]
}
```

Prepend this one line to the scheduled task's prompt (outside this repo):

```text
[SM-INTEGRATION-PRECHECK] Use the UserPromptSubmit gate's GO/STOP for tip/retry and Test Desk turn-taking; do not rerun it, and retain the remaining safety guards and procedure.
```

The hook also recognizes the stored task's existing exact introductory line,
so it can guard that task before the marker is added. Other tasks and manual
follow-up prompts pass untouched. The issue's three-hour comment gate replaces
the older stored task's 75-minute session-activity rule; the standing Test Desk's
own loop is unchanged. A Desktop shell/session entry may still be created, but
the blocked prompt consumes no model turn. A prompt instruction alone does not
provide that guarantee. See the [Claude hooks reference](https://code.claude.com/docs/en/hooks).

A real FAIL: first rule out a flake (run the failing tests again, twice) and a lane fault
(no test ran, a missing VFS overlay or XCFramework, a boot that failed). Then find the
culprit merge, open a revert PR titled "Revert #N" into main with the automerge label, and
file the re-land issue, labeled ready and regression. Don't revert persistence, migration
or packet-format changes, or lane changes: report those on #184 for the owner.

Per-PR /lane requests are not your queue: the runner answers T2 and T3, and journeys run
on main's tip. Run a one-off scenario for a PR only when the owner or the coordinator asks
this session for it directly, on a pool device between jobs, and post its report on
that PR. A work list from scripts/desk-batch.py (Batching T4 requests) is that ask: take its
checks in order, on one build and one pool device.

Simulators:
- The desk uses a pool of up to three devices named "SM Lane Desk pool 1" to "pool 3" (iOS 26.5).
  The owner approves each one once in the simulator panel, and the approval survives an erase, so
  the desk reuses a device instead of creating one per run (#688).
    UDID=$(scripts/lane-sim-boot --pool)
  takes the least recently used free device, erases it, boots it under the lane's boot rules and
  prints its UDID. It creates a device only when none is free and the pool has room: the owner
  approves that new device the first time the desk drives it, so say so on #184 and take the
  first run when they are awake. When the job ends:
    scripts/lane-sim-boot --done "$UDID"
  (once) stops the watcher first, so the shutdown isn't read as a SpringBoard crash, then shuts the
  device down, erases it and keeps it in the pool. A device no run holds is left alone, but a
  device another run has taken since is not: don't repeat --done. The pool is recorded in
  desk-simulator-pool.json in the lane state folder.
- **Settle before the host app launches (#705).** The app and adapters plans of `scripts/verify-tests.py` don't launch `SpokenMarginsApp` until the simulator has been quiet for 20 s, counted from when its boot finished (`lane_sim.boot` marks it) or its last app-hosted test run ended. The marker is `simulator-quiet/<udid>` in the lane state folder, pruned after a day; a device nobody marked (booted by hand) waits 0 s. The manifest's `settle_before_tests` records the seconds quiet and the seconds waited (usually 0 or a few). Why: on 2026-10-14, 18 of the 20 app-plan stalls in the lane's artifacts launched the host app 1-16 s after the boot finished (median 5 s), while runs that didn't stall launched no earlier than about 8 s after, and an adapters plan that began 8 s or less after the app plan ended on the same simulator stalled in 18 of 46 runs (2 of 57 later). The cause inside Xcode or the simulator is not known. Check that it worked from later reports: stalls of an adapters plan that follows an app plan, and of an app plan on a fresh simulator, should become rare. A stall that still happens after a settle is new evidence; the stall folder's `sample-*.txt` is where to read it. The settle is not a fix for #705: the issue stays open, and the lane keeps logging each stall there, until stalls have at least halved and the boundary inside Xcode is named.
  - **Measured (2026-10-15).** In the lane's artifacts, from 2026-10-12 to the settle's merge (04:45Z, 10-15), 44 of 230 app and adapters plans stalled at least once (22 of 185 app, 22 of 45 adapters). In the first 30 plans after it, 1 stalled (1 of 27 app, 0 of 3 adapters). That stall had settled 20 s, so the settle narrows the window but does not close it. The samples are small, adapters especially; keep counting.
  - **The boundary (#705, 2026-10-15).** Of the 40 stalled result bundles kept on the Mac, the 26 with a running host app were all xcodebuild's own launch: the pid in its session log's "Launched app … (pid = N)" was the sampled pid, so nothing else launched the app first. In pr1647-r38684087699 that launch asked for `DYLD_INSERT_LIBRARIES` and the app started 45 ms after "Launching app", yet none of those libraries were loaded (the #1161 read found the same in 19 of 32 folders). Our inference: the simulator's launch of that very process lost its settings. The other 14 stalled attempts never got a process: the session log ends at "Launching app" (10), "Installing app" (2), "Installed app" (1) or is empty (1). Both are in the simulator's launch of the host app, below our code. Each stall now records `session_last_step` and `launched_pid`, and its diagnosis says whether it sampled xcodebuild's own launch.
- A device is retired only by the lane's stop rules: one that failed a boot ("Invalid argument"
  and any other failed boot), crashed, or showed a SpringBoard crash is marked unsafe. The next
  --pool deletes it, drops it from the pool and, if no other device is free, creates a
  replacement (the guard blocks --done on a device marked unsafe). Never retry a failed boot, and
  never boot a device marked unsafe. If the watcher marks a device unsafe after the boot (a late
  crash report), it keeps running and holds its simulator slot: `xcrun simctl shutdown <udid>`,
  wait until the watcher has exited (`ps -p $(cat ~/Library/Caches/SpokenMarginsLane/watch-<udid>.pid)` lists no
  process; the file stays behind, so don't wait for it to go), and the next --pool deletes it. A device that only fails
  to erase stays in the pool and is passed over; the helper prints STOP only when no pool device will erase, so report that on #184.
- **One fresh device after a boot stall (#1802).** A boot stall is SpringBoard restarting or vanishing while the
  device boots, with no crash report. From 10-09 to 10-16 it caused 26 of 45 INCONCLUSIVE integration runs and 22 of
  42 INCONCLUSIVE T3s, on fresh devices too (#1389). `lane_sim.boot_with_retry` marks the stalled device unsafe,
  deletes it, and boots one fresh device in its place: a new clone for the runner's T3, a new Test Runner for
  `verify-tests.py`, another pool device for `--pool`, a new device for `--fresh`. A device named on the command
  line (`lane-sim-boot <udid>`, `verify-tests.py --device`) gets no retry. A second stall, a failed `simctl boot`,
  a crash report and a timeout all stop as before. Before a retry the lane waits 150 s for late crash reports; one
  naming the stalled device means a possible crash flood, and nothing is retried. The retry happens before any app
  is installed or test runs, so it can't hide an app failure; the report names the retry and the replaced device.
  Each stall is logged on #1802: the runner posts it after its report, with the link and verdict; the other
  callers post it from `lane_sim.py`.
- The old standing device, "SM Lane Desk erase-approval" (1330F268-5467-4421-9D55-1FCC3FF5CF8A),
  stays retired: never boot, erase or reuse it. Stay on iOS 26.5: iOS 27's Apple Intelligence
  services crash-flood on this Mac (#184). `--fresh` still makes a one-off device, for work that
  isn't a desk run (it costs an approval each time).
- If scripts/lane-sim-boot prints STOP, stop and report. Never retry a failed boot or boot a
  device another way; the guard blocks devices marked unsafe.
- On 26.5, unlocking after a lock sometimes freezes the display. Mark lock-and-unlock
  steps "not verified" and leave them for the owner's phone pass.
- **A lane job that ends with no report (#2174).** When the runner is lost, a job runs no step: no report, no tidy-up note, and `lane:queued` stays. lane.yml's `lane-lost` job (on the VPS runner, only after the lane job failed) runs `lane-runner.py --lost` from the base branch. It does nothing if the run already reported or tidied up, the PR moved on, or the request was answered; otherwise it posts `Lane report pr<N>-r<run> — INCONCLUSIVE` naming the run (no tested commit, so the auto-revert never counts it), and takes `lane:queued` and `lane:running` off. Dispatch then reruns it once like any lane fault. A cancelled lane job is not covered.
- At most two simulator jobs on this 16 GB Mac, and the second only while memory pressure is
  normal (two plus builds filled swap before the owner freed memory, #184). The helper holds a
  Mac-wide simulator slot from boot until its watcher stops (the stop flag above, or --done). The runner's T3 takes the other slot or waits.
  `scripts/lane-sim-boot --second-slot status` says whether a second job may start. When the
  lane switches the second slot off by itself, it comes back on after a cooldown (4 h, doubling
  for each repeat trip that week, at most 24 h) once pressure is normal; `off` by hand stays off
  until `on` (#2157). A journey
  that needs two devices (J5) still runs them one after the other, so the runner keeps its slot.
- Never touch any other simulator, other projects' simulators, the owner's iPhone,
  their Library, or main.

Crashes: after every journey step, check ~/Library/Logs/DiagnosticReports for new .ips
files. Three crashes of one process within a minute is a flood: stop, retire that
simulator with `scripts/lane-sim-boot --retire <udid> "crash flood: <process>"` (it marks
the device unsafe, so the pool never reuses it, then shuts it down and deletes it),
report on #184, and wait for the owner.

Disk: check df -h / before each build or journey. Below 10 GB free, report
INCONCLUSIVE ("disk below 10 GB") on #184 and stop. After posting each report, delete
that run's .xcresult bundles and raw build logs. Keep only the screenshots and short
logs the report names, under artifacts/lane/<id>/. Shut the simulator down whenever
the queue is empty.

Reports: post in the report format above, on #184 (a one-off scenario's on its PR). There
is no lead session to message; the project reads reports on GitHub. Before you step down, or
when a fresh desk may have to take over, post a "Test Desk hand-off" on #184: the state of
the desk pool (which devices are approved, any retired since the last hand-off), your worktrees,
what's half-done, and lessons for this section.

Decisions: for reversible lane choices, post them on #184 under "Default taken" and keep
going. Stop only for owner data, the phone, money, anything public, main or releases.
```

## Batching T4 requests

`scripts/desk-batch.py` (#1557) turns the unanswered `/lane T4` requests into work lists sized for one desk session. Each desk of 2026-10-13 got through one to three checks before the 250k-token line, mostly because a screenshot costs about 2.5k tokens and the simulator lags enough to need two a step. A desk that starts from a sized list on one build spends its context on checks, not on choosing them. Since 2026-10-16 each check's journeys run in helper agents (journey skill, Driving), so the screenshots no longer pile up in the desk's own context; batch sizes were set before that and may be raised once desks report their `tokens:` lines.

```bash
scripts/desk-batch.py            # prints GO or STOP; on GO writes the first batch to ~/SpokenMarginsOps/desk-batches/
scripts/desk-batch.py --print    # also prints the list
scripts/desk-batch.py --json     # the whole plan, writes nothing
```

- **What counts as waiting.** A `/lane T4` comment on a PR with no later desk report on that PR. A desk report is a comment whose first line starts "Lane report" and says PASS, FAIL or INCONCLUSIVE; the runner's `pr<N>-r<run>` reports don't count, and neither do hand-offs, so a check a desk left half done stays on the list. A newer request on the same PR replaces an older one. Requests older than ten days are not read (`--window-days`).
- **Batches.** A merged PR's check runs on `main`'s tip and an open PR's on its head, and checks that share a build share a batch, so the desk builds and installs once. A batch holds about 24 steps (the numbered lines of `scenario:`, plus the steps of each journey named in `run:`) and at most 4 checks. `priority` PRs go first, then the oldest request. A check bigger than a batch gets a batch of its own.
- **When to start a desk.** GO when any batch has 3 checks or 12 steps, or its oldest request has waited 6 hours (that batch is the one written); STOP otherwise, with what the first batch is waiting for. These are defaults (`--min-checks`, `--min-steps`, `--max-wait-hours`); the Mac tick runs the script (owner's choice, 2026-10-13; text below). The script reads GitHub and starts nothing. Exit code 0 is GO, 1 STOP, 2 an error (never GO).
- **Text for the Mac tick (#1559).** In `~/.claude/scheduled-tasks/sm-mac-tick/SKILL.md`, after the usage-breaker step and before the advice line, add:

  ```text
  TEST DESK BATCH. Run `/usr/bin/python3 ~/SpokenMarginsOps/repo/scripts/desk-batch.py`. It only reads GitHub and takes about 15 seconds.
  - Exit 0 (GO): add one line to this tick: `- Test Desk: GO, <its first output line after "GO:">, work list <the path on its "work list:" line>`.
  - Exit 1 (STOP): add nothing.
  - Exit 2 (error): add `- Test Desk batch check failed: <its ERROR line>`.
  - During a HALT (usage breaker: Claude) the GO line is information only: start nothing until RESUMED.
  ```

  The tick reports; it doesn't start a desk. The desk drives the simulator with the desktop app's iOS simulator tool, which a scheduled task can't use. The open step is who turns a GO line into a running desk: the coordinator's hourly dispatch (a managed desk, as on 2026-10-13) is the natural fit, and needs a line in the project instructions that only the owner can change. Until then the owner starts a desk from `latest.md` in `~/SpokenMarginsOps/desk-batches/`.
- **After the batch.** The desk posts one report per check on its PR, which takes it off the list. When its context runs short it stops between checks and posts a hand-off on #184; the next run of the script lists what is left, so nothing is passed along by hand.
- **Cost.** No model tokens, and no state. About 60 `gh api` reads for the ten-day window. If a batch keeps going with one check, or desks still run out before finishing a batch, change the step budget.

## The Mac's runners

Three self-hosted GitHub Actions runners on the owner's Mac (the third after the owner installs it) run `.github/workflows/lane.yml`. Each is a LaunchAgent in its own folder.

| | Main runner | Build runner | Priority runner |
|---|---|---|---|
| Name | `sm-lane-mac` | `sm-lane-mac-2` | `sm-lane-mac-3` |
| Folder | `~/actions-runner-spoken-margins` | `~/actions-runner-spoken-margins-2` | `~/actions-runner-spoken-margins-3` |
| LaunchAgent | `actions.runner.uncomposed-spoken-margins-native.sm-lane-mac` | `actions.runner.uncomposed-spoken-margins-native.sm-lane-mac-2` | `actions.runner.uncomposed-spoken-margins-native.sm-lane-mac-3` |
| Labels | `self-hosted, macOS, ARM64, sm-lane` | `self-hosted, macOS, ARM64, sm-lane-build` | `self-hosted, macOS, ARM64, sm-lane-priority, sm-lane-build` |
| Jobs | `lane` only (/lane T2, T3, simulators) | `automerge` only (host tests) | Priority `lane` and `automerge`, plus any queued `automerge` when it is free |
| `.env` | `SM_LANE_EVIDENCE_DIR`, `SM_LANE_TOOLS` | the same, plus `SM_LANE_RUNNER_ROLE=build` | Copy the build runner's `.env` exactly |

- **Hosted T2 and T3 (#1389 phase 2), off until the repo is public.** With the repository variable `LANE_HOSTED_APP` set to `on`, the route job sends the `lane` job (every `/lane` request) to a GitHub-hosted Mac (`xcode-27`, Xcode 27.0) instead of the Mac's runners; the `automerge` and `release` jobs, which merge, stay where they are. `lane-runner.py` runs there unchanged, with the lane state and evidence folders in the job's temporary folder, so its slots, simulator template and device claims are its own and never wait. It tests on iOS 26 when the image has that runtime, and otherwise on the image's newest iOS (a warning on the run, and the report's simulator line names it). The evidence goes to the run's `lane-evidence` artifact for 7 days. A T3 PASS that releases a held automerge run hands its host tests to the Mac's release job, as the main runner does (#1209). Two things stay on the Mac's side: the lane auto-revert check, and the step ledger's history (a hosted job's ledger lives and dies with the job, so its alarms see only that job). Set it with `gh variable set LANE_HOSTED_APP --body on`; unset it to go back.
- **Merging off the Mac (#2459).** Off until the hosted Mac-rest check passes on its image (#2459). With `LANE_HOSTED_FAST` and `LANE_HOSTED_MAC_REST` both `on`, hosted-portable.yml runs a third check on PRs, `hosted fast: Mac rest` (`--plan fast-mac-rest` on an `xcode-27` GitHub Mac with BlackHole as its audio output; a dispatch runs it any time), and the route job sends every `automerge` job to `ubuntu-latest`. There `lane-runner.py --hosted` reports a PR held for T3 in seconds and tests nothing. Otherwise it waits on Linux (up to an hour) for all three hosted checks to pass on the head merged onto the trunk, dispatches hosted-portable.yml again on the PR's branch with `base` (up to 3 times) when the trunk has since moved in ways that matter, and merges on them with no test of its own. A failed hosted check is the PR's FAIL. When the checks can't be had (missing, cancelled, never recorded), it posts nothing and the `automerge-mac` job runs the old path on `sm-lane-build`. A T3 PASS's lane job merges on standing hosted checks in seconds instead of handing host tests to the release job. T0 and ops diffs still test themselves on Linux. Turn it on with `gh variable set LANE_HOSTED_MAC_REST --body on`; delete the variable to send merging back to the Mac. With `LANE_HOSTED_FAST` on and `LANE_HOSTED_MAC_REST` off, the `automerge` job still starts on `ubuntu-latest`: a PR held for T3 is reported held there in seconds, a failed hosted pair is the PR's FAIL, and only once both pair checks have passed on the head (or can't be had) does it hand the run to `automerge-mac`, which runs `--plan fast-mac-rest` and merges, so the build Mac never waits idle for the pair or tests a PR held for T3. `LANE_HOSTED_MAC_REST` is not yet on: on 2026-10-22 two of the image's 998 SessionKit tests failed for the OS, not the code (SystemNarrationRateTests on macOS 27's voices, and no en_US SpeechTranscriber model; #2469).
- **Priority routing.** A short GitHub-hosted pre-job checks the repository's runners with `gh api` before either Mac job queues. A PR labelled `priority`, or a T1 diff touching only `ops/`, `docs/`, and the lane paths (`LANE_PREFIXES`/`LANE_FILES` in the base branch's `scripts/test-scope.py`), uses `[self-hosted, sm-lane-priority]` when a matching runner is online. Busy online runners count; priority work queues behind other priority work. T0-only and mixed diffs stay in their normal queues unless labelled `priority`. File pagination and both sides of renames count; incomplete file lists never qualify as ops-only.
  - **Priority runner (#2147).** As of 2026-10-19 (owner) `sm-lane-mac-3` is priority-only again: it carries `sm-lane-priority` and not `sm-lane-build`. So priority jobs skip the ordinary build queue. The Mac runs two heavy jobs at once (`lane_slots`), so a priority job can still wait behind at most one run holding a Mac-wide host-test slot. From 2026-10-11 to 10-19 that runner also carried `sm-lane-build`. GitHub gives waiting self-hosted jobs no order, so the priority label only narrowed a job to one runner: on 2026-10-19 a priority job waited 40 minutes while `sm-lane-mac-2` freed up three times. As a guard in case the label is ever re-added, a priority `automerge` job goes to `[self-hosted, macOS, sm-lane-build]` whenever every online priority runner also carries `sm-lane-build`, so it is never slower than an ordinary job. The `lane` (T2/T3) job always goes to the priority runner. True jump-ahead ordering is #1057.
  - **Overflow (#1327).** An `automerge` job that would otherwise queue for `sm-lane-build` goes to the priority runner instead when that runner is online and idle (`busy` false) and no online runner labelled `sm-lane-build` is idle. This holds for any diff, and the `lane` (T2/T3) job never moves. This is how idle time on the priority runner gets used. It is a snapshot of the runners' `busy` flags taken when the PR is armed, so it can't see jobs already routed to the priority runner: PRs armed within the same minute can all land there and run one after another, and a priority job that arrives later waits behind them. Jobs already queued don't move; a re-arm routes again. The main runner carries only `sm-lane`, so the simulator runner never waits behind host tests.
  - If the runner is uninstalled/offline, runner discovery is denied or times out, or the hosted pre-job fails, jobs use the normal labels above. An online runner going offline after the check can still leave an already-routed job queued; re-run once it is online or remove/re-add the request label to route again.
  - Configure repository Actions secret `SM_LANE_RUNNERS_TOKEN` with a fine-grained PAT restricted to this repository and **Administration: read** for runner discovery. The workflow token is tried if the secret is absent; denied access falls back. PR-file discovery always uses the workflow's read token. Routing executes base-branch policy, with no PR code receiving the discovery token.
  - The third runner adds a queue, not capacity: T3 still takes the existing Mac-wide simulator slot; builds still take the existing `lane_slots` build slots. Its copied `SM_LANE_RUNNER_ROLE=build` applies the same memory/disk gates and host-only beside-a-simulator trial to its automerge jobs. Lane PRs still need a clean Codex audit on their head before merging. Only the owner installs the runner; the implementing PR provides the install commands.
- **Build runner gate.** Automerge jobs build no app since 2026-10-09, so every one takes the host-only terms below. With `SM_LANE_RUNNER_ROLE=build`, an automerge job waits up to 90 minutes for three things: no simulator job running, normal memory pressure, and 20 GB of free disk. Otherwise it reports INCONCLUSIVE and says why.
  - **Trial (2026-10-01): host-only work beside a simulator.** A job whose diff needs no app build (T0 or T1 by main's `test-scope.py`) may start while a simulator job runs, if the kernel reads memory pressure as normal (`kern.memorystatus_vm_pressure_level`, the level `memory_pressure` reports) and more than 30 GiB of disk is free. Its report says "ran beside a simulator job (trial)", and each such job adds one line (time, request id, PR) to `beside-simulator.log` in the lane state folder, to count simulator crashes against. The way back is reverting the PR that added it.
  - The builds-beside-a-simulator trial (2026-10-01) ended with the per-PR app builds (#1207). T2 builds take `lane_slots`' usual build slots wherever they run: two, or one while a simulator job runs.
- **Check all:** `gh api repos/Spoken-Margins/spoken-margins-native/actions/runners --jq '.runners[] | "\(.name) \(.status) busy=\(.busy)"'`. On the Mac, `./svc.sh status` in a runner's folder.
- **Restart one:** `./svc.sh stop`, then `./svc.sh start`, in its folder. Its logs are in `_diag/`, and the job workspace is `_work/spoken-margins-native/spoken-margins-native`.
- **Remove one:** `./svc.sh uninstall`, then `./config.sh remove --token <token>`. Get the token from `gh api -X POST repos/Spoken-Margins/spoken-margins-native/actions/runners/remove-token --jq .token`.
- **Runner simulators.** A T3 job creates its own `SM Lane Runner <run>` device and locks that name in the lane state folder until it deletes the device. Every job first sweeps leftover runner devices but skips a locked one, so one runner's sweep can't delete the other's live T3 device (#440, #411). A crashed job's lock ends with its process, so its leftover is swept. If a plan's device disappears or its readiness step fails, the run stops there and reports INCONCLUSIVE as a lane fault, not FAIL.
- **Evidence:** each job writes to `SM_LANE_EVIDENCE_DIR`, which is `artifacts/lane/<request-id>/` in the owner's main checkout.
- **Lane folder cap (#1775).** `~/Library/Caches/SpokenMarginsLane/` as a whole (warm builds, compilation cache, evidence and state) is held to **16 GiB**. On 2026-10-16 it grew from 10 GB to 23 GB in a working day, 6.2 GB of it evidence that nothing pruned, while the Mac's free disk fell from 73 GB to 31 GB, near the 20 GiB at which the Mac finisher pauses. `ops/disk/sm_lane_prune.py` enforces it; the disk relief job runs it on every run (every 15 minutes), whatever the free space, and the lane runner runs it before each T2 or T3 build (`prune_lane_folder`; one directory walk, never fails the job), which is what reaches `artifacts/lane/`. Its rules:
  - **Evidence** (`pr<PR>-r<run>[-a<N>][-auto]`, in `evidence/` and in `artifacts/lane/`) is deleted 7 days after it last changed. The latest run of each open PR (every attempt and its `-auto` run) is kept whatever its age, found with `gh pr list`. When GitHub can't be asked, the latest run of any PR seen in 30 days is kept. A folder not named like a lane request (a Test Desk or journey folder with a free-form id) has no PR to keep it, so it goes after 7 days too. Nothing changed in the last hour is touched. `artifacts/lane/` is in `~/Documents`, which the disk relief job can't read (no Full Disk Access): there it skips and logs, and the lane runner's run prunes it.
  - **Warm builds** are evicted, oldest first, across all `checkout-*` folders, only while the folder is over the cap. Before a build (the lane runner's run, and any command-line run) the prune also leaves 3.5 GiB of room under the cap, one app build's new warm cache (`BUILD_ROOM_BYTES`), so the folder stays under 16 GiB while that build runs; pruned only to the cap, each build took it to as much as 19.5 GiB until the next run (2026-10-18 and 10-19). The disk relief job prunes to the cap itself, with no room, since no build starts with it. Two app builds that start within a minute of each other can still take it over by about one cache. The newest cache of each checkout stays, and a cache a job holds (its `.lock` flock, the test `_cache_busy` uses) is never touched; the prune holds that lock while it deletes. A `checkout-*` folder that no checkout, worktree or runner workspace on the Mac maps to is removed once every cache in it is idle and the folder has gone a day untouched.
  - **Still over the cap**, the oldest evidence in the lane folder goes next (never an open PR's latest run). What is left is the compilation cache (Xcode bounds it, about 6 GB), state, busy caches and one cache per checkout; the log says so.
  - **Never touched:** the state files (slot locks, `step-ledger.json`, `unsafe-simulators.json`, `desk-simulator-pool.json`, `guard.log`, `inherited-holds.json`, `boot-events.log`) and `compilation-cache/`.
  - Check what it would do with `python3 ops/disk/sm_lane_prune.py --dry-run`. The disk relief log (`~/SpokenMarginsOps/disk-relief/log.txt`) shows each deletion and the folder's size before. **Waste signal:** the prune deletes nothing for 14 days, or the folder's peak stays under 8 GiB for 14 days (the cap is set too high to matter). **Too tight:** more "build folders: cold" lines in lane reports after it.
- **Git LFS:** both jobs check out with `lfs: true`, because the Supertonic models are LFS files and the contracts check reads them. The LFS cache is in the workspace's `.git`, so each runner downloads the models once.
- **Warm build folders.** A T2 or T3 job links the tree's `.build` and `Packages/SessionKit/.build` to `~/Library/Caches/SpokenMarginsLane/warm-build/checkout-<checkout path hash>/sk-<SessionKit tree hash>-<project file hash>/`.
  - Automerge jobs keep no cache (#1207). They build no app, and their host tests' SwiftPM build of SessionKit (1.3 GB) stays in the workspace and is emptied when the job ends. A warm SwiftPM cache saved about 50 s of a 5-minute run on the 48% of runs that hit one (medians from 460 automerge reports, 2026-10-10), and four per build runner held about 9 GB. Each automerge job removes its own runner's idle caches that hold no app build (no `root/dd-*`, nothing in `root/verification`); a T2 or T3 cache, a busy one, and another runner's folder stay.
  - A SessionKit change starts a new cache, because stale SessionKit modules give false "does not conform" errors. An Xcode project change does too.
  - Each runner has its own caches. DerivedData and SwiftPM's state record absolute paths, and a cache shared by the two original runners lost Xcode's VFS overlay and the onnxruntime binary (#405).
  - A cache whose SwiftPM state lists a binary artifact that isn't on disk is emptied, and the job builds cold. Its report says which artifact was missing.
  - The T2 simulator and device builds each have their own DerivedData (`.build/dd-simulator`, `.build/dd-device`). When they shared one, the warm simulator build after a device build failed on a missing `all-product-headers.yaml` (#405).
  - At most four caches are kept per runner (#863), with idle caches evicted first. Below 25 GB of free disk (above the 20 GiB at which the Mac finisher pauses and the build runner waits, #1775) idle caches are cleared; if that cannot restore the floor, the job builds cold and its report says so. Caches in use stay locked and are never evicted, even when that leaves more than four.
  - If a build error disappears on a cold rebuild, delete `warm-build/` while no job runs.
- **Compilation cache (#1331).** Every `verify-tests.py` app build (T3, the integration run, the Test Desk) turns on Xcode's compilation cache, stored in `~/Library/Caches/SpokenMarginsLane/compilation-cache/` and shared by every checkout on the Mac. A prefix map turns the tree's own path into `/^tree`, so one checkout's results serve another. So test failures print `/^tree/App/…/X.swift:25`, not the absolute path. Xcode holds the store under about twice `COMPILATION_CACHE_LIMIT` (3G). Measured 2026-10-12 on the lane Mac: a cold simulator build-for-testing took 57-73 s; with the cache, 46 s after a one-line SessionKit edit, 39 s after an app-only edit, 18-25 s with no change. If a build error looks stale (code that is already fixed still fails), delete `compilation-cache/` while no job runs and run again.
- **The app test host launches but never reaches XCTest (#705, #1161).** On some runs the app plan or the adapters plan launches `SpokenMarginsApp` and then nothing runs: no `Test Suite` line, 0 tests, and Xcode ends with "The test runner hung before establishing connection" (exit 65 after about 5.5 minutes) or the step runs out of its budget (exit 124). Healthy runs print their first `Test Suite` line about 7 seconds after launch. It is not the PR's code: the same head passes on a rerun.
  - **What the stalls show (32 stall folders read 2026-10-14, #1161).** The app's own startup code is not the cause; no sample has a main thread blocked in app code. 19 host apps had started and sat idle in the run loop with no XCTest library loaded: none of the libraries in xcodebuild's `DYLD_INSERT_LIBRARIES` (`libXCTestBundleInject`, `libRPAC`, `libMainThreadChecker`) were in the app's image list, so nothing in the app could connect to the test runner, although the launch settings matched the retry that passed. 12 had no host app process at all: the session log ends at "Launching app". 1 had launched late (the simulator took about 70 s to launch it) and was still in dyld, stopped for the debugger, when the watchdog sampled it; a later stall had the same shape. Why the injected libraries are missing, and why the launch is slow or never completes, is still unknown; it is on the Xcode and simulator side. The adapters plan, which runs second on the same simulator right after the app plan, stalls far more often: 20 of the 32 stall folders were from the adapters plan, though the Mac held about one adapters run for every five app runs.
  - **Warm builds are unlikely to be the cause.** The first #1161 failures were on up-to-date builds, but the watchdog's retry reuses the same build and has recovered stalls on it, so a stall is not a reason to delete `warm-build/` (that is for a build error that a cold rebuild clears). The retry is the remedy.
  - `verify-tests.py` watches the `xcode-tests` step of the app and adapters plans. With no test output 90 seconds after launch it saves `xcode-tests-stall-N/` (the simulator's processes and a 3-second `sample` of the host app), ends that launch and launches the same command once more inside the same budget. The manifest records `startup_stalls` and `startup_attempts`; each stall's `diagnosis` names its shape (for example "host app idle in its run loop; XCTest never injected", or "no host app process: the launch into the simulator never completed"), and the step's warning and error repeat it. The partial result bundle is kept as `tests-stalled-N.xcresult`.
  - **What the Mac was doing at each launch (#2176).** Each launch attempt of the app and adapters plans records `launch_conditions` as it starts and as its tests start (with the seconds that took), and each stall records `conditions` as it is seen: the load average, memory pressure, swap in use, free disk, and which lane jobs hold the build, host-test and simulator slots (`scripts/lane_conditions.py`). The manifest's `app_bundle_mb` is the size of the app each launch installs. `.venv/bin/python scripts/lane_stall_report.py [--since YYYY-MM-DD] [folders]` counts stalls against each of these across `artifacts/lane`; a launch gate's threshold comes from it. On 2026-10-19, with only the load on record, the 1-minute load at launch gave none: 10% of launches stalled below 100, 17-31% between 100 and 200, 14% above 200.
  - **One stall that the first retry recovers, with every requested test then passing, is a PASS** (owner's call, 2026-10-11, decided on the project's decision card; an owner-accepted exception to #705's "don't convert this INCONCLUSIVE to PASS without the cause" while the cause is still open). The manifest step carries `startup_recovered`, the report says "recovered after 1 startup stall", and the lane runner posts each such stall on #705 (the plan, the PR and head, the report link, the stall folder and the kept `tests-stalled-N.xcresult`) as evidence of the cause. Two or more stalls before a pass still end with "Recovered after N startup stall(s) … not a PASS", and if the last launch also never starts the step fails with "Test runner printed no test output in 2 launch(es)"; both report INCONCLUSIVE. A stall whose `diagnosis` is not one of the three shapes above is new evidence: read its `sample-*.txt`.
- **Merging.** An `automerge` PASS is merged by the runner itself (`scripts/lane-runner.py`, `run_auto`):
  - It tests the exact merge commit (main first), posts "**Merge check (triage desk)", then does a plain push. A push refused because main moved leads to a re-test, up to 3 times, unless main's commits since the tested one touch none of the PR's files and no build inputs (`project.yml`, any `.xcodeproj` or `.xcconfig`, `Config/`, `Package.swift` and `Package.resolved`, `package.json` and its lock, `.github/`, `scripts/`, `Contracts/schemas/`). A script the PR's checks never read doesn't count (`HOST_UNREAD_SCRIPTS` in `lane-runner.py`: phone builds, job dedupe, the merge audit, app-build and release scripts, and the runner tests that aren't readers), unless the PR itself touches `scripts/`, `.github/`, `.gitignore`, `ops/`, `project.yml`, `TestPlans/` or `AGENTS.md`, which runs every runner test or the ops tests (#1208). Then it merges onto the new next and pushes without testing again, the owner's standing call being that the Test Desk tests main's merged tip end to end. The report says which way it went and lists the commits it didn't re-test against. `scripts/phone-build` accepts either the exact tested merge or the safe re-merge explicitly named in a PASS report, without repeating host tests or the simulator build (#1329). Missing evidence still runs those checks. Its ten-minute poll coalesces changed tips to hourly, with an earlier build after integration PASS or an explicit owner request, and keeps a persistent source checkout and Release DerivedData.
  - Lane changes merge like any other, with the audit below (owner rule 2026-10-01), except a PR touching `scripts/lane-runner.py` or anything under `.github/`: the runner never merges those, whatever the audit says, and its report says the PR needs the owner's tap (owner rule 2026-10-09, #1203). The owner arms and merges them; the audit still runs, for the owner. The lane paths are the ones `scripts/test-scope.py` lists in `LANE_PREFIXES` and `LANE_FILES`: the workflows, the runner and its helpers, the policies it loads from next, `verify-tests.py`, and the two T3 test plans. A lane PR's own run uses its own workflow and helpers, so its PASS proves less than usual; the Codex audit is the check that matters.
  - An audio, persistence, packet or lane diff merges only when the newest audit that names the PR's head commit (the heading "**Claude audit on `<sha7>`**", or the older "**Codex audit (Astra) on `<sha7>`**") opens its verdict (the first line after the heading) with "No blocking findings" (#441). An audit of an older commit, or one with findings, holds it, and the report says which. It reads the comments again after testing, so an audit that lands during the run counts. An older manual "## Codex audit" counts only if its heading names the head commit.
  - After each merge it runs `merge_audit.py --sweep-hours 2`, because pushes made with the workflow token start no workflow. `merge-audit.yml` audits every other push to `main`. It has no schedule: GitHub runs scheduled workflows only from the default branch (`main`).
- **Stale merge refs.** GitHub builds a PR's run from its merge ref, and a label event doesn't refresh it. A PR opened before a `lane.yml` change keeps the old jobs until it merges next and pushes (#221).
- **Step ledger** (#1200, `scripts/lane_ledger.py`). After each report, the runner adds every step the job ran (hot-file ratchet, host tests, app builds, app tests) to `step-ledger.json` in the lane state folder: runs, wall time, PASS / FAIL / runner faults, and catches (a FAIL that a later commit on the same PR fixed). It posts one "Lane step alarm" comment on #337 the moment a step runs 20 times in a row without a FAIL at over a minute a run, has 3 runner faults in a row, or fails the same test on two PRs tested against the same `main`. An alarm isn't repeated until its condition clears and comes back. To read the numbers: `cat ~/Library/Caches/SpokenMarginsLane/step-ledger.json`.
- **Auto-revert of a lane change** (owner rule 2026-10-01). Every lane job on `main` starts by finding the newest merge into `main` that touched lane paths (`scripts/test-scope.py`, `LANE_PREFIXES` and `LANE_FILES`). If the first two lane reports on PRs after it, from jobs that tested a `main` containing it, were both runner faults, the runner reverts that merge with `git revert -m 1`, pushes it like a merge, files a `ready` + `regression` issue to re-land it, and posts a comment starting "Lane auto-revert:" on #337 naming the PR, the two reports and the revert commit.
  - A runner fault is an INCONCLUSIVE report for a lane reason (a failed boot, the build runner's room wait, a crash in the runner, a missing tool or runtime, a timeout), or a job that stopped before reporting. A merge conflict, a T3 hold, a request with no tests, a test that fails on `main` too (#1204) and any FAIL are not.
  - A report counts only if its "(tested merged with main at `<sha7>`)" names `main`, not a `lane-check/**` base, at a commit containing the lane change. A stopped-job note carries the same words when the job had fetched its base before it stopped; one without them doesn't count.
  - Only once per lane change, and never a merge that didn't touch lane paths or that is itself a revert of a lane change. A revert is recognized by git's "This reverts commit `<sha>`" line in the merge's own commits, naming a lane change already on `main`, not by the PR title. A revert that doesn't apply cleanly is posted on #337 ("Lane auto-revert failed:") and left for a person.
  - It can't catch a lane change that stops the runner before the check runs (a broken `lane.yml`, or a `lane-runner.py` that doesn't start): no job reports, so nothing triggers it. The Mac tick on #337 is the watch for that.
- **Mac-wide state** is in `~/Library/Caches/SpokenMarginsLane/`: the slot locks, `boot-events.log`, `unsafe-simulators.json`, `desk-simulator-pool.json` (the Test Desk's pool, #688), and the lane guard's `guard.log`; the folder as a whole is capped (see "Lane folder cap" above). The guard hook is `~/.claude/hooks/spoken-margins-lane-guard.py`; reinstall it with `scripts/install-lane-guard.py`, and use `--check` to see drift.

## What the owner sees

- Each stream's PR shows its requests and reports in order, so the phone view of GitHub is the dashboard.
- The owner gets a notification only for: a crash flood, a FAIL on a gate stream, a TestFlight candidate that passed T5 and is ready for T6, or an owner decision a stream is blocked on.
