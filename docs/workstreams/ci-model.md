# CI model

`scripts/ci_model.py` is an offline model of how a PR moves from arming to merged. Use it to test a change to the
pipeline (a workflow, the label bridge, the merge policy, the audit) before it lands, instead of finding out on `main`.

## Running it

- `.venv/bin/python scripts/ci_model.py` runs every scenario against the working tree and prints one line each.
- `.venv/bin/python scripts/ci_model.py --scenario b-lane-no-audit` prints one scenario's event log and the chain of
  events that merged it.
- `.venv/bin/python scripts/ci_model.py --diff origin/main` compares `main` with the working tree;
  `--diff origin/main origin/<branch>` compares two refs. It lists the static changes (triggers, `if:`, tokens,
  check names, script effects) and every scenario whose outcome changes.
- `.venv/bin/python scripts/ci_model.py --extract` prints the static model as JSON.
- `--live` re-reads the ruleset, variables, secret names and disabled workflows with `gh` instead of the snapshot.
- `--diff <ref>` imports and runs that tree's scripts on your machine, so never point it at an untrusted branch.

A CI PR should say what `--diff origin/main` printed, and update `scripts/tests/test_ci_model.py` in the same PR when
an outcome changes on purpose.

## What it models

1. **Static model.** Read from `.github/workflows/*.yml` on every run: triggers (events, types, branches, paths,
   crons, upstream workflows), concurrency groups, jobs with their `if:` and check names, variables and secrets read,
   the token each job writes with (`GH_TOKEN`), and what the scripts it runs do (label changes, comments,
   dispatches, re-runs, queueing, pushes), each with `file:line`.
2. **GitHub's side.** Which event starts which workflow, `if:` evaluation (a small evaluator for GitHub
   expressions), the rule that events caused by `GITHUB_TOKEN` start nothing except dispatches, required checks,
   auto-merge, merge groups, the queue's timeout, and dequeueing.
3. **The repository's own decisions are not copied.** These run from the tree under test against a fake GitHub,
   so a change to them shows up in `--diff`:
   - the label bridge (`merge_queue_label_bridge.main`) and the dequeue notifier (`merge_queue_dequeued.notify`);
   - the merge policy (`merge_policy.blockers`, with its git reads replaced by the scenario's paths);
   - the `rearm` jobs (`lane_rearm.main`, with `--results` rendered from the workflow step);
   - the audit's eligibility (`sm_codex_audit.evaluate`, `owner_tap_alert.checks_state`) and its merge policy re-run
     (`sm_codex_audit.rerun_merge_policy`);
   - the Mac-check scope (`test-scope.py mac_checks_required`).

State that is not in the files is the dated `SNAPSHOT` in the script: the "protect main" ruleset, variables, secret
names, disabled workflows, and how often GitHub actually ran the schedules. By default schedules fire as observed
(the audit about every 8 hours, the bridge sweep about every 12, against 15-minute crons); scenario `c2` shows the
nominal cron.

## The timed harness (#4937)

`scripts/ci_model.py` runs one PR with every run finishing at once, so it could not see the faults that reached live
PRs on 2026-11-20 to 22: a re-arm whose two label events left the newest `merge policy` run cancelled (#4929), a
queue entry that timed out and disarmed its PR, a token the bridge was refused with no word anywhere, a portable job
at its time limit ending grey (#4747). `scripts/ci_harness.py` reuses this model's static extraction, expression
evaluator and the tree's own decision code, and adds time, concurrency groups as GitHub runs them, the newest-check
rule, the queue's admission, black-box Mac jobs (pass, fail, hang to the time limit, cancel, run past the queue's
timeout, never get a runner), download outages, token refusals, dropped schedules and the VPS backstop. Its docstring
lists the GitHub rules it assumes and the invariants it checks.

- `.venv/bin/python scripts/ci_harness.py --check` runs every combination (418 on 2026-11-22, about 35 seconds) and fails on a stuck,
  silent, looping or broken-merge case that `KNOWN` does not list, on a `KNOWN` entry that no longer happens, and on
  a static finding (workflow-level concurrency over jobs that skip on the label; a required job skipped when an
  unrequired job it needs fails; a required check no job reports). The `hosted fast: portable` job runs it on every
  PR and merge group, so a pipeline change has to pass it before it merges.
- `--diff origin/main` lists the violations a branch adds or fixes; `--one <kind> <arming> <fault> <admission>`
  prints one combination's event log; `--check-snapshot` compares the ruleset in `SNAPSHOT` with the live one.
- `scripts/tests/test_ci_harness.py` puts fixed faults back into the in-memory model (the merge-policy group, the
  web job's skip, a required check nobody reports) and expects the harness to see them again.

A PR that changes the pipeline says what `--diff origin/main` printed. When it fixes a `KNOWN` entry, it removes it.

### What it would have caught (retrospective, 2026-11-22)

Each fix is replayed with `ci_harness.py --diff <merge>^1 <merge>` where the older tree still loads; trees before
`scripts/lane_merge_rules.py` (#4769) do not, and for those the row names the fault class that covers the case.

| Fix | What happened live | `ci_model.py` | `ci_harness.py` |
| --- | --- | --- | --- |
| #4930 (#4929) | A re-arm's two label events left the newest `merge policy` run cancelled; #4898, #4871, #4830 waited 2 to 5 hours | missed (runs take no time) | caught: 26 combinations stuck before the commit, none after |
| #4849 (#4843) | Audio and persistence PRs were never audited, so they never merged (#4666, 37 hours) | missed | caught: before the commit an audio PR with no fault never merges (62 combinations fixed) |
| #4888 (#4867) | A required check that never ran on a PR head | missed | missed: neither models a check added to the ruleset after the head was pushed |
| #4752 | A cancelled queue entry disarmed its PR | missed | covered by `mac-cancel-once`; still stuck on `main` until #4937 (9 combinations); the older tree does not load |
| #4747 | A passing portable run at its time limit ended `cancelled`, grey, and nothing re-ran it | missed | covered by `portable-timeout-once`: 35 combinations fixed by #4937's re-run |
| #4753, #4755 | Audit before the hosted checks; the re-arm job standing down | caught in hindsight | the older trees do not load |
| #4746, #4754 | Audit without the lane; the merge audit trusting the queue | missed | the older trees do not load |
| #4835 (#4795) | download.onnxruntime.ai's bad certificate failed Mac jobs; each PR was re-armed by hand | missed | caught as `outage-90m` / `needs-person`. #4940 (merge-queue half) reads the failing step and retries a setup failure once after 30 minutes: `mac-fail-once` and `mac-download-fail-once` now merge on the Mac-in-queue kinds; a failed test (`mac-test-fail-once`) is still held at once. `outage-90m` and the web kind stay in `KNOWN` (#5057: the failing check is on the PR itself, and `rerun-cancelled.yml` re-runs only a cancelled run) |
| #4937 | The bridge's token refused (403), or expired (401 on every read, found by #4942's audit), with no word on the PR; a timed-out queue entry disarmed; workflow-level groups in two more workflows; the web check skipped (= passed) when change detection failed | missed | caught: 42 + 9 combinations, and the static rules |

Against `main` at b825e9dd, over the first 376 combinations, #4937 fixes 134 of 222 violating ones and moves 9 more
from silent to told or slow. The expired-token fault added after #4942's audit adds 42 combinations, all of them told
on the PR. After #4940 the harness runs 460 combinations (42 added: a Mac job that fails in a download, and one that fails a test) and 81 violations are left, all in `KNOWN`: outages and one-off failures of a PR-level check (#5057), dropped schedules with the
backstop down (#4866, now reported by the wake sweep's rule 15), and GitHub's runner pool.

## Assumptions

Every rule taken on trust is in `ASSUMPTIONS`, marked documented, observed or inferred, with its source. The ones
that matter most and are not verified: a re-run asked for with `GITHUB_TOKEN` runs (A6); a failed merge group turns
auto-merge off (A9, scenario `d2` shows the loop if it does not); merge-group events start runs whoever queued the
PR (A8).

## Limits

- One PR at a time. Groups of several PRs, queue ordering and HEADGREEN grouping are not modelled (nor in the
  harness).
- Runs take no time, so races appear only when a scenario sets one up (`b3`). The harness adds time.
- Neither models a required check added to the ruleset after a PR's head was pushed (#4867, #4888).
- A job with no behaviour in `BEHAVIOURS` succeeds and does nothing.
- In `--diff`, helper modules that the imported scripts load by name (for example `comment_trust`) come from the
  first tree loaded.
- Some decisions are still read or written by hand, so a change to them does not show in `--diff`:
  - the web paths (a `grep` in `hosted-web.yml`) are read from the YAML text with a regular expression, so a reworded
    step falls back to a default. The docs-only rule (inline Python in `hosted-portable.yml`) is not: the model runs
    the step's own Python, and a step that no longer has it stops the model with an error (#5048);
  - the audit's candidate loop (when it reads the head's checks) mirrors `sm_codex_audit.py` around line 866, and it
    assumes the re-run is called after every posted audit inside a workflow;
  - main-t3's `decide`, and which job catches which defect (`DEFECT_CATCHERS`, assumption A15).

## Cost and catch

`scripts/tests/test_ci_model.py` runs in CI. It is discovered by the fast plan's `runner-tests` step
(`scripts/verify-tests.py`, in `PORTABLE_STEPS` and `MAC_REST_STEPS`), and the portable split runs it; the Mac-rest
split's `runner-tests` keeps only the tests that drive Apple tools, so it skips this file.

1. Cost: about 6 s of runner time per portable run, no tokens and no clicks. The model itself runs only when a
   person or an agent runs it.
2. Frequency: every PR whose portable job runs `runner-tests`, plus local fast runs.
3. Catch: a change to the workflows or the scripts the model imports that breaks the model, or that makes a
   scenario impossible (a docs PR armed by a person no longer merges, a failed group merges). The tests are written
   so that a CI fix never turns them red: a current defect (b4) is pinned on a fixture tree with a stub
   `lane_rearm.py`, and on the working tree a stuck outcome is only checked for naming its cause.
4. Waste signal: the file goes red for a change that broke nothing in the pipeline, twice; or a CI change lands
   without anyone reading `--diff`, so the model is kept up for nobody.
