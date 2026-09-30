---
name: lane-request
description: Pick the test tier for a Spoken Margins change and ask the Mac test lane for a T2–T5 run (app build, app-hosted XCTest, journeys) on a pushed commit, arm the PR and move on, and read a lane report when picking up a FAIL. Use before asking for any simulator or app test, before labelling a PR automerge, when picking up a lane FAIL, or when a command was blocked by the lane guard.
---

# Asking the test lane for a run

The contract is [docs/workstreams/test-lane.md](../../../docs/workstreams/test-lane.md): tiers, request format, report format. This skill is the how-to.

## 1. Pick the tier

Run the scope tool from your worktree:

```bash
scripts/test-scope.py
```

It compares your branch (uncommitted files included) with `origin/next`, prints the minimum tier, the reason for each file, and what to run. Use `--base <ref>` for another base, or `--files <paths>` for a list. If you think the tier should be higher, use the higher one and say why in the request.

## 2. Run what you can yourself

- **T1** (host tests): run the commands the scope tool printed, or `.venv/bin/python scripts/verify-tests.py --plan fast`. In a new worktree, run `scripts/setup-worktree.sh` once first; it links the main checkout's `.venv` and `node_modules`.
- **T2** (compile for simulator and device): Mac sessions run it themselves with `scripts/xcodebuild-lane` (the two commands in `AGENTS.md`). The wrapper waits for a Mac-wide build slot, so a queue message isn't an error. Cloud sessions can't build; ask the lane.
- **T3 and up** need a simulator. Only the Test Desk session may boot one. In any other session the lane guard hook blocks `simctl boot/install/launch`, `xcodebuild test`, `verify-tests.py --plan app|adapters|...`, and opening Simulator.app. Don't work around it; ask the lane.

## 3. Ask the lane

1. Merge `origin/next` into your branch and push. The lane tests the pushed commit, not your working tree.
2. On your draft PR into `next`, post the request exactly in the format from test-lane.md, then add the `lane:queued` label:

   ```bash
   gh pr comment <pr> --body-file <request.txt>
   gh pr edit <pr> --add-label lane:queued
   ```

   A T3 request, for example:

   ```text
   /lane T3
   commit: 1bc676d
   changed: the Library remembers each tab's navigation
   tests: AppNavigationStateTests, Gate1AppModelWorkflowTests/testRestoresSelection
   watch for: tab switch resets the path
   not needed: T2 green on 1bc676d
   ```

   Keep it short.
   - For T3, put the app test classes or methods on their own `tests:` line. `scripts/test-scope.py` suggests them. The runner adds test-scope's classes for your diff anyway, so `tests:` only needs what those classes leave out.
   - For T4, `run:` names the journeys (`J1, J7`).
   - Use `scenario:` only for a one-off check, with numbered steps and what passing looks like.
   - `watch for:` names the specific risk.
   - `not needed:` lists what you already ran on this commit.
3. For T4/T5 on the Mac, you may also message the `test-desk` session as a doorbell ("lane request on PR #N"). The PR comment is always the real request.

**Who takes it.**
- **T2 and T3** go to the self-hosted runner. It starts within a minute or so of the label, or later if other PRs are queued. It tests your PR merged into `next`, on a temporary iOS 26.5 simulator for T3.
- **T4 and T5** go to the Test Desk.
- Ask for each tier in its own comment. The runner answers the newest T2/T3 request it hasn't reported on, and leaves `lane:queued` in place while a T4/T5 request is waiting.

**Newer pushes and repeats.**
- A newer push replaces a queued request: the lane tests only the newest commit.
- Asking again for the same commit, tier and tests after a PASS or FAIL gets a link to that report, not a rerun. After INCONCLUSIVE, asking again does run again.

## 4. Arm the PR, then move on

A PR is done when it's armed (`AGENTS.md`). Never stop before that:

1. Merge `origin/next` into your branch and push. GitHub builds the run from the PR's merge ref, which it doesn't refresh when `next` moves, so a branch last pushed before the lane workflow reached `next` (#221), or one that conflicts with `next`, gets no run.
2. If the diff needs T3, post the `/lane T3` request and add `lane:queued` (section 3). Adding a label that's already on the PR triggers nothing, so if `lane:queued` was already there (a T4 waiting), remove it and add it again. The PR must target `next` from a branch in this repository.
3. Add `automerge` once the issue's "Done when" holds, after the T3 request if there is one. The runner then runs the host tests and builds the diff needs, and runs again on every push while the label stays ([test-lane.md](../../../docs/workstreams/test-lane.md), Request format).
4. Post a short summary on the PR. Then take the next `ready` issue, or, above about 250,000 tokens of context, post a short note on the issue and stop (`AGENTS.md`).

**Don't retry or wait.** Once armed, don't watch for the run to start, don't re-check after a few minutes, and don't set timers, reminders or check-ins on your own PRs. The runner merges on PASS. What happens otherwise is the project's hourly dispatcher's job:
- **FAIL on the PR's own code**, or a conflict with `next`: the dispatcher gives the fix to whoever is free.
- **Runner fault** (no run starts, the runner is offline, or INCONCLUSIVE because of the lane: no simulator, XCTest never connected, a failed boot, a crash flood, low disk): the dispatcher asks for one more run, and files an issue labelled `ready` and `regression` only if it fails the same way again.

An INCONCLUSIVE T3 is re-run by a new `/lane T3` comment with the same `tests:` line plus `lane:queued`, because re-adding `automerge` starts only the host tests and builds. A fault in those is re-run by removing and re-adding `automerge`. An identical request for the same head and `next` commit that already has a PASS or FAIL report isn't run again; the lane links the earlier report.

## 5. Read a report (the dispatcher and fix-up threads)

The lane replies on the PR with `Lane report <id> — PASS | FAIL | INCONCLUSIVE`. The thread that armed the PR has moved on by then; this section is for the dispatcher and for the thread it gives a fix to.

- **INCONCLUSIVE is not a pass.** It means no simulator, XCTest never connected, a crash flood stopped the run, or `next` didn't merge into the head (the report names the files). The report says which. A merge conflict is the PR's to fix; the rest are runner faults. Don't treat it as green.
- **FAIL** names the step, what was expected, what was observed, and a local evidence path (`artifacts/lane/<id>/…` on the Mac). A fix-up thread fixes the first failure, pushes (the `automerge` label reruns the lane on every push), posts a new `/lane T3` request and adds `lane:queued` again if the FAIL was T3 (the runner swaps it for `lane:done` after each report). That re-arms the PR, and the thread moves on.
- **Held for T3.** A PR with a T3 request merges only on a T3 PASS. When an automerge run finished before the T3 report and was held, the lane job that reports the T3 PASS runs the automerge checks again itself and merges on PASS (#421). Nobody re-adds `automerge` for this.
- **Held for the Codex audit.** The runner won't merge an audio, persistence or packet diff until the newest "Codex audit (Astra) on `<sha7>`" comment names the PR's head commit and its verdict line opens with "No blocking findings" (#441). Confirmed findings go to whoever is free, like a FAIL. A clean audit that lands after the automerge run finished: the dispatcher removes and re-adds `automerge`, because a comment starts no run.
- **No run started.** Check the PR's base (`next`, from a branch in this repository), whether `next` has been merged in since the lane workflow last changed, and the runners: `gh api repos/uncomposed/spoken-margins-native/actions/runners` should show `sm-lane-mac online`.
- **"not verified"** lists what the lane can't check (audible content, Lock Screen, Bluetooth). Those belong to the owner's T6 pass, so carry them into your milestone report.
