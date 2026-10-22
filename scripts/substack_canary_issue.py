#!/usr/bin/env python3
"""Files the Substack canary's result on GitHub (#2027): one open issue, never one a day.

On a failure it opens an issue labelled `ready` and `regression`, or comments on the open one with the same
title, skipping the comment when the failure reads exactly as the last one did. On a pass it says so once on
an open issue, so whoever is fixing it knows it is green again; it never closes the issue. An inconclusive
run (feeds couldn't be read) files nothing.

    substack_canary_issue.py --status <canary exit status> --report <canary report.md> --run-url <url> [--dry-run]

Needs GITHUB_TOKEN (issues: write) and GITHUB_REPOSITORY. Standard library only, so the VPS runner needs
nothing installed.
"""
import argparse
import hashlib
import json
import os
import re
import sys
import urllib.parse
import urllib.request

TITLE = "Substack canary: the app's parser missed a publisher voice"
MARKER = re.compile(r'<!-- substack-canary: (\S+) -->')
API = 'https://api.github.com'


def signature(report):
    """What failed, without post titles or dates, so the same breakage on newer posts reads the same."""
    reasons = sorted({line.split('): ', 1)[1].strip()
                      for line in report.splitlines()
                      if '): FAIL' in line})
    if not reasons:
        reasons = [line.strip() for line in report.splitlines()[:1]]
    return hashlib.sha256('\n'.join(reasons).encode()).hexdigest()[:16]


def decide(status, issue_open, last_mark, sig):
    """The one GitHub action for this run: 'open', 'comment', 'pass_note' or None."""
    if status == 1:
        if not issue_open:
            return 'open'
        return None if last_mark == sig else 'comment'
    if status == 0 and issue_open and last_mark not in (None, 'pass'):
        return 'pass_note'
    return None


def request(method, path, token, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(API + path, data=data, method=method, headers={
        'Authorization': f'Bearer {token}',
        'Accept': 'application/vnd.github+json',
        'X-GitHub-Api-Version': '2022-11-28',
        'User-Agent': 'spoken-margins-substack-canary',
    })
    with urllib.request.urlopen(req, timeout=30) as response:
        return json.loads(response.read() or b'null')


def open_issue(repo, token):
    for page in range(1, 11):
        issues = request('GET', f'/repos/{repo}/issues?state=open&per_page=100&page={page}', token)
        for issue in issues:
            if 'pull_request' not in issue and issue['title'] == TITLE:
                return issue
        if len(issues) < 100:
            return None
    return None


def last_mark(repo, token, issue):
    marks = MARKER.findall(issue.get('body') or '')
    comments = request('GET', f'/repos/{repo}/issues/{issue["number"]}/comments?per_page=100', token)
    for comment in comments:
        marks += MARKER.findall(comment.get('body') or '')
    return marks[-1] if marks else None


def issue_body(report, run_url, sig):
    return (
        "The daily Substack canary found a Substack post page whose publisher voice the app's parser "
        "(`PublisherNarrationEvidence`) didn't read, or found no voice on any feed. This is the #2024 class: "
        "Substack changed its page format and the app quietly stopped finding the voice.\n\n"
        "What to do: open one of the posts below, compare its page with the parser's expectations, and fix "
        "the parser in SessionKitFeeds with a fixture of the new format. The canary runs the code on the trunk (`main`), "
        "so it goes green on the first run after the fix merges. To run it by hand: "
        "`scripts/substack-canary.sh`.\n\n"
        f"Run: {run_url}\n\n{report}\n<!-- substack-canary: {sig} -->\n"
    )


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--status', type=int, required=True)
    parser.add_argument('--report', required=True)
    parser.add_argument('--run-url', default='')
    parser.add_argument('--dry-run', action='store_true')
    args = parser.parse_args()
    report = open(args.report, encoding='utf-8').read() if os.path.exists(args.report) else '(no report)\n'
    sig = signature(report)
    if args.status not in (0, 1):
        print(f'Canary status {args.status}: nothing filed.')
        return 0
    repo, token = os.environ['GITHUB_REPOSITORY'], os.environ['GITHUB_TOKEN']
    issue = open_issue(repo, token)
    action = decide(args.status, issue is not None, last_mark(repo, token, issue) if issue else None, sig)
    print(f'Canary status {args.status}, open issue {issue["number"] if issue else "none"}: {action or "nothing to file"}.')
    if action is None or args.dry_run:
        return 0
    if action == 'open':
        created = request('POST', f'/repos/{repo}/issues', token, {
            'title': TITLE, 'body': issue_body(report, args.run_url, sig), 'labels': ['ready', 'regression'],
        })
        print(f'Opened #{created["number"]}.')
    elif action == 'comment':
        request('POST', f'/repos/{repo}/issues/{issue["number"]}/comments', token, {
            'body': f'The canary still fails, differently from the last report. Run: {args.run_url}\n\n{report}\n'
                    f'<!-- substack-canary: {sig} -->\n'})
        # Keep it in the queue even if someone took a label off.
        request('POST', f'/repos/{repo}/issues/{issue["number"]}/labels', token, {'labels': ['ready', 'regression']})
    else:
        request('POST', f'/repos/{repo}/issues/{issue["number"]}/comments', token, {
            'body': f'The canary passes again on the trunk (`main`). Close this once the fix is confirmed. Run: {args.run_url}\n\n'
                    f'{report}\n<!-- substack-canary: pass -->\n'})
    return 0


if __name__ == '__main__':
    sys.exit(main())
