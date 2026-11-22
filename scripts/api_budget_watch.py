#!/usr/bin/env python3
"""Warn the owner before the workflow token's hourly API budget runs out (#4990).

On 2026-11-22 the repository's workflows spent the budget (1,000 calls an hour for a workflow's token), and the first
anyone knew was the `merge policy` check holding two owner-tapped PRs (#4985, #4983) with "API rate limit exceeded for
installation". This reads how much of the budget is used and says so before it is gone.

It runs as a step of .github/workflows/merge-stall.yml, which already starts each time a PR's hosted checks finish and
from the VPS every 15 minutes, so it adds no workflow run and is sampled most often exactly when the budget is being
spent. A 15-minute `schedule:` of its own would not do: GitHub ran 4 of 96 such ticks on a busy day (#4866).

Each run:
  * reads `rate_limit`, which GitHub does not count against the budget, and writes one line to the step summary;
  * below WARN_AT of the limit it stops there: no counted call at all;
  * at or above it, it posts one comment that @mentions the owner on the standing issue (opened on first need), from
    the project's bot, because a comment under the owner's own account notifies nobody (scripts/owner_tap_alert.py).
    One comment per budget window: the comment carries the window's reset time and a later run in that window sees it.
    The comment lists the workflows with the most runs in the last hour, from one list call.

It never fails the job: a warning that can't be posted is a line in the log, and the stall watch runs after it.
"""
from __future__ import annotations

import argparse
import collections
import datetime
import json
import os
import subprocess
import sys

OWNER_LOGIN = 'uncomposed'  # as in owner_tap_alert.py and merge_stall_watch.py
BOT = 'github-actions[bot]'
WARN_AT = 0.70
ISSUE_TITLE = 'GitHub API budget warnings'
ISSUE_MARKER = '<!-- api-budget-watch -->'
TOP = 5
ISSUE_BODY = (f'{ISSUE_MARKER}\nThe workflows in this repository share one hourly budget of GitHub API calls. '
              f'`scripts/api_budget_watch.py` comments here, once per hour window, when {int(WARN_AT * 100)}% of it is '
              'used, so the owner hears before checks start failing with "API rate limit exceeded" (#4990). '
              'Leave this issue open; closing it only makes the next warning open a new one.')


def window_marker(reset: int) -> str:
    return f'<!-- api-budget-window {reset} -->'


def should_warn(used: int, limit: int) -> bool:
    return limit > 0 and used >= WARN_AT * limit


def already_warned(comments: list[dict], reset: int) -> bool:
    """True when the bot has commented for this window. A stranger's comment with the marker counts for nothing."""
    return any(window_marker(reset) in (c.get('body') or '') and ((c.get('user') or {}).get('login') == BOT)
               for c in comments)


def busiest(runs: list[dict], top: int = TOP) -> list[tuple[str, int]]:
    """(workflow, runs) for the workflows with the most runs that did work; a skipped run started no job."""
    counts = collections.Counter(run.get('name') or '?' for run in runs if run.get('conclusion') != 'skipped')
    return sorted(counts.items(), key=lambda item: (-item[1], item[0]))[:top]


def reading_line(used: int, limit: int, reset: int, now: float) -> str:
    left = max(0, int((reset - now) // 60))
    percent = int(100 * used / limit) if limit else 0
    return f'API budget: {used} of {limit} calls used ({percent}%), resets in {left} minutes.'


def warning_body(used: int, limit: int, reset: int, now: float, runs: list[dict] | None, listed: int = 0) -> str:
    lines = [f'@{OWNER_LOGIN} the workflows have used most of this hour\'s GitHub API budget. '
             + reading_line(used, limit, reset, now).removeprefix('API budget: '),
             '',
             'When it reaches the limit, checks that read GitHub fail until the reset. '
             'Nothing is needed from you if merges are moving; this is the early notice.']
    if runs is None:
        lines += ['', 'The recent runs could not be read.']
    else:
        lines += ['', f'Workflows with the most runs in the last hour (of the newest {listed} runs, skipped ones left out):']
        lines += [f'{index}. `{name}`: {count} runs' for index, (name, count) in enumerate(busiest(runs), 1)]
    lines += ['', window_marker(reset)]
    return '\n'.join(lines)


def find_issue(issues: list[dict]) -> int | None:
    for issue in issues:
        if (issue.get('user') or {}).get('login') == BOT and ISSUE_MARKER in (issue.get('body') or '') \
                and 'pull_request' not in issue:
            return issue['number']
    return None


class GitHub:
    """`gh api`, counted. run is injected in tests."""

    def __init__(self, repo: str, run=subprocess.run):
        self.repo, self.run, self.calls = repo, run, []

    def api(self, path: str, *args: str):
        self.calls.append(path)
        done = self.run(['gh', 'api', path, *args], capture_output=True, text=True, timeout=60)
        if done.returncode:
            raise RuntimeError(f'gh api {path}: {(done.stderr or "").strip()[:200]}')
        return json.loads(done.stdout) if done.stdout.strip() else {}


def watch(github: GitHub, now: float, out=print, dry_run: bool = False) -> str:
    """One run. Returns the reading line (for the step summary), with what was done about it."""
    core = github.api('rate_limit')['resources']['core']
    used, limit, reset = int(core['used']), int(core['limit']), int(core['reset'])
    line = reading_line(used, limit, reset, now)
    if not should_warn(used, limit):
        return line
    repo = github.repo
    number = find_issue(github.api(f'repos/{repo}/issues?state=open&creator={BOT.replace("[", "%5B").replace("]", "%5D")}&per_page=100'))
    if number is not None:
        since = datetime.datetime.fromtimestamp(reset - 3700, datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
        if already_warned(github.api(f'repos/{repo}/issues/{number}/comments?since={since}&per_page=100'), reset):
            return line + f' Already said on #{number} for this window.'
    try:
        hour_ago = datetime.datetime.fromtimestamp(now - 3600, datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
        runs = github.api(f'repos/{repo}/actions/runs?created=%3E%3D{hour_ago}&per_page=100').get('workflow_runs') or []
    except (RuntimeError, ValueError):
        runs = None
    body = warning_body(used, limit, reset, now, runs, len(runs or []))
    if dry_run:
        out(body)
        return line + ' Dry run: would warn.'
    if number is None:
        number = github.api(f'repos/{repo}/issues', '-X', 'POST', '-f', f'title={ISSUE_TITLE}', '-f', f'body={ISSUE_BODY}')['number']
    github.api(f'repos/{repo}/issues/{number}/comments', '-X', 'POST', '-f', f'body={body}')
    return line + f' Warned on #{number}.'


def main(argv: list[str] | None = None, github: GitHub | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    parser.add_argument('--repo', default=os.environ.get('GH_REPO') or os.environ.get('GITHUB_REPOSITORY', ''))
    parser.add_argument('--dry-run', action='store_true', help='print the warning instead of posting it')
    args = parser.parse_args(argv)
    now = datetime.datetime.now(datetime.timezone.utc).timestamp()
    try:
        line = watch(github or GitHub(args.repo), now, dry_run=args.dry_run)
    except Exception as error:  # noqa: BLE001 - never fail the job the stall watch runs in
        line = f'API budget: could not read or warn ({str(error)[:200]}).'
    print(line)
    summary = os.environ.get('GITHUB_STEP_SUMMARY')
    if summary:
        stamp = datetime.datetime.fromtimestamp(now, datetime.timezone.utc).strftime('%Y-%m-%d %H:%M UTC')
        with open(summary, 'a') as handle:
            handle.write(f'{stamp}: {line}\n')
    return 0


if __name__ == '__main__':
    sys.exit(main())
