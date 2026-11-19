#!/usr/bin/env python3
"""Start an armed PR's merge run again when the hosted checks it was waiting for have finished.

The hosted automerge job used to sleep on a hosted Linux runner until hosted-portable.yml finished, up to two hours,
and each sleeper held one of the org's 20 concurrent hosted slots (2026-11-19: 8 of 15 running Linux jobs, with 84
Linux and 22 Mac jobs queued). It now exits after about 8 minutes with checks still running (lane-runner.py, WAITING)
and posts nothing. This script is what picks the PR up again. .github/workflows/lane-rearm.yml runs it when
hosted-portable.yml or hosted-web.yml completes on a commit: for each open same-repo PR into the trunk whose head is
that commit and that still carries `automerge`, it dispatches lane.yml with the PR, the head and auto=true, as the
audit does (#2170). The `release` job that runs re-reads the PR and checks, merges on green, reports a FAIL on red,
and does nothing for a PR that moved on, closed or lost the label, so an extra dispatch is harmless.

A cancelled check run is started again too (the merge run starts the checks again itself), but nothing starts again once
the head has had RUN_LIMIT hosted runs, whatever they ended with: the merge run's own 3-redispatch cap resets with every
new job, so this is what stops a loop. A failed dispatch fails the workflow run, so it shows red.

Run from the trunk's copy, never the PR's: `python3 scripts/lane_rearm.py --head <sha> --conclusion success`.
"""
import argparse
import json
import os
import subprocess
import sys

REARM_CONCLUSIONS = ('success', 'failure', 'timed_out', 'cancelled')
RUN_LIMIT = 8  # hosted runs on one head (both workflows, any conclusion) after which nothing starts again
HOSTED_WORKFLOWS = ('hosted-portable.yml', 'hosted-web.yml')
ARMED = 'automerge'


class GitHubApi:
    def __init__(self, repo):
        self.repo = repo

    def get(self, path):
        return json.loads(subprocess.run(['gh', 'api', f'repos/{self.repo}/{path}'], text=True, timeout=30,
                                         capture_output=True, check=True).stdout)

    def dispatch_lane(self, trunk, pr, head):
        subprocess.run(['gh', 'api', '-X', 'POST', f'repos/{self.repo}/actions/workflows/lane.yml/dispatches',
                        '-f', f'ref={trunk}', '-f', f'inputs[pr]={pr}', '-f', f'inputs[head]={head}',
                        '-f', 'inputs[auto]=true'], text=True, timeout=30, capture_output=True, check=True)


def armed_prs_on(api, trunk: str, head: str) -> list[int]:
    """Open PRs from this repository into <trunk> whose head is <head> and that carry automerge. Asked of the commit,
    not the PR list, so a backlog of more than 100 open PRs cannot hide one."""
    found = []
    for pull in api.get(f'commits/{head}/pulls?per_page=100'):
        if pull.get('state') != 'open' or pull['head']['sha'] != head or pull['base']['ref'] != trunk:
            continue
        if (pull['head'].get('repo') or {}).get('full_name') != api.repo:
            continue
        if ARMED in {label['name'] for label in pull.get('labels', [])}:
            found.append(pull['number'])
    return found


def hosted_runs_on(api, head: str) -> int:
    total = 0
    for workflow in HOSTED_WORKFLOWS:
        total += api.get(f'actions/workflows/{workflow}/runs?head_sha={head}&per_page=1')['total_count']
    return total


def rearm(api, trunk: str, head: str, conclusion: str, out=sys.stdout) -> tuple[list[int], list[int]]:
    """(the PRs a merge run was dispatched for, the PRs whose dispatch failed)."""
    if conclusion not in REARM_CONCLUSIONS:
        print(f'{conclusion or "no conclusion"}: nothing to start again', file=out)
        return [], []
    # The merge run starts a stale or missing check again itself, up to 3 times per job, and each job is new: this
    # is the cap across jobs, whatever the runs ended with, so a check that never records its result cannot loop.
    if hosted_runs_on(api, head) >= RUN_LIMIT:
        print(f'{head[:7]}: {RUN_LIMIT} hosted runs already; not starting the merge run again', file=out)
        return [], []
    started, failed = [], []
    for pr in armed_prs_on(api, trunk, head):
        try:
            api.dispatch_lane(trunk, pr, head)
        except (OSError, subprocess.SubprocessError) as error:
            print(f'::error::PR #{pr}: could not start its merge run ({error!r})', file=out)
            failed.append(pr)
            continue
        print(f'PR #{pr}: hosted checks on {head[:7]} ended {conclusion}; started its merge run', file=out)
        started.append(pr)
    return started, failed


def main(argv=None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument('--repo', default=os.environ.get('GH_REPO', ''))
    parser.add_argument('--trunk', default=os.environ.get('SM_TRUNK') or 'main')
    parser.add_argument('--head', required=True)
    parser.add_argument('--conclusion', default='')
    args = parser.parse_args(argv)
    if len(args.head) != 40 or not all(c in '0123456789abcdef' for c in args.head) or not args.repo:
        print('::warning::lane_rearm needs a full head SHA and a repository; nothing started.')
        return 0
    try:
        _, failed = rearm(GitHubApi(args.repo), args.trunk, args.head, args.conclusion)
        if failed:
            return 1
    except (OSError, subprocess.SubprocessError, ValueError, KeyError) as error:
        # A failed read starts nothing and the red run says so; a push, label or audit dispatch also runs it.
        print(f'::error::lane_rearm could not finish ({error!r}).')
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
