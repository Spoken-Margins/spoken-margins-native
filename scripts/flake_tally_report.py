#!/usr/bin/env python3
"""Read the retry-pass tally on #2176 and say which tests are due a `ready` Showcase issue (owner, 2026-10-24).

The hosted integration run and the lane runner each tally a retry-pass as a comment on #2176 and open an issue when
the test they just tallied crosses 3 in 7 days. A test whose retry-passes come from both, or whose issue was closed
and then flaked again, is only seen by a reader of the whole tally. This is that reader. After a test's flake issue
is closed, only its retry-passes from after the close count, so a fixed test doesn't get a second issue.

    scripts/flake_tally_report.py                 dry run: counts per test and the tests due an issue
    scripts/flake_tally_report.py --file-issues   open one `ready` Showcase issue per due test

Only comments from the owner, collaborators and `github-actions[bot]` count (`scripts/comment_trust.py`, #1822), so
a stranger's look-alike line can't open an issue. A test with an open issue carrying its marker is skipped.
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import subprocess
import sys

import flake_tally

REPO = 'Spoken-Margins/spoken-margins-native'


def gh_json_lines(args: list[str]) -> list[dict]:
    """`gh api --paginate --jq '.[] | @json'` output as a list of dicts."""
    done = subprocess.run(['gh', 'api', '--paginate', '--jq', '.[] | @json', *args], capture_output=True, text=True)
    if done.returncode:
        raise RuntimeError(done.stderr.strip()[:300])
    return [json.loads(line) for line in done.stdout.splitlines() if line.strip()]


def fetch_comments(repo: str) -> list[dict]:
    return gh_json_lines([f'repos/{repo}/issues/{flake_tally.TALLY_ISSUE}/comments?per_page=100'])


def fetch_open_issues(repo: str) -> list[dict]:
    return [i for i in gh_json_lines([f'repos/{repo}/issues?state=open&per_page=100']) if not i.get('pull_request')]


def fetch_closed_issues(repo: str, since: dt.datetime) -> list[dict]:
    """Issues closed since `since`: GitHub's `since` filters on the last update, and a close is an update."""
    stamp = since.strftime(flake_tally.TIME_FORMAT)
    return [i for i in gh_json_lines([f'repos/{repo}/issues?state=closed&since={stamp}&per_page=100'])
            if not i.get('pull_request')]


def open_issue(repo: str, title: str, body: str) -> str:
    done = subprocess.run(['gh', 'issue', 'create', '-R', repo, '--title', title, '--body', body,
                           '--label', 'ready', '--milestone', 'Showcase'], capture_output=True, text=True)
    if done.returncode:
        raise RuntimeError(done.stderr.strip()[:300])
    return done.stdout.strip()


def build_report(comments: list[dict], issues: list[dict], now: dt.datetime,
                 closed_issues: list[dict] = ()) -> tuple[dict[str, list[str]], list[str]]:
    """(retry-pass run ids per test in the window and after any close of its flake issue, tests due an issue)."""
    counts = flake_tally.tally_counts(comments, now, closed=flake_tally.closed_flake_markers(list(closed_issues)))
    return counts, flake_tally.tests_due_an_issue(counts, flake_tally.flake_markers(issues))


def render(counts: dict[str, list[str]], due: list[str]) -> str:
    lines = [f'Retry-passes in the last {flake_tally.TALLY_WINDOW.days} days (threshold {flake_tally.TALLY_THRESHOLD}):']
    for test, runs in sorted(counts.items(), key=lambda kv: (-len(kv[1]), kv[0])):
        lines.append(f'  {len(runs)}  {test}' + ('  <- due an issue' if test in due else ''))
    if not counts:
        lines.append('  none')
    lines.append(f'Due an issue: {len(due)}')
    return '\n'.join(lines)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    parser.add_argument('--file-issues', action='store_true', help='open the issues (the default is a dry run)')
    parser.add_argument('--repo', default=REPO)
    args = parser.parse_args(argv)
    now = dt.datetime.now(dt.timezone.utc)
    counts, due = build_report(fetch_comments(args.repo), fetch_open_issues(args.repo), now,
                               fetch_closed_issues(args.repo, now - flake_tally.TALLY_WINDOW))
    print(render(counts, due))
    if args.file_issues:
        for test in due:
            title, body = flake_tally.flake_issue_text(test, counts[test], args.repo)
            print('opened', open_issue(args.repo, title, body))
    return 0


if __name__ == '__main__':
    sys.exit(main())
