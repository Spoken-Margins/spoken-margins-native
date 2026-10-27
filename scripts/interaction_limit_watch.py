#!/usr/bin/env python3
"""Tells the owner before the repository's interaction limit lapses (#2371).

The collaborators-only limit set at the flip (#1393) expires on a date GitHub never warns about. Once a day this
reads `GET /repos/{repo}/interaction-limits` and, inside the last 30 days, opens one issue (`priority`,
`needs-owner`) or, at 7 days and when the limit is already gone, adds one comment to it. It never files more than
one comment per stage and never closes the issue: renewing is the owner's tap (Settings > Moderation options >
Interaction limits), and he closes it.

    interaction_limit_watch.py [--dry-run] [--now 2027-04-01T00:00:00Z]

Needs GITHUB_TOKEN and GITHUB_REPOSITORY; LIMIT_READ_TOKEN, if set, reads the limit instead. A token that can't read the limit (403 or 404) falls back to
FALLBACK_EXPIRY below, which is wrong after a renewal: update it in the same sitting. Standard library only.
"""
import argparse
import json
import os
import re
import sys
import urllib.error
import urllib.request
from datetime import datetime, timedelta, timezone

TITLE = "Renew the repository's interaction limit (collaborators only)"
LABELS = ['priority', 'needs-owner']
FALLBACK_EXPIRY = '2027-04-21T16:56:10Z'  # from the API on 2026-10-27; used only when the API can't be read
WARN_DAYS = 30
URGENT_DAYS = 7
MARKER = re.compile(r'<!-- interaction-limit: (\w+) -->')
API = 'https://api.github.com'


def parse_time(text):
    return datetime.fromisoformat(text.replace('Z', '+00:00')).astimezone(timezone.utc)


def stage(limit, now):
    """'ok', 'warn30', 'warn7' or 'gone' for the API's answer (`{}` when no limit is set)."""
    if not limit or not limit.get('limit'):
        return 'gone'
    if not limit.get('expires_at'):
        return 'ok'  # a limit with no end has nothing to renew
    remaining = parse_time(limit['expires_at']) - now
    if remaining <= timedelta(0):
        return 'gone'
    if remaining <= timedelta(days=URGENT_DAYS):
        return 'warn7'
    if remaining <= timedelta(days=WARN_DAYS):
        return 'warn30'
    return 'ok'


def decide(current, issue_open, marks):
    """The one GitHub action for this run: 'open', 'comment' or None."""
    if current == 'ok':
        return None
    if not issue_open:
        return 'open'
    return None if current in marks else 'comment'


def message(current, limit):
    expiry = limit.get('expires_at') if limit else None
    if current == 'gone':
        return ("The interaction limit is gone: anyone can open issues, pull requests and comments, and nothing but "
                "CONTRIBUTING enforces the contributor agreement (#1393). Set it again in Settings > Moderation "
                "options > Interaction limits, or replace it with a lasting rule.")
    when = f'**{expiry}**' if expiry else 'soon'
    urgency = 'in under 7 days' if current == 'warn7' else 'within 30 days'
    return (f"The collaborators-only interaction limit expires {when}, {urgency}. When it lapses anyone can open "
            "issues, pull requests and comments. Renew it in Settings > Moderation options > Interaction limits "
            "(owner tap), or replace it with a lasting rule, then close this issue.")


def request(method, path, token, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(API + path, data=data, method=method, headers={
        'Authorization': f'Bearer {token}',
        'Accept': 'application/vnd.github+json',
        'X-GitHub-Api-Version': '2022-11-28',
        'User-Agent': 'spoken-margins-interaction-limit-watch',
        **({'Content-Type': 'application/json'} if data is not None else {}),
    })
    with urllib.request.urlopen(req, timeout=30) as response:
        return json.loads(response.read() or b'null')


def read_limit(repo, token):
    """The API's limit, or the fallback with a note when the token can't read it."""
    try:
        return request('GET', f'/repos/{repo}/interaction-limits', token), None
    except urllib.error.HTTPError as error:
        if error.code not in (403, 404):
            raise
        return {'limit': 'collaborators_only', 'expires_at': FALLBACK_EXPIRY}, (
            f'The token could not read the limit (HTTP {error.code}); using the known expiry {FALLBACK_EXPIRY}.')


def open_issue(repo, token):
    for page in range(1, 11):
        issues = request('GET', f'/repos/{repo}/issues?state=open&per_page=100&page={page}', token)
        for issue in issues:
            if 'pull_request' not in issue and issue['title'] == TITLE:
                return issue
        if len(issues) < 100:
            return None
    return None


def marks_seen(repo, token, issue):
    marks = set(MARKER.findall(issue.get('body') or ''))
    for comment in request('GET', f'/repos/{repo}/issues/{issue["number"]}/comments?per_page=100', token):
        marks.update(MARKER.findall(comment.get('body') or ''))
    return marks


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--dry-run', action='store_true')
    parser.add_argument('--now', help='ISO time to act as (for testing)')
    args = parser.parse_args()
    repo, token = os.environ['GITHUB_REPOSITORY'], os.environ['GITHUB_TOKEN']
    now = parse_time(args.now) if args.now else datetime.now(timezone.utc)
    limit, note = read_limit(repo, os.environ.get('LIMIT_READ_TOKEN') or token)
    if note:
        print(note)
    current = stage(limit, now)
    issue = open_issue(repo, token)
    action = decide(current, issue is not None, marks_seen(repo, token, issue) if issue else set())
    print(f'Interaction limit: {current}, open issue {issue["number"] if issue else "none"}: {action or "nothing to file"}.')
    if action is None or args.dry_run:
        return 0
    text = message(current, limit) + (f'\n\n_{note}_' if note else '') + f'\n\n<!-- interaction-limit: {current} -->\n'
    if action == 'open':
        created = request('POST', f'/repos/{repo}/issues', token, {'title': TITLE, 'body': text, 'labels': LABELS})
        print(f'Opened #{created["number"]}.')
    else:
        request('POST', f'/repos/{repo}/issues/{issue["number"]}/comments', token, {'body': text})
        print(f'Commented on #{issue["number"]}.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
