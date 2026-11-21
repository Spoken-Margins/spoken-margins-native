#!/usr/bin/env python3
"""Dispatch backstop (#4866): start the 15-minute workflows from the VPS when GitHub's own schedule drops them.

GitHub runs a `schedule:` late or not at all when it is busy: in the 24 hours to 2026-11-21 `claude-audit` ran 4 of 96
times, `merge-stall` 3 of 96, `merge-queue-label-bridge` 4 of 96, `lane-conflicts` 3 of 24 and `main-t3` 6 of 8. Each of
these now starts on an event where one exists. This timer (every 15 minutes, next to the Dial gate) is the backstop for
the time-based part: for each workflow it asks when the newest run of any kind began and fires `workflow_dispatch` only
when that is older than the workflow's interval. A workflow an event started a few minutes ago is left alone, so this is a
backstop and not a second trigger.

One log line per workflow per tick, to stdout (journald). Exit 1 if any dispatch or lookup failed, so the unit shows red.
Stdlib only, Python 3.9+. `--dry-run` asks GitHub but dispatches nothing.
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import sys
import urllib.error
import urllib.request
from pathlib import Path

REPO = os.environ.get('SM_DISPATCH_REPO', 'Spoken-Margins/spoken-margins-native')
TRUNK = os.environ.get('SM_TRUNK', 'main')
# The first file that exists is the token. It needs `actions: write` on this repository (fine-grained) or `workflow`
# scope (classic). The Dial's token is the fallback so a host that already has one that can dispatch needs nothing new.
TOKEN_FILES = (Path(os.environ.get('SM_DISPATCH_CONFIG', '/etc/sm-dispatch')) / 'github-token',
               Path(os.environ.get('SM_DIAL_CONFIG', '/etc/sm-dial')) / 'github-token')

# workflow file -> the interval it should not go without a run, in minutes. Keep in step with the `schedule:` comments in
# each file; scripts/tests/test_scheduled_workflows.py holds every name here to a real workflow with workflow_dispatch.
WORKFLOWS = {
    'claude-audit.yml': 15,
    'merge-stall.yml': 15,
    'merge-queue-label-bridge.yml': 15,
    'lane-conflicts.yml': 60,
    'main-t3.yml': 180,
}


def parse_time(text: str) -> dt.datetime:
    return dt.datetime.strptime(text, '%Y-%m-%dT%H:%M:%SZ').replace(tzinfo=dt.timezone.utc)


def gh(method: str, path: str, token: str, body: dict | None = None):
    req = urllib.request.Request(
        f'https://api.github.com/{path}', method=method,
        data=json.dumps(body).encode() if body is not None else None,
        headers={'Authorization': f'Bearer {token}', 'Accept': 'application/vnd.github+json',
                 'X-GitHub-Api-Version': '2022-11-28', 'User-Agent': 'sm-dispatch-backstop',
                 **({'Content-Type': 'application/json'} if body is not None else {})})
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.loads(resp.read() or b'null')


def newest_run(workflow: str, token: str, get=gh) -> dict | None:
    """The newest run of any event, or None when the workflow has never run."""
    runs = get('GET', f'repos/{REPO}/actions/workflows/{workflow}/runs?per_page=1', token)['workflow_runs']
    return runs[0] if runs else None


def decide(now: dt.datetime, interval_minutes: int, run: dict | None) -> tuple[bool, str]:
    """(dispatch?, why). A run counts from the moment it was created, whatever its event or result."""
    if run is None:
        return True, 'no run yet'
    age = now - parse_time(run['created_at'])
    minutes = int(age.total_seconds() // 60)
    if age < dt.timedelta(minutes=interval_minutes):
        return False, f"last run {minutes}m ago ({run.get('event')}), inside {interval_minutes}m"
    return True, f"last run {minutes}m ago ({run.get('event')}), past {interval_minutes}m"


def tick(token: str, now: dt.datetime, out=sys.stdout, dry_run: bool = False, get=gh, workflows=None) -> int:
    """Look at each workflow once and dispatch the ones that are overdue. Returns how many lookups or dispatches failed."""
    failures = 0
    stamp = now.strftime('%Y-%m-%dT%H:%M:%SZ')
    for workflow, interval in (workflows or WORKFLOWS).items():
        try:
            go, why = decide(now, interval, newest_run(workflow, token, get))
            if not go:
                print(f'{stamp} {workflow} skipped: {why}', file=out)
            elif dry_run:
                print(f'{stamp} {workflow} would dispatch: {why}', file=out)
            else:
                get('POST', f'repos/{REPO}/actions/workflows/{workflow}/dispatches', token, {'ref': TRUNK})
                print(f'{stamp} {workflow} dispatched: {why}', file=out)
        except (urllib.error.URLError, OSError, ValueError, KeyError) as error:
            failures += 1
            print(f'{stamp} {workflow} FAILED: {error}', file=out)
    return failures


def read_token() -> str:
    token = os.environ.get('SM_DISPATCH_GITHUB_TOKEN')
    if token:
        return token.strip()
    for path in TOKEN_FILES:
        try:
            text = path.read_text().strip()
        except OSError:
            continue
        if text:
            return text
    raise SystemExit('no GitHub token: put one in ' + ' or '.join(str(p) for p in TOKEN_FILES))


def main(argv=None, now: dt.datetime | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('--dry-run', action='store_true', help='look up each workflow, dispatch nothing')
    args = parser.parse_args(argv)
    now = now or dt.datetime.now(dt.timezone.utc)
    return 1 if tick(read_token(), now, dry_run=args.dry_run) else 0


if __name__ == '__main__':
    sys.exit(main())
