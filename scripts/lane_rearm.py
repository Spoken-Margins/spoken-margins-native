#!/usr/bin/env python3
"""Start an armed PR's merge run again when the hosted checks it was waiting for have finished.

The hosted automerge job used to sleep on a hosted Linux runner until hosted-portable.yml finished, up to two hours,
and each sleeper held one of the org's 20 concurrent hosted slots (2026-11-19: 8 of 15 running Linux jobs, with 84
Linux and 22 Mac jobs queued). It now exits after about 8 minutes with checks still running (lane-runner.py, WAITING)
and posts nothing. This script is what picks the PR up again. The last job of hosted-portable.yml and of
hosted-web.yml (`rearm`, after every other job, `if: always()`) runs it when its workflow run is over: for each open same-repo PR into the trunk whose head is
that commit and that still carries `automerge`, it dispatches lane.yml with the PR, the head and auto=true, as the
audit does (#2170). The `release` job that runs re-reads the PR and checks, merges on green, reports a FAIL on red,
and does nothing for a PR that moved on, closed or lost the label, so an extra dispatch is harmless.

A cancelled check run is started again too (the merge run starts the checks again itself), but nothing starts again once
the head has had RUN_LIMIT hosted runs, whatever they ended with: the merge run's own 3-redispatch cap resets with every
new job, so this is what stops a loop. A failed dispatch fails the workflow run, so it shows red.

It runs inside the hosted workflows, not as a workflow_run trigger: GitHub starts no workflow_run for a run caused by
GITHUB_TOKEN, and the hosted-portable runs the lane dispatches itself (actor github-actions[bot], about two in three of
them on 2026-11-19) would never have started it, so PRs like #4603 stayed unmerged with every check green. A
workflow_dispatch sent with GITHUB_TOKEN does start a run, so the dispatch below works from either kind of run.

Run from the trunk's copy, never the PR's: `python3 scripts/lane_rearm.py --head <sha> --results "success skipped"`.
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

    def dispatch_lane(self, ref, pr, head):
        subprocess.run(['gh', 'api', '-X', 'POST', f'repos/{self.repo}/actions/workflows/lane.yml/dispatches',
                        '-f', f'ref={ref}', '-f', f'inputs[pr]={pr}', '-f', f'inputs[head]={head}',
                        '-f', 'inputs[auto]=true'], text=True, timeout=30, capture_output=True, check=True)


LANE_CHECK = 'lane-check/'  # bases that exist only to test a change to the lane (lane.yml); their release job takes these refs


def armed_prs_on(api, trunk: str, head: str) -> list[tuple[int, str]]:
    """(number, base branch) of the open PRs from this repository into <trunk> or a lane-check/** base whose head is
    <head> and that carry automerge. Asked of the commit, not the PR list, so a backlog of more than 100 open PRs
    cannot hide one. The merge run is dispatched on the PR's own base, as lane.yml's release job requires: the trunk, or
    the lane-check base that carries the lane change under test."""
    found = []
    for pull in api.get(f'commits/{head}/pulls?per_page=100'):
        base = pull['base']['ref']
        if pull.get('state') != 'open' or pull['head']['sha'] != head:
            continue
        if base != trunk and not base.startswith(LANE_CHECK):
            continue
        if (pull['head'].get('repo') or {}).get('full_name') != api.repo:
            continue
        if ARMED in {label['name'] for label in pull.get('labels', [])}:
            found.append((pull['number'], base))
    return found


def conclusion_of(results: str) -> str:
    """One conclusion for a workflow run from its jobs' `needs.*.result` values (space separated). Any failure is
    `failure`, else any cancellation is `cancelled`, else any success is `success`; all skipped (or nothing) is `skipped`,
    which starts nothing."""
    seen = set(results.split())
    for result in ('failure', 'cancelled', 'success'):
        if result in seen:
            return result
    return 'skipped'


def hosted_runs_on(api, head: str) -> int:
    total = 0
    for workflow in HOSTED_WORKFLOWS:
        total += api.get(f'actions/workflows/{workflow}/runs?head_sha={head}&per_page=1')['total_count']
    return total


def active_runs_on(api, head: str) -> int:
    """Hosted runs of this head that are queued or still running, this workflow run included."""
    total = 0
    for workflow in HOSTED_WORKFLOWS:
        for status in ('queued', 'in_progress', 'waiting', 'pending'):
            total += api.get(f'actions/workflows/{workflow}/runs?head_sha={head}&status={status}&per_page=1')['total_count']
    return total


def rearm(api, trunk: str, head: str, conclusion: str, out=sys.stdout, own_runs: int = 0) -> tuple[list[int], list[int]]:
    """(the PRs a merge run was dispatched for, the PRs whose dispatch failed). own_runs is 1 when the caller is itself
    a hosted run still in progress: GitHub counts it, so it is not one of the earlier runs the cap is about."""
    if conclusion not in REARM_CONCLUSIONS:
        print(f'{conclusion or "no conclusion"}: nothing to start again', file=out)
        return [], []
    # The merge run starts a stale or missing check again itself, up to 3 times per job, and each job is new: this
    # is the cap across jobs, whatever the runs ended with, so a check that never records its result cannot loop.
    if hosted_runs_on(api, head) - own_runs >= RUN_LIMIT:
        print(f'{head[:7]}: {RUN_LIMIT} hosted runs already; not starting the merge run again', file=out)
        return [], []
    # A run that a newer one on the same head replaced ends cancelled while that newer run is still going: the newer run's
    # own rearm job starts the merge run when it finishes, and starting it now would only hold a runner for its wait.
    if conclusion == 'cancelled' and active_runs_on(api, head) - own_runs > 0:
        print(f'{head[:7]}: cancelled while a newer hosted run is active; its end starts the merge run', file=out)
        return [], []
    started, failed = [], []
    for pr, base in armed_prs_on(api, trunk, head):
        try:
            api.dispatch_lane(base, pr, head)
        except (OSError, subprocess.SubprocessError) as error:
            print(f'::error::PR #{pr}: could not start its merge run ({error!r})', file=out)
            failed.append(pr)
            continue
        print(f'PR #{pr}: hosted checks on {head[:7]} ended {conclusion}; started its merge run', file=out)
        started.append(pr)
    return started, failed


def main(argv=None, api=None, out=sys.stdout) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument('--repo', default=os.environ.get('GH_REPO', ''))
    parser.add_argument('--trunk', default=os.environ.get('SM_TRUNK') or 'main')
    parser.add_argument('--head', required=True)
    parser.add_argument('--conclusion', default='')
    parser.add_argument('--results', default='', help="the check jobs' results, space separated, as needs.<job>.result gives them")
    args = parser.parse_args(argv)
    if len(args.head) != 40 or not all(c in '0123456789abcdef' for c in args.head) or not args.repo:
        print('::warning::lane_rearm needs a full head SHA and a repository; nothing started.')
        return 0
    try:
        _, failed = rearm(api or GitHubApi(args.repo), args.trunk, args.head, args.conclusion or conclusion_of(args.results), out=out,
                            own_runs=1 if args.results else 0)
        if failed:
            return 1
    except (OSError, subprocess.SubprocessError, ValueError, KeyError) as error:
        # A failed read starts nothing and the red run says so; a push, label or audit dispatch also runs it.
        print(f'::error::lane_rearm could not finish ({error!r}).')
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())

# live proof of the rearm job, 2026-11-19 (throwaway, never merged to main)
