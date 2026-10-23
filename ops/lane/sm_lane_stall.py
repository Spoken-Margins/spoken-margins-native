#!/usr/bin/env python3
"""Lane stall check: flag a lane runner that has stopped reporting while lane jobs wait.

A lane change can stop the self-hosted runner from starting at all. Then it posts no lane reports,
so a guard that waits for runner-fault reports (the planned auto-revert, #640) never fires. This
check looks from the outside instead: when lane jobs are queued or running and no "Lane report"
comment has appeared for N hours (default 2), it prints a STALL line.

Facts, both read with `gh`:
- the newest "Lane report" comment on any issue or PR in the repo (a body that starts with
  "Lane report" or "```text\\nLane report"). The repo gets thousands of comments a week, so it
  reads only the newest window (`issues/comments?since=…`, newest first) and stops at the first
  report it finds;
- the number of runs of `.github/workflows/lane.yml` that are queued, pending or in progress.

Prints one line and exits 0 for OK, 1 for STALL, 2 when a fact couldn't be read (an ERROR line).
Stdlib only, Python 3.9+. Read-only: it never comments, labels or touches a run.
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
from typing import Optional

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'scripts'))
import comment_trust  # noqa: E402  (#1822: a stranger's fake lane report must not hide a stall)

DEFAULT_REPO = 'Spoken-Margins/spoken-margins-native'
WORKFLOW = 'lane.yml'
REPORT = re.compile(r'^(```text\r?\n)?Lane report')
# Waiting on a runner (queued), on the per-PR concurrency group (pending), or running.
ACTIVE_STATUSES = ('queued', 'pending', 'in_progress')
PAGE_SIZE = 100


def is_lane_report(body: Optional[str]) -> bool:
    return bool(body) and bool(REPORT.match(body.lstrip()))


def parse_time(stamp: str) -> dt.datetime:
    return dt.datetime.strptime(stamp, '%Y-%m-%dT%H:%M:%SZ').replace(tzinfo=dt.timezone.utc)


def span(seconds: float) -> str:
    minutes = max(0, int(seconds // 60))
    return f'{minutes // 60}h {minutes % 60}m'


def decide(now: dt.datetime, newest_report_at: Optional[dt.datetime], newest_report_url: Optional[str],
           active_jobs: int, stall_hours: float, lookback_hours: float) -> tuple[bool, str]:
    """The whole decision, pure. Returns (stalled, the one line to print).

    newest_report_at is None when no lane report turned up in the last lookback_hours."""
    jobs = f'{active_jobs} lane job{"" if active_jobs == 1 else "s"}'
    are = 'is' if active_jobs == 1 else 'are'
    if newest_report_at is None:
        if active_jobs > 0:
            return True, (f'STALL: no lane report for over {span(lookback_hours * 3600)} while {jobs} '
                          f'{are} queued (newest report: none in the last {span(lookback_hours * 3600)})')
        return False, f'OK: no lane jobs queued (no lane report in the last {span(lookback_hours * 3600)})'
    quiet = (now - newest_report_at).total_seconds()
    if active_jobs > 0 and quiet >= stall_hours * 3600:
        return True, (f'STALL: no lane report for {span(quiet)} while {jobs} {are} queued '
                      f'(newest report: {newest_report_url})')
    if active_jobs == 0:
        return False, f'OK: no lane jobs queued; newest lane report {span(quiet)} ago'
    return False, f'OK: newest lane report {span(quiet)} ago; {jobs} queued or running'


def gh_json(path: str):
    result = subprocess.run(['gh', 'api', path], capture_output=True, text=True, timeout=60)
    if result.returncode != 0:
        raise RuntimeError(f'gh api {path.split("?")[0]} failed: {result.stderr.strip()[:200]}')
    return json.loads(result.stdout)


def newest_report(repo: str, now: dt.datetime, lookback_hours: float, max_pages: int):
    """(created_at, url) of the newest lane report created in the lookback window, or (None, None).

    `since` filters on update time, so it bounds the window; sorting by creation, newest first,
    makes the first match the newest report."""
    since = (now - dt.timedelta(hours=lookback_hours)).strftime('%Y-%m-%dT%H:%M:%SZ')
    for page in range(1, max_pages + 1):
        comments = gh_json(f'repos/{repo}/issues/comments?sort=created&direction=desc'
                           f'&since={since}&per_page={PAGE_SIZE}&page={page}')
        for comment in comments:
            if is_lane_report(comment.get('body')) and comment_trust.trusted(comment):
                return parse_time(comment['created_at']), comment['html_url']
        if len(comments) < PAGE_SIZE:
            break
    return None, None


def active_lane_jobs(repo: str) -> int:
    return sum(gh_json(f'repos/{repo}/actions/workflows/{WORKFLOW}/runs?status={status}&per_page=1')
               ['total_count'] for status in ACTIVE_STATUSES)


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    parser.add_argument('--hours', type=float, default=2.0,
                        help='hours without a lane report, while jobs wait, that count as a stall (default 2)')
    parser.add_argument('--lookback-hours', type=float, default=24.0,
                        help='how far back to look for the newest report (default 24)')
    parser.add_argument('--max-pages', type=int, default=20, help='comment pages of 100 to read at most (default 20)')
    parser.add_argument('--repo', default=os.environ.get('GH_REPO') or DEFAULT_REPO)
    args = parser.parse_args(argv)
    now = dt.datetime.now(dt.timezone.utc).replace(microsecond=0)
    try:
        jobs = active_lane_jobs(args.repo)
        at, url = newest_report(args.repo, now, max(args.lookback_hours, args.hours), args.max_pages)
    except (RuntimeError, OSError, ValueError, KeyError, subprocess.TimeoutExpired) as error:
        print(f'ERROR: lane stall check could not read GitHub: {error}')
        return 2
    stalled, line = decide(now, at, url, jobs, args.hours, max(args.lookback_hours, args.hours))
    print(line)
    return 1 if stalled else 0


if __name__ == '__main__':
    sys.exit(main())
