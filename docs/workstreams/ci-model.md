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
3. **The repository's own decisions are not copied.** The label bridge, the dequeue notifier, the merge-policy
   rules (`lane-runner.py merge_blockers`, `test-scope.py classify`), the audit's eligibility
   (`sm_codex_audit.py evaluate`) and the Mac-check scope (`test-scope.py mac_checks_required`) are imported from the
   tree under test and run against a fake GitHub. A change to them shows up in `--diff`.

State that is not in the files is the dated `SNAPSHOT` in the script: the "protect main" ruleset, variables, secret
names, disabled workflows, and how often GitHub actually ran the schedules. By default schedules fire as observed
(the audit about every 8 hours, the bridge sweep about every 12, against 15-minute crons); scenario `c2` shows the
nominal cron.

## Assumptions

Every rule taken on trust is in `ASSUMPTIONS`, marked documented, observed or inferred, with its source. The ones
that matter most and are not verified: a re-run asked for with `GITHUB_TOKEN` runs (A6); a failed merge group turns
auto-merge off (A9, scenario `d2` shows the loop if it does not); merge-group events start runs whoever queued the
PR (A8).

## Limits

- One PR at a time. Groups of several PRs, queue ordering and HEADGREEN grouping are not modelled.
- Runs take no time, so races appear only when a scenario sets one up (`b3`).
- A job with no behaviour in `BEHAVIOURS` succeeds and does nothing.
- In `--diff`, helper modules that the imported scripts load by name (for example `comment_trust`) come from the
  first tree loaded.
- It adds no recurring cost: nothing runs it but a person or an agent.
