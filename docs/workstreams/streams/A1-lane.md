# A1 · lane: a shared test lane for the Mac

**Outcome.** Any stream, in the cloud or on the Mac, can get its commit built, tested or journey-checked on the Mac and read a clear report on its PR, without the owner in the loop and without the Mac drowning in simulators.

**Why first.** Every Mac stream's milestones end in a lane run, and cloud streams have no other way to learn whether their Swift even compiles. Until this exists, the owner is the dispatcher.

**Where.** Mac. Start from the owner's main checkout.

**Seams.** Owns I16 (lane request and report, defined in [../test-lane.md](../test-lane.md)). Provides the tooling every stream relies on ([../kickoff.md](../kickoff.md) "Repo tooling").

## Starting points

- `scripts/verify-tests.py` already runs named plans with bounded processes, an execution manifest, crash-flood detection and a dedicated `SpokenMargins Test Runner` simulator. Build on it; don't replace it.
- Plans today: `fast` (host), `app`, `adapters`, plus the retired `smoke`, `ui`, `speech-canary`, `release`. See `docs/testing.md`.
- Journeys are in `docs/journeys.md`, including simulator-driving pitfalls learned the hard way.
- Claude Desktop's simulator pane doesn't support Xcode 27 yet, so the Test Desk drives the simulator through computer use from the CLI.
- SessionKit's core, Feeds, Persistence and EPUB targets import only Foundation, CryptoKit and SQLite. They could plausibly build on Linux with a CryptoKit shim, which would let cloud streams run T1 themselves.

## Milestones

**M1: Workbench.** Parallel Mac sessions can't hurt each other.
- Done when:
  - A `PreToolUse` hook, installed in the Mac's user-level `~/.claude/settings.json` so it covers sessions on any branch, blocks simulator boot, install, launch and simulator test plans in every session except the Test Desk. The Test Desk can be identified however A1 chooses, for example an environment variable set when it starts. The agent shows it being blocked in a stream session and allowed in the Test Desk. Changing the owner's user settings is an owner-approved step: show the diff first.
  - A build wrapper caps concurrent `xcodebuild` at two across the whole Mac (lane included), with per-worktree DerivedData. Three simultaneous builds are shown queueing.
  - `scripts/test-scope.py` maps a diff to a tier, and its unit tests cover at least: docs-only, SessionKit-only, app UI, audio-session, persistence, packet.
  - `lane-request` and `journey` skills exist.
  - `.claude/worktrees/` is git-ignored.
- Tier: T1 for the scripts. Demonstrate the hook and wrapper live.

**M2: Deterministic lane.** T2 and T3 run with no agent involved.
- Done when:
  - A PR comment in the request format with label `lane:queued`, on a PR into `next`, results in a T2 or T3 run on the Mac and a report comment in the format of [../test-lane.md](../test-lane.md). Recommended mechanism: a self-hosted GitHub Actions runner with one concurrency group.
  - Two queued requests for the same PR run only the newest commit.
  - Shown working end to end on a throwaway PR.

**M3: Test Desk.** T4 and T5 run with an agent.
- Done when a long-lived Claude Code session named `test-desk` picks up a T4 request (by polling with `/loop` or being messaged), runs the named journey in its own worktree, and posts a report with step-level observations and local evidence paths. Demonstrated with J1 and J7 on `next`.
  - The crash-flood rule is enforced: stop the lane, shut the simulator down, notify the owner (Remote Control push, or a GitHub mention).

**M4 (optional, high leverage): Cloud T1.** Cloud streams can run SessionKit's pure-logic tests themselves.
- Done when a cloud session installs a Swift toolchain (a setup script or `SessionStart` hook) and runs `swift test` for the Foundation-only SessionKit targets in under 10 minutes, and those same tests still pass on macOS.
  - If it needs more than thin `#if canImport` shims, stop and report the cost instead.

## Must not break

- The owner's journey simulator, and anything on the owner's phone.
- `verify-tests.py` evidence guarantees: no silent retries, and a missing test is a failure.
- Nothing in the lane may merge, archive, upload or push to `main`.

## Out of scope

Deciding what other streams must test (the tier table is the policy). Building a web dashboard (GitHub is the dashboard).

## Related

`docs/testing.md`, `docs/journeys.md`, #120 (onboarding recordings as a QA gate: coordinate with G1).
