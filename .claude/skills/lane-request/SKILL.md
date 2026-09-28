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

- **T1** (host tests): run the commands the scope tool printed, or `.venv/bin/python scripts/verify-tests.py --plan fast`.
- **T2** (compile for simulator and device): Mac sessions run it themselves with `scripts/xcodebuild-lane` (the two commands in `AGENTS.md`). The wrapper waits for a Mac-wide build slot, so a queue message isn't an error. Cloud sessions can't build; ask the lane.
- **T3 and up** need a simulator. Only the Test Desk session may boot one. In any other session the lane guard hook blocks `simctl boot/install/launch`, `xcodebuild test`, `verify-tests.py --plan app|adapters|...`, and opening Simulator.app. Don't work around it; ask the lane.

## 3. Ask the lane

1. Merge `origin/next` into your branch and push. The lane tests the pushed commit, not your working tree.
2. On your draft PR into `next`, post the request exactly in the format from test-lane.md, then add the `lane:queued` label:

   ```bash
   gh pr comment <pr> --body-file <request.txt>
   gh pr edit <pr> --add-label lane:queued
   ```

   Keep it short. `run:` names journeys (`J1, J7`) or `tests: <Class>/<method>` for T3. Use `scenario:` only for a one-off check, with numbered steps and what passing looks like. `watch for:` names the specific risk. `not needed:` lists what you already ran on this commit.
3. On the Mac you may also message the `test-desk` session as a doorbell ("lane request on PR #N"). The PR comment is always the real request.

A newer push to the same PR replaces a queued request: the lane tests only the newest commit.

## 4. Read the report

The lane replies on the PR with `Lane report <id> — PASS | FAIL | INCONCLUSIVE`.

- **INCONCLUSIVE is not a pass.** It means no simulator, XCTest never connected, or a crash flood stopped the run. The report says which. Fix the cause or ask again; don't treat it as green.
- **FAIL** names the step, what was expected, what was observed, and a local evidence path (`artifacts/lane/<id>/…` on the Mac). Fix the first failure before asking again.
- **"not verified"** lists what the lane can't check (audible content, Lock Screen, Bluetooth). Those belong to the owner's T6 pass, so carry them into your milestone report.
