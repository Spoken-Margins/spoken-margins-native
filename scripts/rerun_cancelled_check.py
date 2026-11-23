#!/usr/bin/env python3
"""Re-run a PR's required check once when its newest run on the PR head was cancelled and nothing replaced it (#4937).

GitHub reads a required check from the newest check run of that name on the commit (G4 in scripts/ci_harness.py). A
cancelled newest run blocks the PR, shows grey rather than red, and nothing in the pipeline starts it again:

- #4929: a re-arm's two label events started two `merge policy` runs in one second and the concurrency group
  cancelled the newer one; #4898, #4871 and #4830 sat armed with green checks for 2 to 5 hours.
- #4747: passing `hosted fast: portable` runs hit their time limit (which ends `cancelled`, not `timed_out`).
- A hosted Mac job that hangs to its `timeout-minutes` on a PR (`hosted web: build and Playwright`).

rerun-cancelled.yml runs this from main's copy when a `pull_request` run of a workflow that reports a required check
ends `cancelled`. It re-runs that run when all of these hold, and otherwise says why not and exits 0:

1. it was the run's first attempt (a re-run that is cancelled again is left alone: one retry, never a loop);
2. a PR it ran for is open, not a draft, carries `automerge`, and its head is still the run's commit (a run
   cancelled because a newer push replaced it is not re-run);
3. among the run's required checks none failed (hosted-portable's `stop-macs-on-red` cancels its own run when
   `portable` fails; that is a verdict, not a cancel);
4. the newest check run of at least one of those names on the head is this run's, cancelled.

It runs no PR code. The token needs `actions: write` for the re-run; a re-run asked for with GITHUB_TOKEN runs
(G6, observed 2026-11-22). Stdlib plus `gh`.

Run: `python3 scripts/rerun_cancelled_check.py --repo owner/name --run-id <id>`.
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys

sys.path.insert(0, __file__.rsplit('/', 1)[0])
from required_checks import REQUIRED_CHECKS  # noqa: E402

ARM_LABEL = 'automerge'
RUN_IN_URL = re.compile(r'/actions/runs/(\d+)(?:/|$)')


class GitHub:
    """The `gh api` calls this script makes. The tests and scripts/ci_harness.py replace it at this boundary."""

    def __init__(self, repo):
        self.repo = repo

    def get(self, path):
        done = subprocess.run(['gh', 'api', f'repos/{self.repo}/{path}'], text=True, capture_output=True, timeout=60,
                              check=True)
        return json.loads(done.stdout)

    def rerun(self, run_id):
        subprocess.run(['gh', 'api', '-X', 'POST', f'repos/{self.repo}/actions/runs/{run_id}/rerun'], text=True,
                       capture_output=True, timeout=60, check=True)


def run_of(check: dict) -> int | None:
    for key in ('details_url', 'html_url'):
        match = RUN_IN_URL.search(str(check.get(key) or ''))
        if match:
            return int(match.group(1))
    return None


def abandoned(check: dict) -> bool:
    """A check run still `in_progress` or `queued` in a run that has ended cancelled: it can never finish, so it blocks
    the merge like a cancelled one. `merge policy` writes its own check run, and a runner that is cancelled, times out or
    is lost kills the script before it can mark it (#4986, the audit of #5011); GitHub only marks job checks itself."""
    return check.get('conclusion') is None and check.get('status') in ('in_progress', 'queued', 'waiting', 'pending')


def decide(run: dict, pulls: list[dict], checks: list[dict]) -> tuple[bool, str]:
    """(re-run?, why) for one cancelled workflow run, the PRs it ran for and every check run on its head commit."""
    if run.get('event') != 'pull_request':
        return False, f'a {run.get("event")} run, not a PR\'s'
    if run.get('conclusion') != 'cancelled':
        return False, f'it ended {run.get("conclusion")}, not cancelled'
    if int(run.get('run_attempt') or 1) > 1:
        return False, f'attempt {run.get("run_attempt")} was cancelled too; one re-run only'
    head = run.get('head_sha')
    armed = [p for p in pulls if p.get('state') == 'open' and not p.get('draft')
             and (p.get('head') or {}).get('sha') == head
             and ARM_LABEL in {label.get('name') for label in p.get('labels') or []}]
    if not armed:
        return False, 'no open, armed PR has this run\'s commit as its head'
    run_id = int(run['id'])
    names = set(REQUIRED_CHECKS)
    mine = [c for c in checks if c.get('name') in names and run_of(c) == run_id]
    if any(c.get('conclusion') in ('failure', 'timed_out') for c in mine):
        return False, 'one of its required checks failed: a verdict, not a cancel'
    blocked = []
    for name in sorted({c['name'] for c in mine}):
        newest = max((c for c in checks if c.get('name') == name), key=lambda c: int(c.get('id') or 0))
        if run_of(newest) == run_id and (newest.get('conclusion') == 'cancelled' or abandoned(newest)):
            blocked.append(name)
    if not blocked:
        return False, 'a newer run of each of its required checks is on the head'
    return True, f'its cancelled run is the newest "{", ".join(blocked)}" on #{armed[0]["number"]}\'s head'


def main(argv=None, github=None, out=sys.stdout) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    parser.add_argument('--repo', required=True)
    parser.add_argument('--run-id', required=True, type=int)
    args = parser.parse_args(argv)
    github = github or GitHub(args.repo)
    try:
        run = github.get(f'actions/runs/{args.run_id}')
        pulls = [github.get(f'pulls/{p["number"]}') for p in run.get('pull_requests') or []]
        checks = github.get(f'commits/{run["head_sha"]}/check-runs?filter=all&per_page=100').get('check_runs', [])
        go, why = decide(run, pulls, checks)
        if go:
            github.rerun(args.run_id)
        print(f'run {args.run_id} ({run.get("name")}): {"re-run" if go else "left alone"}: {why}', file=out)
    except (subprocess.SubprocessError, OSError, ValueError, KeyError) as error:
        # A failed read or re-run is only logged: the merge-stall watch still sees a stuck PR.
        print(f'::warning::run {args.run_id}: could not finish ({error!r})', file=out)
    return 0


if __name__ == '__main__':
    sys.exit(main())
