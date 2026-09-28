---
name: lane-request
description: Pick the test tier for a Spoken Margins change and ask the Mac test lane for a T2–T5 run (app build, app-hosted XCTest, journeys) on a pushed commit, then read the lane report. Use before asking for any simulator or app test, when a milestone needs a lane report, or when a command was blocked by the lane guard.
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
   - For T3, put the app test classes or methods on their own `tests:` line. `scripts/test-scope.py` suggests them.
   - For T4, `run:` names the journeys (`J1, J7`).
   - Use `scenario:` only for a one-off check, with numbered steps and what passing looks like.
   - `watch for:` names the specific risk.
   - `not needed:` lists what you already ran on this commit.
3. For T4/T5 on the Mac, you may also message the `test-desk` session as a doorbell ("lane request on PR #N"). The PR comment is always the real request.

**Who takes it.**
- **T2 and T3** go to the self-hosted runner. It starts within a minute or so of the label, or later if other PRs are queued. It tests your PR merged into `next`, on a temporary iOS 26.5 simulator for T3.
- **T4 and T5** go to the Test Desk.
- Ask for each tier in its own comment. The runner answers the newest T2/T3 request it hasn't reported on, and leaves `lane:queued` in place while a T4/T5 request is waiting.

**When nothing happens.** If no run starts within about 2 minutes of labeling, merge `origin/next` into your branch and push. GitHub builds the run from the PR's merge ref, which it doesn't refresh when `next` moves, so a branch last pushed before the lane workflow reached `next`, or one that conflicts with `next`, gets no run until then. If it still doesn't start, check:
- **The PR's base.** It must target `next`, from a branch in this repository.
- **The label.** Adding a label that's already on the PR triggers nothing. If `lane:queued` is already there (a T4 waiting), remove it and add it again after posting your T2/T3 request.
- **The runner.** `gh api repos/uncomposed/spoken-margins-native/actions/runners` should show `sm-lane-mac online`. If it's offline, say so on the stream's tracking issue.

Once a run starts, the runner merges the newest `next` into your head itself, so the report tests against the current `next`. If that merge conflicts, you get an INCONCLUSIVE report naming the files.

**Newer pushes and repeats.**
- A newer push replaces a queued request: the lane tests only the newest commit.
- Asking again for the same commit, tier and tests after a PASS or FAIL gets a link to that report, not a rerun. After INCONCLUSIVE, asking again does run again.

## 4. Read the report

The lane replies on the PR with `Lane report <id> — PASS | FAIL | INCONCLUSIVE`.

- **INCONCLUSIVE is not a pass.** It means no simulator, XCTest never connected, or a crash flood stopped the run. The report says which. Fix the cause or ask again; don't treat it as green.
- **FAIL** names the step, what was expected, what was observed, and a local evidence path (`artifacts/lane/<id>/…` on the Mac). Fix the first failure before asking again.
- **"not verified"** lists what the lane can't check (audible content, Lock Screen, Bluetooth). Those belong to the owner's T6 pass, so carry them into your milestone report.
