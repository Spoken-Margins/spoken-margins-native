#!/usr/bin/env python3
"""Tell the owner when merging has stopped, from a machine that isn't his laptop (#3502).

On 2026-11-05 nothing merged for 11.5 hours while his Mac slept. The #337 Mac tick that would have said so runs on that
same Mac, and the hourly dispatcher only left a note on a PR. This runs on hosted Linux (.github/workflows/merge-stall.yml).

It alarms when both hold:
  * nothing has reached the trunk for STALL_AFTER;
  * an armed PR is stuck: open, not a draft, from this repository, with `automerge`, and nothing has moved on it for
    STALL_AFTER. Moved means a new commit, a trusted comment, or a check other than the merge jobs running on its head.
    The merge jobs don't count, because they may only be waiting.

A PR that needs its own author, rather than the pipeline, is not stuck: a merge conflict, or a FAIL or a blocking audit
as the newest verdict on its head. Comments from outsiders count for nothing (scripts/comment_trust.py, #1822), so a
stranger's comment can't hide a stall or fake a verdict.

The alarm is one issue from the project's bot that @mentions the owner, and the GitHub mobile app pushes mentions. While
that issue is open the watch says nothing more. When something reaches the trunk, it closes the issue with a note.
"""
from __future__ import annotations

import argparse
import datetime
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
from comment_trust import trusted_author, author_login  # noqa: E402
from trunk import trunk_branch  # noqa: E402

STALL_AFTER = datetime.timedelta(minutes=60)
OWNER_LOGIN = 'uncomposed'  # as in owner_tap_alert.py
AUTOMERGE = 'automerge'
MARKER = '<!-- merge-stall-alarm -->'
BOT = 'github-actions[bot]'
# These run on a PR's head while they wait for something else, so they aren't progress. The `release` job's check sits on
# the trunk's tip, never on the PR's head.
WAITING_CHECKS = {'automerge', 'automerge-mac'}
LANE_VERDICT = re.compile(r'^\s*Lane report\b.*?(?:—|--|-)\s*(PASS|FAIL|INCONCLUSIVE)\b')
LANE_COMMIT = re.compile(r'\bcommit\s+`?([0-9a-f]{7,40})\b')
AUDIT_HEADING = re.compile(r'^\*\*Claude audit on `([0-9a-f]{7,40})`\*\*\s*$')
CLEAN_AUDIT = re.compile(r'no (blocking )?findings\b', re.I)


def parse_time(text: str) -> datetime.datetime:
    return datetime.datetime.fromisoformat(text.replace('Z', '+00:00'))


def trusted_comments(comments: list[dict]) -> list[dict]:
    return [c for c in comments if trusted_author(c.get('author_association'), author_login(c))]


def needs_its_author(pr: dict, comments: list[dict]) -> str:
    """Why this PR waits on its author rather than the pipeline, or ''."""
    head = pr['head']['sha']
    if pr.get('mergeable_state') == 'dirty':
        return 'has a merge conflict'
    for comment in reversed(comments):
        body = (comment.get('body') or '').lstrip()
        first, _, rest = body.partition('\n')
        audit = AUDIT_HEADING.match(first.rstrip())
        if audit and head.startswith(audit.group(1)):
            verdict = next((line.strip() for line in rest.splitlines() if line.strip()), '')
            if not CLEAN_AUDIT.match(verdict):
                return 'has a blocking audit on its head'
            continue
        lane = LANE_VERDICT.match(first)
        commit = LANE_COMMIT.search(body)
        if lane and commit and head.startswith(commit.group(1)):
            return 'has a lane FAIL on its head' if lane.group(1) == 'FAIL' else ''
    return ''


def stuck_for(pr: dict, comments: list[dict], running: list[str], head_time: datetime.datetime,
              now: datetime.datetime) -> datetime.timedelta | None:
    """How long nothing has moved on this PR, or None when something is moving right now or its author must act."""
    if any(name not in WAITING_CHECKS for name in running):
        return None
    if needs_its_author(pr, comments):
        return None
    times = [head_time] + [parse_time(c['created_at']) for c in comments]
    return now - max(times)


def minutes(delta: datetime.timedelta) -> int:
    return int(delta.total_seconds() // 60)


def stall(now: datetime.datetime, last_merge: datetime.datetime, armed: list[dict]) -> list[str]:
    """The lines for the alarm, or [] when there's nothing to say. <armed>: {pr, comments, running, head_time}."""
    if now - last_merge < STALL_AFTER:
        return []
    lines = []
    for item in armed:
        comments = trusted_comments(item['comments'])
        stuck = stuck_for(item['pr'], comments, item['running'], item['head_time'], now)
        if stuck is not None and stuck >= STALL_AFTER:
            pr = item['pr']
            lines.append(f'- #{pr["number"]} has not moved for {minutes(stuck)} minutes. {waiting_on(comments)}')
    return lines


def waiting_on(comments: list[dict]) -> str:
    """The newest lane note on the PR, cut short, as a lead for the reader."""
    for comment in reversed(comments):
        if author_login(comment) == BOT:
            line = (comment.get('body') or '').strip().partition('\n')[0]
            return f'Latest bot note: "{line[:120]}"'
    return 'The bot has said nothing on it.'


def alarm_body(now: datetime.datetime, last_merge: datetime.datetime, lines: list[str]) -> str:
    return '\n'.join([
        f'@{OWNER_LOGIN} nothing has merged for {minutes(now - last_merge)} minutes, and PRs are armed but not moving.',
        '',
        *lines,
        '',
        'Queued jobs: https://github.com/Spoken-Margins/spoken-margins-native/actions?query=is%3Aqueued',
        '',
        'This watch closes the issue when something merges. It runs on hosted Linux and does not need your Mac (#3502).',
        MARKER,
    ])


def gh(*args: str, stdin: str | None = None) -> str:
    return subprocess.run(['gh', *args], check=True, capture_output=True, text=True, input=stdin).stdout


def api(path: str) -> list | dict:
    """One read; a path that asks for per_page=100 reads every page, as a list of pages."""
    return json.loads(gh('api', '--paginate', '--slurp', path) if 'per_page=100' in path else gh('api', path))


def flat(pages) -> list:
    return [item for page in pages for item in page]


def read_armed(repo: str, base: str) -> list[dict]:
    armed = []
    for listed in flat(api(f'repos/{repo}/pulls?state=open&base={base}&per_page=100')):
        names = {label['name'] for label in listed.get('labels') or []}
        if AUTOMERGE not in names or listed.get('draft') \
                or (listed.get('head', {}).get('repo') or {}).get('full_name') != repo:
            continue
        number, head = listed['number'], listed['head']['sha']
        pr = api(f'repos/{repo}/pulls/{number}')  # only a single PR's read carries mergeable_state
        comments = flat(api(f'repos/{repo}/issues/{number}/comments?per_page=100'))
        checks = api(f'repos/{repo}/commits/{head}/check-runs?status=in_progress&filter=latest')
        commit = api(f'repos/{repo}/commits/{head}')
        armed.append({'pr': pr, 'comments': comments,
                      'running': [check['name'] for check in checks.get('check_runs', [])],
                      'head_time': parse_time(commit['commit']['committer']['date'])})
    return armed


def open_alarm(repo: str) -> int | None:
    issues = flat(api(f'repos/{repo}/issues?state=open&creator={BOT.replace("[", "%5B").replace("]", "%5D")}&per_page=100'))
    for issue in issues:
        if author_login(issue) == BOT and MARKER in (issue.get('body') or '') and 'pull_request' not in issue:
            return issue['number']
    return None


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    parser.add_argument('--dry-run', action='store_true', help='print what it would do; change nothing')
    args = parser.parse_args(argv)
    repo = os.environ.get('GH_REPO', 'Spoken-Margins/spoken-margins-native')
    base = trunk_branch()
    now = datetime.datetime.now(datetime.timezone.utc)
    last_merge = parse_time(api(f'repos/{repo}/commits/{base}')['commit']['committer']['date'])
    alarm = open_alarm(repo)
    if alarm and now - last_merge < STALL_AFTER:
        print(f'Something merged {minutes(now - last_merge)} minutes ago: closing #{alarm}.')
        if not args.dry_run:
            gh('issue', 'close', str(alarm), '--repo', repo, '--comment', 'Merging is moving again.')
        return 0
    if alarm:
        print(f'Still stalled; #{alarm} already says so.')
        return 0
    lines = stall(now, last_merge, read_armed(repo, base))
    if not lines:
        print(f'No stall: last merge {minutes(now - last_merge)} minutes ago, and no armed PR is stuck.')
        return 0
    body = alarm_body(now, last_merge, lines)
    print(body)
    if not args.dry_run:
        with tempfile.NamedTemporaryFile('w', suffix='.md') as handle:
            handle.write(body)
            handle.flush()
            gh('issue', 'create', '--repo', repo, '--title', 'Merging has stalled', '--body-file', handle.name)
    return 0


if __name__ == '__main__':
    sys.exit(main())
