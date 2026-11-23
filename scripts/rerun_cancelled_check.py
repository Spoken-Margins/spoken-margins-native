#!/usr/bin/env python3
"""Re-run a PR's required check once when its newest run on the PR head was cancelled, or failed outside the PR (#4937, #5057).

GitHub reads a required check from the newest check run of that name on the commit (G4 in scripts/ci_harness.py). A
cancelled newest run blocks the PR, shows grey rather than red, and nothing in the pipeline starts it again:

- #4929: a re-arm's two label events started two `merge policy` runs in one second and the concurrency group
  cancelled the newer one; #4898, #4871 and #4830 sat armed with green checks for 2 to 5 hours.
- #4747: passing `hosted fast: portable` runs hit their time limit (which ends `cancelled`, not `timed_out`).
- A hosted Mac job that hangs to its `timeout-minutes` on a PR (`hosted web: build and Playwright`).

A run that failed only in a setup step, or in a plan step whose log ends in a network error from an outside host
(merge_queue_dequeued.failed_outside_pr, the same reading the dequeue notifier makes of a merge group, #4940), failed
for the runner's or the network's reasons, not the PR's: the onnxruntime certificate outage of 2026-11-21 (#4795), a
runner that fails in `Set up job`, the Playwright CDN down for the web job (not Hugging Face: the speech model downloads
inside `Playwright suite`, a test step). A log tail that shows a failed test is always the PR's. On a PR no merge group
exists, so the notifier never sees it, and the check stayed red until a person re-ran it (#5057).

rerun-cancelled.yml runs this from main's copy when a `pull_request` run of a workflow that reports a required check
ends `cancelled` or `failure`. It re-runs that run when all of these hold, and otherwise says why not and exits 0:

1. it was the run's first attempt (a re-run that ends the same way is left alone: one retry, never a loop);
2. a PR it ran for is open, not a draft, carries `automerge`, and its head is still the run's commit (a run
   replaced by a newer push is not re-run);
3. if any job of the run failed, every failed job failed outside the PR (above); a failed test step, a step
   merge_queue_dequeued does not know, or a log it cannot read is the PR's verdict and is left red. hosted-portable's
   `stop-macs-on-red` cancels its own run when `portable` fails, so a cancelled run is read the same way;
4. the newest check run of at least one of the run's required checks on the head is this run's, cancelled or failed.

A run that failed outside the PR is re-run only after RETRY_DELAY_MINUTES, so an outage has time to end, and the
four conditions are read again after the wait (a person may have re-run it or pushed meanwhile). A cancelled run is
re-run at once, as before.

It runs no PR code. The token needs `actions: write` for the re-run; a re-run asked for with GITHUB_TOKEN runs
(G6, observed 2026-11-22). Stdlib plus `gh`.

Run: `python3 scripts/rerun_cancelled_check.py --repo owner/name --run-id <id>`.
"""
from __future__ import annotations

import argparse
import re
import subprocess
import sys
import time

sys.path.insert(0, __file__.rsplit('/', 1)[0])
import merge_queue_dequeued as dequeued  # noqa: E402
from required_checks import REQUIRED_CHECKS  # noqa: E402

ARM_LABEL = 'automerge'
RUN_IN_URL = re.compile(r'/actions/runs/(\d+)(?:/|$)')
FAILED = dequeued.FAILED
# A Default taken (#5057): long enough that the harness's 90-minute outage (`outage-90m` in scripts/ci_harness.py)
# has ended when the re-run starts, for the 12-minute web job and the 25-minute portable job alike. A PR's own check
# blocks only that PR, so a long wait costs one PR's time, not the queue's; the merge-queue retry stays at 30 minutes
# (merge_queue_dequeued.SETUP_RETRY_DELAY). rerun-cancelled.yml's `timeout-minutes` must exceed it.
RETRY_DELAY_MINUTES = 90


class GitHub:
    """The `gh api` calls this script makes. The tests and scripts/ci_harness.py replace it at this boundary."""

    def __init__(self, repo):
        self.repo = repo

    def get(self, path):
        # merge_queue_dequeued's reads try three times, so one `gh api` hiccup before or after the wait does not end
        # the retry (review of #5057).
        return dequeued.GitHub(self.repo).get(path)

    def rerun(self, run_id):
        subprocess.run(['gh', 'api', '-X', 'POST', f'repos/{self.repo}/actions/runs/{run_id}/rerun'], text=True,
                       capture_output=True, timeout=60, check=True)

    def log_tail(self, job_id):
        """The failing step's last log lines, read as the dequeue notifier reads them (raises dequeued.ReadFailed)."""
        return dequeued.GitHub(self.repo).log_tail(job_id)

    def wait(self, minutes):
        time.sleep(minutes * 60)


def run_of(check: dict) -> int | None:
    for key in ('details_url', 'html_url'):
        match = RUN_IN_URL.search(str(check.get(key) or ''))
        if match:
            return int(match.group(1))
    return None


def decide(run: dict, pulls: list[dict], checks: list[dict], outside=None, waited=True) -> tuple[str, str]:
    """('rerun' | 'wait' | 'leave', why) for one cancelled or failed workflow run, the PRs it ran for and every check
    run on its head commit. `outside(failed check runs)` is merge_queue_dequeued.failed_outside_pr's answer; without it
    a failed job is always the PR's. 'wait' means re-run after RETRY_DELAY_MINUTES once the run has been read again
    (`waited` says that wait is over)."""
    if run.get('event') != 'pull_request':
        return 'leave', f'a {run.get("event")} run, not a PR\'s'
    if run.get('conclusion') not in ('cancelled', 'failure'):
        return 'leave', f'it ended {run.get("conclusion")}, not cancelled or failed'
    if int(run.get('run_attempt') or 1) > 1:
        return 'leave', f'attempt {run.get("run_attempt")} ended {run.get("conclusion")} too; one re-run only'
    head = run.get('head_sha')
    armed = [p for p in pulls if p.get('state') == 'open' and not p.get('draft')
             and (p.get('head') or {}).get('sha') == head
             and ARM_LABEL in {label.get('name') for label in p.get('labels') or []}]
    if not armed:
        return 'leave', 'no open, armed PR has this run\'s commit as its head'
    run_id = int(run['id'])
    names = set(REQUIRED_CHECKS)
    ours = [c for c in checks if run_of(c) == run_id]
    mine = [c for c in ours if c.get('name') in names]
    failed = [c for c in ours if c.get('conclusion') in FAILED]
    if run.get('conclusion') == 'failure' and not failed:
        # The failed job is not in the check-run listing (one page of 100): never read that as a cancel (review).
        return 'leave', 'it failed, but no failed job of it is in the check-run listing'
    if failed:
        if outside is None:
            return 'leave', 'one of its jobs failed: a verdict, not a cancel'
        is_outside, seen = outside(failed)
        where = '; '.join(f'"{name}" in "{step}"' for name, step in seen) or 'no failed step could be read'
        if not is_outside:
            return 'leave', f'a job failed in the PR\'s own code or a step not known to be setup ({where}): a verdict'
    blocked = []
    for name in sorted({c['name'] for c in mine}):
        newest = max((c for c in checks if c.get('name') == name), key=lambda c: int(c.get('id') or 0))
        if run_of(newest) == run_id and newest.get('conclusion') in ('cancelled', *FAILED):
            blocked.append(name)
    if not blocked:
        return 'leave', 'a newer run of each of its required checks is on the head'
    on = f'"{", ".join(blocked)}" on #{armed[0]["number"]}\'s head'
    if not failed:
        return 'rerun', f'its cancelled run is the newest {on}'
    if not waited:
        return 'wait', f'every failed job failed outside the PR ({where}); it is the newest {on}'
    return 'rerun', f'every failed job failed outside the PR ({where}), and after the wait it is still the newest {on}'


def main(argv=None, github=None, out=sys.stdout) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    parser.add_argument('--repo', required=True)
    parser.add_argument('--run-id', required=True, type=int)
    parser.add_argument('--waited', action='store_true',
                        help='the retry delay has already passed (scripts/ci_harness.py runs the second read this way)')
    args = parser.parse_args(argv)
    github = github or GitHub(args.repo)

    def read():
        run = github.get(f'actions/runs/{args.run_id}')
        pulls = [github.get(f'pulls/{p["number"]}') for p in run.get('pull_requests') or []]
        checks = github.get(f'commits/{run["head_sha"]}/check-runs?filter=all&per_page=100').get('check_runs', [])
        return run, pulls, checks

    def outside(failed):
        return dequeued.failed_outside_pr(github, failed)

    try:
        run, pulls, checks = read()
        action, why = decide(run, pulls, checks, outside=outside, waited=args.waited)
        if action == 'wait':
            print(f'run {args.run_id} ({run.get("name")}): waiting {RETRY_DELAY_MINUTES} minutes: {why}', file=out,
                  flush=True)
            github.wait(RETRY_DELAY_MINUTES)
            run, pulls, checks = read()
            action, why = decide(run, pulls, checks, outside=outside, waited=True)
        if action == 'rerun':
            github.rerun(args.run_id)
        print(f'run {args.run_id} ({run.get("name")}): {"re-run" if action == "rerun" else "left alone"}: {why}',
              file=out)
    except (subprocess.SubprocessError, OSError, ValueError, KeyError, dequeued.ReadFailed) as error:
        # A failed read or re-run is only logged: the merge-stall watch still sees a stuck PR.
        print(f'::warning::run {args.run_id}: could not finish ({error!r})', file=out)
    return 0


if __name__ == '__main__':
    sys.exit(main())
