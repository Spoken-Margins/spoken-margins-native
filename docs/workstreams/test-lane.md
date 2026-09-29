# Test lane: sharing one Mac between many streams

The Mac is the bottleneck. It is the only place that can build the app, boot simulators and drive journeys, and it can't run many simulators at once. The test lane is how streams share it, and the test tiers below are how streams avoid testing more than a change needs.

This page is the contract. Stream A1 (`lane`) builds the machinery behind it.

## Tiers: test what the change could have broken

Pick the **lowest tier that exercises what the diff could break**, and run it once. A tier doesn't include the tiers below it unless the row says so.

| Tier | What runs | Where | Typical cost | Use it for |
| --- | --- | --- | --- | --- |
| **T0** | Nothing, or a doc/link check | anywhere | 0 | Docs, research notes, charters, server code with its own tests |
| **T1** | The tests for the touched module only: `swift test --filter <Suite>` for SessionKit, or the stream's own Python/Node/server suite | Mac host, or cloud once A1 enables Linux SessionKit tests | 1–3 min | Pure logic: parsers, ranking, packet merge, text cleanup, resolvers |
| **T2** | Compile the app for simulator **and** device (the two `xcodebuild` commands in `AGENTS.md`), no simulator boot | Mac, build semaphore | 4–10 min | Any change to `App/`, `project.yml`, or a SessionKit public API |
| **T3** | Targeted app-hosted XCTest (`-only-testing:` the touched test classes) in the Test Runner simulator | Mac, via the lane | 5–15 min | App orchestration: model/coordinator wiring, persistence through the app |
| **T4** | Named journeys from `docs/journeys.md`, or a one-off scenario the request spells out, driven with real taps and screenshots | Mac, via the lane (Test Desk) | 10–40 min each | A stream milestone that changes something a listener does |
| **T5** | Full regression: `--plan fast`, `--plan app`, every journey | Mac, via the lane | 1–3 h | Only for a TestFlight candidate on `next`, once per candidate |
| **T6** | Owner on the phone | owner | owner time | Audible content, Bluetooth, Lock Screen, background, thermal. Batched per TestFlight build |

**Rules of thumb**

- A change you could describe in one sentence, in one module, with a test that fails without it, stops at **T1**, or **T2** if it touched the app.
- Most commits stop at T1 or T2. T3 and T4 happen at **milestones**, not per commit.
- **Escalate one tier** for anything touching the audio session, players, playback state, persistence/migrations, or packet import/export. These are where Build 28 → co-op went wrong.
- **Never escalate to T5 on a stream branch.** Full regression runs once per TestFlight candidate on `next`.
- A new regression test must be run once **without** the fix and seen to fail (`AGENTS.md`). That run counts as T1, not an extra tier.
- When unsure, ask the lane for the tier (A1 ships `scripts/test-scope.py`, which maps a diff to its minimum tier and suggested test filters). If the tool and your judgment disagree, take the higher tier and say why in the request.

## The lane

**Endpoint A1 must reach.** Any stream, cloud or Mac, can request T2–T5 against a pushed commit without the owner doing anything, and gets a report on its PR. The Mac never runs more than **one** simulator job at a time (it has 16 GB; two simulators plus builds filled swap, #184). It never runs more than **two** `xcodebuild` invocations at once *in total*, and only one while a simulator job runs: one Mac-wide semaphore shared by the lane and every stream session. A crash flood stops the lane and notifies the owner.

**Recommended shape** (A1 may change it if the endpoint holds):

- **Intake is the PR.** A stream opens a draft PR into `next` and comments a request (format below) with the label `lane:queued`. Mac streams may also message the Test Desk session directly as a doorbell, but the request itself always lives on the PR so the owner can see it from the phone.
- **Deterministic tiers run without an agent.** A self-hosted GitHub Actions runner on the Mac, with a single concurrency group, runs T2 and T3 (and T1 for Swift) and posts the result. Cheap, repeatable, no tokens.
- **Journeys run with an agent.** A long-lived Claude Code session on the Mac named `test-desk` picks up T4/T5 requests (polling the label with `/loop`, or woken by a message), works in its own worktree and DerivedData, drives the simulator, and posts the report.
- **Coalesce.** If a newer commit lands on the same PR while a request is queued, test the newest only. Identical requests against the same commit run once.
- **Order.** Gate streams (A2 `seams`, anything blocking others) first, then oldest request first.
- **Evidence stays local.** Screenshots and logs go under `artifacts/lane/<request-id>/` (git-ignored). The PR comment carries the observations and file paths, not images.

Note for whoever builds the Test Desk: Claude Desktop's iOS Simulator pane currently doesn't work with Xcode 27 ([docs](https://code.claude.com/docs/en/desktop-ios-simulator)). This repo builds with Xcode 27, so drive the simulator through computer use from the CLI, as the journeys do today, until the pane supports Xcode 27.

## Guard rails (deterministic, not advisory)

- **Only the lane boots simulators.** A1 installs a `PreToolUse` hook in the Mac's **user-level** settings (`~/.claude/settings.json`), so it applies to every session whatever branch it started on. It blocks `xcrun simctl boot|install|launch`, `xcodebuild test`, and `verify-tests.py --plan app|adapters|ui|release` unless the session is the Test Desk. Stream agents then *can't* start a simulator flood by accident. `AGENTS.md` sends `--plan app` through the lane for this reason.
- **Build semaphore.** Every `xcodebuild` on the Mac, from streams and from the lane, goes through one wrapper that allows two at a time and queues the rest.
- **Fresh DerivedData per worktree** (`AGENTS.md`: stale SessionKit modules give false "does not conform" errors).
- **Crash-flood rule** as in `AGENTS.md`: three crashes of one process within a minute stops the lane, shuts that simulator down and notifies the owner. A lone crash is noted in the report and work continues.

## Request format

Post as a PR comment. Keep it short; the Test Desk needs intent, not narrative.

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

The Test Desk is a Claude Code session opened on the `spoken-margins-native-test-desk` folder, which sits next to the repo checkout (a git worktree). The lane guard lets only that session boot simulators. Restart it from this prompt at the start of each day, or whenever it starts contradicting what's recorded here or on #184, so that no rule lives only in a session's context.

```text
You are the Test Desk for Spoken Margins: the only session on this Mac allowed to boot
simulators. Read AGENTS.md, docs/workstreams/test-lane.md, docs/journeys.md, the
journey and lane-request skills in .claude/skills/, and the last few comments on #184.

Setup: this folder is a worktree. Run git fetch origin && git switch --detach origin/next,
then scripts/setup-worktree.sh. Never create branches here.

Queue: /lane requests on open PRs into next. Test the newest commit on each PR only.
Order: gate streams first, then oldest first. Run every T3 before any T4, and run T4
only where the listener's flow changed. Build through scripts/xcodebuild-lane.

Simulators:
- Every request gets a fresh iOS 26.5 device: UDID=$(scripts/lane-sim-boot --fresh
  "SM Lane Desk <request>"). A watcher stops it at the first SpringBoard crash. Remove it when
  the job ends with scripts/lane-sim-boot --done "$UDID". There is no standing lane device;
  942055FF is retired. iOS 27's Apple Intelligence services crash-flood on this Mac (#184).
- If scripts/lane-sim-boot prints STOP, stop and report. Never retry a failed boot or boot a
  device another way; the guard blocks devices marked unsafe.
- On 26.5, unlocking after a lock sometimes freezes the display. Mark lock-and-unlock
  steps "not verified" and leave them for the owner's phone pass.
- One simulator at a time on this 16 GB Mac (two plus builds filled swap). The helper holds the
  Mac-wide simulator slot from boot to --done, and the runner's T3 waits for it. A journey that
  needs two devices (J5) runs them one after the other, or goes to the owner's device pass.
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

Reports: post in the report format above, on the PR. After each PASS, message the day's
lead session "PASS #<pr> <head sha> <tiers>", if it has told you its name.

Decisions: for reversible lane choices, post them on #184 under "Default taken" and keep
going. Stop only for owner data, the phone, money, anything public, main or releases.
```

## What the owner sees

- Each stream's PR shows its requests and reports in order, so the phone view of GitHub is the dashboard.
- The owner gets a notification only for: a crash flood, a FAIL on a gate stream, a TestFlight candidate that passed T5 and is ready for T6, or an owner decision a stream is blocked on.
