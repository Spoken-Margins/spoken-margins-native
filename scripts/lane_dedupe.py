#!/usr/bin/env python3
"""Hosted lane routing: keep runs that can't do useful work out of the Mac queues (#860).

The `route` job of .github/workflows/lane.yml runs this before either Mac job can queue. It

1. stops this run when the PR is closed or merged, or has moved past this run's head;
2. stops this run, per kind (`lane` or `automerge`), when an older run of the same PR and head already
   has a job of that kind queued or running;
3. cancels the PR's older-head runs whose Mac job has not started (GitHub only replaces a *pending*
   job in a concurrency group, never one already waiting for a runner, so these would hold the queue).

A run is identified by its run name (`run-name` in lane.yml): `lane pr=<n> head=<sha> lane=<bool>
auto=<bool>`. Any API error or doubt changes nothing: the run goes ahead as it did before.
"""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys

RUN_NAME = re.compile(r'^lane pr=(\d+) head=([0-9a-f]{40}) lane=(true|false) auto=(true|false)$')
ACTIVE = ('queued', 'in_progress', 'pending', 'waiting')
KINDS = ('lane', 'automerge')


class GitHubApi:
    def __init__(self, repo):
        self.repo = repo

    def get(self, path):
        out = subprocess.check_output(['gh', 'api', f'repos/{self.repo}/{path}'], text=True, timeout=30)
        return json.loads(out)

    def post(self, path):
        subprocess.check_call(['gh', 'api', '-X', 'POST', f'repos/{self.repo}/{path}'],
                              stdout=subprocess.DEVNULL, timeout=30)


def parse_run_name(title):
    match = RUN_NAME.match(title or '')
    if not match:
        return None
    pr, head, lane, auto = match.groups()
    return {'pr': int(pr), 'head': head, 'kinds': {'lane': lane == 'true', 'automerge': auto == 'true'}}


def active_runs(api):
    runs = {}
    for status in ACTIVE:
        page = api.get(f'actions/workflows/lane.yml/runs?event=pull_request&status={status}&per_page=100')
        if page['total_count'] > len(page['workflow_runs']):
            raise ValueError(f'more than one page of {status} runs')
        for run in page['workflow_runs']:
            runs[run['id']] = run
    return runs


def mac_jobs(api, run_id):
    """The run's lane and automerge jobs, keyed by name. Missing ones haven't been created yet."""
    jobs = api.get(f'actions/runs/{run_id}/jobs?per_page=100')
    if jobs['total_count'] > len(jobs['jobs']):
        raise ValueError('more than one page of jobs')
    return {job['name']: job for job in jobs['jobs'] if job['name'] in KINDS}


def holds_a_slot(jobs, kind):
    """A queued or running job of this kind (one that was skipped or finished does not hold anything)."""
    job = jobs.get(kind)
    return job is None or job['status'] in ACTIVE


def automerge_holds_a_slot(api, pr, head):
    """Defer audit re-arming until route would accept a fresh automerge run.

    Uses the same run identity and job predicate as dedupe. API doubt raises so
    the audit leaves the label and the pending re-arm untouched for its next pass.
    """
    for run_id, run in active_runs(api).items():
        info = parse_run_name(run.get('display_title'))
        if info and info['pr'] == pr and info['head'] == head and info['kinds']['automerge']:
            if holds_a_slot(mac_jobs(api, run_id), 'automerge'):
                return True
    return False


def mac_job_started(jobs):
    # A job that finished since listing has started too. Be conservative if the
    # API has populated started_at before changing the status. Skipped jobs
    # never used the Mac and must not protect the other queued job.
    return any(job.get('conclusion') != 'skipped' and
               (job['status'] in ('in_progress', 'completed') or job.get('started_at'))
               for job in jobs.values())


def obsolete_reason(pull, pr, head):
    if pull['state'] != 'open':
        return f'PR #{pr} is {"merged" if pull.get("merged") else "closed"}'
    if pull['head']['sha'] != head:
        return f'the PR moved on to {pull["head"]["sha"][:7]}; this run is for {head[:7]}'
    return None


def decide(api, pr, head, run_id, wants):
    """What this run should do. Raises on any API doubt; the caller falls back to running normally."""
    result = {'skip': {kind: False for kind in KINDS}, 'cancel': [], 'why': []}
    pull = api.get(f'pulls/{pr}')
    why = obsolete_reason(pull, pr, head)
    if why:
        result['skip'] = {kind: True for kind in KINDS}
        result['why'].append(why)
        return result
    for other_id, run in sorted(active_runs(api).items()):
        info = parse_run_name(run.get('display_title'))
        # A push may have created a newer run since we read the PR. Never cancel it.
        if other_id >= run_id or not info or info['pr'] != pr:
            continue
        if info['head'] != head:
            jobs = mac_jobs(api, other_id)
            if not mac_job_started(jobs):
                result['cancel'].append(other_id)
            continue
        jobs = mac_jobs(api, other_id)
        for kind in KINDS:
            if wants[kind] and info['kinds'][kind] and holds_a_slot(jobs, kind):
                result['skip'][kind] = True
                result['why'].append(f'run {other_id} already has a {kind} job for {head[:7]}')
    return result


def route(api, pr, head, run_id, wants):
    try:
        result = decide(api, pr, head, run_id, wants)
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
        print(f'::warning::Lane dedupe unavailable ({error!r}); running as before.', file=sys.stderr)
        return {kind: False for kind in KINDS}
    for run in result['cancel']:
        # Listing runs/jobs takes time. Revalidate before every destructive request.
        try:
            why = obsolete_reason(api.get(f'pulls/{pr}'), pr, head)
        except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
            print(f'::warning::Lane dedupe unavailable ({error!r}); running as before.', file=sys.stderr)
            return {kind: False for kind in KINDS}
        if why:
            print(f'Not queuing: {why}.', file=sys.stderr)
            return {kind: True for kind in KINDS}
        try:
            if mac_job_started(mac_jobs(api, run)):
                continue
        except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
            print(f'::warning::Lane dedupe unavailable ({error!r}); running as before.', file=sys.stderr)
            return {kind: False for kind in KINDS}
        try:
            api.post(f'actions/runs/{run}/cancel')
            print(f'Cancelled run {run}: its Mac job had not started and the PR has a newer commit.', file=sys.stderr)
        except (OSError, subprocess.SubprocessError) as error:
            print(f'::warning::Could not cancel run {run} ({error!r}); it ends itself when it starts.', file=sys.stderr)
    for why in result['why']:
        print(f'Not queuing: {why}.', file=sys.stderr)
    return result['skip']


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--pr', type=int, required=True)
    parser.add_argument('--head', required=True)
    parser.add_argument('--run-id', type=int, required=True)
    parser.add_argument('--lane', choices=['true', 'false'], required=True)
    parser.add_argument('--auto', choices=['true', 'false'], required=True)
    args = parser.parse_args(argv)
    skip = route(GitHubApi(os.environ['GH_REPO']), args.pr, args.head, args.run_id,
                 {'lane': args.lane == 'true', 'automerge': args.auto == 'true'})
    print(json.dumps({'skip_lane': skip['lane'], 'skip_automerge': skip['automerge']}))
    return 0


if __name__ == '__main__':
    sys.exit(main())
