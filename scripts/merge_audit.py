#!/usr/bin/env python3
"""Flag merges into next that didn't go through the triage desk's merge check.

Run by .github/workflows/merge-audit.yml on every push to next. For each pull request merged by the
push, it passes when the PR has an issue comment that starts with "**Merge check (triage desk)",
contains the first 7 characters of the merged head commit, and was posted before the merge.
Otherwise it adds the `merge-audit` label and says so on the PR. Commits pushed to next without any
pull request get a `merge-audit` issue. It never reverts anything.

The owner may merge directly; they remove the label. The lead session surveys open `merge-audit`
labels each morning (docs/workstreams/kickoff.md).

  scripts/merge_audit.py --before <sha> --after <sha>     (GH_TOKEN and GH_REPO in the environment)
  scripts/merge_audit.py --sweep-hours 2                    PRs merged into next in the last 2 hours

The sweep exists because the lane runner merges with the workflow token (decision 3), and pushes
made with that token don't start other workflows, so no push run audits them. The runner posts its
merge check before it pushes, so its own merges pass.
"""
from __future__ import annotations

import argparse
import datetime
import json
import os
import subprocess
import sys
import time

PREFIX = '**Merge check (triage desk)'
LABEL = 'merge-audit'
LABEL_COLOR = 'b60205'
LABEL_DESCRIPTION = 'Merged into next without a triage-desk merge check (remove if the owner merged it)'
ZERO = '0' * 40


def parse_time(text: str) -> datetime.datetime:
    return datetime.datetime.strptime(text, '%Y-%m-%dT%H:%M:%SZ')


def has_merge_check(comments: list[dict], head_sha: str, merged_at: str) -> bool:
    """Whether a triage-desk merge check for this head was posted before the merge."""
    sha7, merged = head_sha[:7], parse_time(merged_at)
    for comment in comments:
        body = (comment.get('body') or '').lstrip()
        if body.startswith(PREFIX) and sha7 in body and parse_time(comment['created_at']) < merged:
            return True
    return False


def failure_comment(head_sha: str) -> str:
    return (f'Merged into next without a triage-desk merge check on {head_sha[:7]}. '
            'If the owner merged this directly, remove the label.')


def recently_merged(recent: list[dict], hours: float, now: datetime.datetime) -> list[dict]:
    """PRs into next merged within the last `hours`."""
    since = now - datetime.timedelta(hours=hours)
    return [p for p in recent if p.get('merged_at') and (p.get('base') or {}).get('ref') == 'next'
            and parse_time(p['merged_at']) >= since]


def classify_push(pushed: list[str], head: str, recent: list[dict]) -> tuple[dict, bool]:
    """Which merged PRs this push brought in, and whether its tip came from no PR at all.

    recent are recently closed PRs into next. A PR belongs to this push when its merge commit (merge,
    squash or rebase) is one of the pushed commits. GitHub's commit-to-PR lookup can't be used: for
    commits not on the default branch (main) it returns only open PRs.
    """
    pushed_set = set(pushed)
    merged = {p['number']: p for p in recent
              if p.get('merged_at') and p.get('merge_commit_sha') in pushed_set
              and (p.get('base') or {}).get('ref') == 'next'}
    tip_from_pr = any(p['merge_commit_sha'] == head for p in merged.values())
    return merged, not tip_from_pr


class GitHub:
    def __init__(self, repo: str):
        self.repo = repo

    def api(self, *args: str, check: bool = True) -> str:
        done = subprocess.run(['gh', 'api', *args], capture_output=True, text=True)
        if check and done.returncode:
            raise RuntimeError(f'gh api {" ".join(args)}: {done.stderr.strip()}')
        return done.stdout

    def json_lines(self, path: str) -> list[dict]:
        out = self.api('--paginate', '--jq', '.[] | @json', path)
        return [json.loads(line) for line in out.splitlines() if line.strip()]

    def pushed_commits(self, before: str, after: str) -> list[str]:
        if before == ZERO:
            return [after]
        try:
            compare = json.loads(self.api(f'repos/{self.repo}/compare/{before}...{after}'))
            shas = [c['sha'] for c in compare.get('commits', [])]
            return shas or [after]
        except (RuntimeError, ValueError):
            return [after]  # a force-push: audit the head only

    def recently_closed_into_next(self) -> list[dict]:
        return json.loads(self.api(f'repos/{self.repo}/pulls?state=closed&base=next&sort=updated&direction=desc'
                                   '&per_page=50'))

    def ensure_label(self) -> None:
        self.api(f'repos/{self.repo}/labels', '-f', f'name={LABEL}', '-f', f'color={LABEL_COLOR}',
                 '-f', f'description={LABEL_DESCRIPTION}', check=False)  # already exists: fine

    def flag_pull(self, number: int, head_sha: str) -> None:
        labels = {l['name'] for l in json.loads(self.api(f'repos/{self.repo}/issues/{number}'))['labels']}
        if LABEL in labels:
            return
        self.ensure_label()
        self.api('-X', 'POST', f'repos/{self.repo}/issues/{number}/labels', '-f', f'labels[]={LABEL}')
        self.api(f'repos/{self.repo}/issues/{number}/comments', '-f', f'body={failure_comment(head_sha)}')

    def flag_direct(self, head: str, shas: list[str]) -> None:
        self.ensure_label()
        lines = '\n'.join(f'- {sha}' for sha in shas)
        self.api(f'repos/{self.repo}/issues', '-f', f'title=merge-audit: {head[:7]} reached next without a pull '
                 'request', '-f', f'body=The push that moved next to {head} did not come from merging a pull request, '
                 f'so no triage-desk merge check could run. Pushed commits:\n{lines}\n\nIf the owner pushed '
                 'this, close the issue.', '-f', f'labels[]={LABEL}')


def audit_pull(github: 'GitHub', pull: dict, dry_run: bool) -> None:
    number, head = pull['number'], pull['head']['sha']
    comments = github.json_lines(f'repos/{github.repo}/issues/{number}/comments')
    if has_merge_check(comments, head, pull['merged_at']):
        print(f'#{number} ({head[:7]}): merge check found')
    else:
        print(f'#{number} ({head[:7]}): no triage-desk merge check before the merge; flagged')
        if not dry_run:
            github.flag_pull(number, head)


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--before')
    parser.add_argument('--after')
    parser.add_argument('--sweep-hours', type=float, help='audit PRs merged into next within this many hours')
    parser.add_argument('--dry-run', action='store_true', help='print the decisions; change nothing on GitHub')
    args = parser.parse_args(argv)
    github = GitHub(os.environ['GH_REPO'])
    if args.sweep_hours is not None:
        now = datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None, microsecond=0)
        for pull in sorted(recently_merged(github.recently_closed_into_next(), args.sweep_hours, now),
                           key=lambda p: p['number']):
            audit_pull(github, pull, args.dry_run)
        return 0
    if not (args.before and args.after):
        parser.error('--before and --after are required unless --sweep-hours is given')
    pushed = github.pushed_commits(args.before, args.after)
    merged, direct = classify_push(pushed, args.after, github.recently_closed_into_next())
    if direct:  # the PR list can lag a merge by a moment
        time.sleep(10)
        merged, direct = classify_push(pushed, args.after, github.recently_closed_into_next())
    for _, pull in sorted(merged.items()):
        audit_pull(github, pull, args.dry_run)
    if direct:
        print(f'{args.after[:7]} reached next without a pull request; flagged')
        if not args.dry_run:
            github.flag_direct(args.after, pushed)
    return 0


if __name__ == '__main__':
    sys.exit(main())
