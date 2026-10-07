#!/usr/bin/env python3
"""Lane poll, shadow mode (#1057): what would a poller start if GitHub Actions were not the trigger?

Today `.github/workflows/lane.yml`, `shipped-build-compat.yml` and `merge-audit.yml` decide when a lane
job starts. This script makes the same decisions from GitHub's REST API alone, so the owner can see
whether a poller would start everything Actions starts, and what Actions misses (stale merge refs, #221).

It only reads. Each run (every minute or so, from launchd or a timer):

1. Lists the open PRs into `next`, the newest issue events, and `next`'s head.
2. For each PR with `lane:queued` or `automerge` (same-repo heads only, as lane.yml's `if:` says) it
   starts a job when the head changed since the last run (a push), the label was added again since the
   last run (an event), or the PR was reopened. A PR whose changed paths match shipped-build-compat.yml's
   filter gets a compat job on each new head. A moved `next` gets a merge-audit job.
3. Prints one JSON line per job it would start, with whether Actions has a run of the matching
   workflow on the same head. A line saying `actions: none` that is more than a few minutes old is a
   trigger Actions missed.

The first run only records a baseline and prints no jobs. Lane merges also move `next`, and Actions
never audits those (a push made with the workflow token starts no workflow), so their merge-audit lines
show `actions: none` by design.

Not covered yet: `lane-check/**` bases, more than 100 open PRs (it warns), and running anything.
Stdlib only, Python 3.9-compatible. Needs the `gh` CLI, signed in, with read access to the repository.
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import re
import subprocess
import sys
from pathlib import Path

REPO = os.environ.get('SM_LANE_POLL_REPO', 'uncomposed/spoken-margins-native')
BASE = 'next'
STATE_FILE = Path(os.environ.get('SM_LANE_POLL_STATE',
                                 str(Path.home() / 'SpokenMarginsOps/lane-poll/state.json')))

# The label that asks for each kind of job, as in lane.yml's `if:` conditions.
LABEL_FOR = {'lane': 'lane:queued', 'automerge': 'automerge'}
# The workflow file that starts each kind today, for the "did Actions start it" lookup.
WORKFLOW_FOR = {'lane': 'lane.yml', 'automerge': 'lane.yml',
                'compat': 'shipped-build-compat.yml', 'merge-audit': 'merge-audit.yml'}
# The `paths:` filter of shipped-build-compat.yml. test_sm_lane_poll.py keeps the two in step.
COMPAT_PATHS = (
    'Packages/SessionKit/Sources/SessionKitPersistence/**',
    'Packages/SessionKit/Sources/SessionKitSharing/**',
    'Packages/SessionKit/Tests/ShippedReader/**',
    'Packages/SessionKit/Tests/*/Build29DatabaseFixtureTests.swift',
    'scripts/check-build29-database.sh',
    'scripts/build29-db-reader/**',
    'scripts/freeze-shipped-reader.sh',
    '.github/workflows/shipped-build-compat.yml',
)
FILE_PAGES = 10  # a PR with more than 1,000 changed files is not a compat question


class GhApi:
    """Reads with the `gh` CLI. There is no method that writes: this tool must not change GitHub."""

    def get(self, path: str):
        out = subprocess.check_output(['gh', 'api', path], text=True, timeout=120)
        return json.loads(out)


def glob_regex(pattern: str):
    """GitHub's path-filter glob as a regex: `*` stays inside one folder, `**` crosses folders."""
    out, i = [], 0
    while i < len(pattern):
        if pattern.startswith('**/', i):
            out.append('(?:.*/)?')
            i += 3
        elif pattern.startswith('**', i):
            out.append('.*')
            i += 2
        elif pattern[i] == '*':
            out.append('[^/]*')
            i += 1
        elif pattern[i] == '?':
            out.append('[^/]')
            i += 1
        else:
            out.append(re.escape(pattern[i]))
            i += 1
    return re.compile('^' + ''.join(out) + '$')


COMPAT_RES = [glob_regex(pattern) for pattern in COMPAT_PATHS]


def touches_compat(paths) -> bool:
    return any(rx.match(path) for path in paths for rx in COMPAT_RES)


def empty_state() -> dict:
    return {'version': 1, 'baselined': False, 'event_cursor': 0, 'next_sha': '', 'dispatched': {}, 'compat': {}}


def load_state(path: Path) -> dict:
    try:
        state = json.loads(path.read_text())
    except (OSError, ValueError):
        return empty_state()
    return state if state.get('version') == 1 and state.get('baselined') else empty_state()


def save_state(path: Path, state: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_suffix('.tmp')
    temp.write_text(json.dumps(state, indent=1, sort_keys=True))
    temp.replace(path)


def same_repo_into_base(pr: dict, repo: str) -> bool:
    head_repo = (pr.get('head') or {}).get('repo') or {}
    return (pr.get('base') or {}).get('ref') == BASE and head_repo.get('full_name') == repo


def pr_events(events) -> list:
    """Events on pull requests, as (id, event, issue number, label name)."""
    found = []
    for event in events:
        issue = event.get('issue') or {}
        if issue.get('pull_request') is not None:
            found.append((event['id'], event.get('event'), issue.get('number'), (event.get('label') or {}).get('name')))
    return found


def baseline(prs, events, next_sha: str, repo: str) -> dict:
    """Record what exists now, without starting anything: the PRs already armed at their current heads."""
    state = empty_state()
    state.update(baselined=True, next_sha=next_sha,
                 event_cursor=max([event['id'] for event in events] or [0]))
    for pr in prs:
        if not same_repo_into_base(pr, repo):
            continue
        names = {label['name'] for label in pr.get('labels', [])}
        for kind, label in LABEL_FOR.items():
            if label in names:
                state['dispatched'][f'{pr["number"]}:{kind}'] = pr['head']['sha']
        state['compat'][str(pr['number'])] = pr['head']['sha']
    return state


def decide(prs, events, next_sha: str, state: dict, files_for, repo: str = REPO) -> tuple:
    """The jobs to start, and the next state. Pure apart from `files_for(pr_number)`, which is asked only
    for a PR whose head the compat check has not seen."""
    jobs = []
    new = json.loads(json.dumps(state))
    cursor = state['event_cursor']
    fresh = [event for event in pr_events(events) if event[0] > cursor]
    relabelled = {(number, label) for _, kind, number, label in fresh if kind == 'labeled'}
    reopened = {number for _, kind, number, _ in fresh if kind == 'reopened'}
    open_numbers = set()
    for pr in prs:
        if not same_repo_into_base(pr, repo):
            continue
        number, head = pr['number'], pr['head']['sha']
        open_numbers.add(number)
        names = {label['name'] for label in pr.get('labels', [])}
        for kind, label in LABEL_FOR.items():
            key = f'{number}:{kind}'
            if label not in names:
                new['dispatched'].pop(key, None)  # adding it back later starts a job, even on the same head
                continue
            seen = state['dispatched'].get(key)
            reasons = []
            if seen != head:
                reasons.append('push' if seen else 'first-seen')
            if (number, label) in relabelled:
                reasons.append('labeled')
            if number in reopened:
                reasons.append('reopened')
            if reasons:
                jobs.append({'kind': kind, 'pr': number, 'head': head, 'reasons': reasons})
            new['dispatched'][key] = head
        if state['compat'].get(str(number)) != head:
            if touches_compat(files_for(number)):
                jobs.append({'kind': 'compat', 'pr': number, 'head': head, 'reasons': ['push']})
            new['compat'][str(number)] = head
    # Forget PRs that are no longer open.
    new['dispatched'] = {k: v for k, v in new['dispatched'].items() if int(k.split(':')[0]) in open_numbers}
    new['compat'] = {k: v for k, v in new['compat'].items() if int(k) in open_numbers}
    if state['next_sha'] and state['next_sha'] != next_sha:
        jobs.append({'kind': 'merge-audit', 'pr': None, 'head': next_sha, 'reasons': ['next-moved'],
                     'before': state['next_sha']})
    new['next_sha'] = next_sha
    new['event_cursor'] = max([cursor] + [event[0] for event in fresh])
    return jobs, new


def actions_status(api, repo: str, job: dict) -> str:
    """Whether Actions has a run of the workflow that would start this job, on the same head."""
    runs = api.get(f'repos/{repo}/actions/runs?head_sha={job["head"]}&per_page=50').get('workflow_runs', [])
    mine = [run for run in runs if (run.get('path') or '').endswith('/' + WORKFLOW_FOR[job['kind']])]
    if not mine:
        return 'none'
    newest = max(mine, key=lambda run: run['id'])
    return f'{len(mine)} run(s) on this head, newest {newest["id"]} {newest["status"]}/{newest.get("conclusion") or "-"}'


def changed_paths(api, repo: str, number: int) -> list:
    paths = []
    for page in range(1, FILE_PAGES + 1):
        files = api.get(f'repos/{repo}/pulls/{number}/files?per_page=100&page={page}')
        for entry in files:
            paths.append(entry['filename'])
            if entry.get('previous_filename'):
                paths.append(entry['previous_filename'])
        if len(files) < 100:
            break
    return paths


def run_once(api, state_path: Path, repo: str = REPO, compare: bool = True, now=None) -> list:
    """One poll. Returns the JSON-able lines to print. Writes only its own state file, and only after
    every read succeeded."""
    stamp = (now or (lambda: dt.datetime.now(dt.timezone.utc)))().strftime('%Y-%m-%dT%H:%M:%SZ')
    prs = api.get(f'repos/{repo}/pulls?state=open&base={BASE}&per_page=100')
    events = api.get(f'repos/{repo}/issues/events?per_page=100')
    next_sha = api.get(f'repos/{repo}/branches/{BASE}')['commit']['sha']
    lines = []
    if len(prs) >= 100:
        lines.append({'at': stamp, 'warning': '100 open PRs: the list may be cut off'})
    state = load_state(state_path)
    if not state['baselined']:
        state = baseline(prs, events, next_sha, repo)
        save_state(state_path, state)
        armed = len(state['dispatched'])
        lines.append({'at': stamp, 'baseline': {'open_prs': len(prs), 'armed_pairs': armed,
                                                'event_cursor': state['event_cursor'], 'next': next_sha[:7]}})
        return lines
    ids = [event['id'] for event in events]
    if ids and state['event_cursor'] and min(ids) > state['event_cursor']:
        lines.append({'at': stamp, 'warning': 'event feed gap: label events between polls may be missed; '
                                               'the head check still sees pushes'})
    jobs, new = decide(prs, events, next_sha, state, lambda number: changed_paths(api, repo, number), repo)
    for job in jobs:
        line = {'at': stamp, 'would_start': job['kind'], 'pr': job['pr'], 'head': job['head'],
                'reasons': job['reasons']}
        if 'before' in job:
            line['before'] = job['before']
        if compare:
            line['actions'] = actions_status(api, repo, job)
        lines.append(line)
    save_state(state_path, new)
    return lines


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--state', type=Path, default=STATE_FILE, help='where it keeps what it has seen')
    parser.add_argument('--repo', default=REPO)
    parser.add_argument('--no-compare', action='store_true', help='skip the lookup of Actions runs')
    parser.add_argument('--reset', action='store_true', help='forget the state: the next run records a new baseline')
    args = parser.parse_args(argv)
    if args.reset and args.state.exists():
        args.state.unlink()
    try:
        lines = run_once(GhApi(), args.state, args.repo, compare=not args.no_compare)
    except (subprocess.SubprocessError, OSError, ValueError, KeyError) as error:
        print(f'lane-poll: could not read GitHub: {error!r}', file=sys.stderr)
        return 2
    for line in lines:
        print(json.dumps(line, sort_keys=True), flush=True)
    return 0


if __name__ == '__main__':
    sys.exit(main())
