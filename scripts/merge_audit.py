#!/usr/bin/env python3
"""Flag merges into next that didn't go through the triage desk's merge check.

Run by .github/workflows/merge-audit.yml on every push to next. For each pull request merged by the
push, it passes when the PR has an issue comment that starts with "**Merge check (triage desk)",
contains the first 7 characters of the merged head commit, and was posted before the merge.
A hand merge without that comment also passes when, before the merge, the head had what the owner's
hand-merge rule asks for (#742): the newest lane report the runner posted on the head says PASS, so does
the newest T3 report on the head if there is one, and the newest Codex or Claude audit naming the head says "No
blocking findings". Otherwise it adds the `merge-audit` label and says on the PR what was missing.
Commits pushed to next without any pull request get a `merge-audit` issue. It never reverts anything.

The owner may merge directly; they remove the label. The lead session surveys open `merge-audit`
labels each morning (docs/workstreams/kickoff.md).

  scripts/merge_audit.py --before <sha> --after <sha>     (GH_TOKEN and GH_REPO in the environment)
  scripts/merge_audit.py --sweep-hours 2                    PRs merged into next in the last 2 hours

The sweep exists because the lane runner merges with the workflow token (decision 3), and pushes
made with that token don't start other workflows, so no push run audits them. lane-runner.py runs
the sweep after each merge it pushes. The runner posts its merge check before it pushes, so its own
merges pass.
"""
from __future__ import annotations

import argparse
import datetime
import json
import os
import re
import subprocess
import sys
import time

# Whose comments count (#1822). .github/workflows/merge-audit.yml checks out this one file, so the rule of
# scripts/comment_trust.py is copied here, not imported; test_comment_trust.py fails if the two drift.
TRUSTED_ASSOCIATIONS = ('OWNER', 'MEMBER', 'COLLABORATOR')
TRUSTED_BOTS = ('github-actions[bot]',)
GRAPHQL_BOT_LOGINS = ('github-actions', 'app/github-actions')


def trusted(item: dict) -> bool:
    """Whether a comment (REST or `gh --json` shape) is from the owner, a member, a collaborator or the bot."""
    person = item.get('user') or item.get('author') or {}
    login = person.get('login') or ''
    association = item.get('author_association', item.get('authorAssociation'))
    if (isinstance(association, str) and association in TRUSTED_ASSOCIATIONS) or login in TRUSTED_BOTS:
        return True
    author = item.get('author')
    return (isinstance(author, dict) and login in GRAPHQL_BOT_LOGINS
            and (author.get('__typename') == 'Bot' or author.get('is_bot') is True))


def trusted_only(items: list[dict]) -> list[dict]:
    return [item for item in items or [] if trusted(item)]


PREFIX = '**Merge check (triage desk)'
LABEL = 'merge-audit'
LABEL_COLOR = 'b60205'
LABEL_DESCRIPTION = 'Merged into next without a triage-desk merge check (remove if the owner merged it)'
ZERO = '0' * 40
# The lane runner's report and audit formats (scripts/lane-runner.py: BOT, REPORT, MARKER, AUDITS,
# AUDIT_SHA, CLEAN_AUDIT). Reports count only from the runner's bot; agents post as the owner.
LANE_BOT = 'github-actions[bot]'
REPORT = re.compile(r'Lane report \S+ — (PASS|FAIL|INCONCLUSIVE)')
MARKER = re.compile(r'<!-- lane-request: (\{.*?\}) -->')
AUDITS = ('**Codex audit (Astra)', '## Codex audit', '**Claude audit on `')
AUDIT_SHA = re.compile(r'`([0-9a-f]{7,40})`')
CLEAN_AUDIT = re.compile(r'no (blocking )?findings\b', re.I)


def parse_time(text: str) -> datetime.datetime:
    return datetime.datetime.strptime(text, '%Y-%m-%dT%H:%M:%SZ')


def has_merge_check(comments: list[dict], head_sha: str, merged_at: str) -> bool:
    """Whether a triage-desk merge check for this head was posted before the merge."""
    sha7, merged = head_sha[:7], parse_time(merged_at)
    for comment in trusted_only(comments):  # #1822: a stranger's look-alike is not a merge check
        body = (comment.get('body') or '').lstrip()
        if body.startswith(PREFIX) and sha7 in body and parse_time(comment['created_at']) < merged:
            return True
    return False


def same_commit(a: str, b: str) -> bool:
    return bool(a) and bool(b) and (a.startswith(b) or b.startswith(a))


def lane_reports(comments: list[dict], head_sha: str, merged: datetime.datetime) -> list[tuple[str, str]]:
    """(verdict, tier) of the runner's lane reports on this head posted before the merge, oldest first."""
    found = []
    for comment in trusted_only(comments):
        if (comment.get('user') or {}).get('login') != LANE_BOT or parse_time(comment['created_at']) >= merged:
            continue
        body = (comment.get('body') or '').lstrip()
        verdict, marker = REPORT.match(body), MARKER.search(body)
        try:
            wanted = json.loads(marker.group(1)) if marker else {}
        except ValueError:
            wanted = {}
        if verdict and same_commit(wanted.get('commit', ''), head_sha):
            found.append((verdict.group(1), wanted.get('tier', '')))
    return found


def audit_verdict(comments: list[dict], head_sha: str, merged: datetime.datetime) -> str | None:
    """The verdict line of the newest Codex or Claude audit naming this head posted before the merge, if any."""
    verdict = None
    for comment in trusted_only(comments):  # #1822: only the owner's, a collaborator's or the bot's
        body = (comment.get('body') or '').lstrip()
        heading, _, rest = body.partition('\n')
        is_audit = (body.startswith(AUDITS[:2]) or
                    re.fullmatch(r'\*\*Claude audit on `[0-9a-f]{7,40}`\*\*', heading.rstrip()))
        if not is_audit or parse_time(comment['created_at']) >= merged:
            continue
        if any(same_commit(sha, head_sha) for sha in AUDIT_SHA.findall(heading)):
            verdict = next((line.strip() for line in rest.splitlines() if line.strip()), '')
    return verdict


def hand_merge_gap(comments: list[dict], head_sha: str, merged_at: str) -> str | None:
    """What the owner's hand-merge rule missed on this head before the merge, or None when it was all there.

    The rule (owner, 2026-10-01; #742): a lane PASS and a clean Codex or Claude audit on the head being merged. Lane
    changes the runner can't merge (`.github/`, `scripts/lane*`) are merged by hand this way.
    """
    sha7, merged = head_sha[:7], parse_time(merged_at)
    missing = []
    reports = lane_reports(comments, head_sha, merged)
    t3 = [verdict for verdict, tier in reports if tier == 'T3']
    if not reports:
        missing.append(f'no lane report on `{sha7}`')
    elif reports[-1][0] != 'PASS':
        missing.append(f'the newest lane report on `{sha7}` is {reports[-1][0]}')
    elif t3 and t3[-1] != 'PASS':
        missing.append(f'the newest T3 lane report on `{sha7}` is {t3[-1]}')
    verdict = audit_verdict(comments, head_sha, merged)
    if verdict is None:
        missing.append(f'no Codex or Claude audit of `{sha7}`')
    elif not CLEAN_AUDIT.match(verdict):
        missing.append(f'the Codex or Claude audit of `{sha7}` has blocking findings')
    return '; '.join(missing) or None


def trunk() -> str:
    """The trunk branch (scripts/trunk.py, #1492), imported late so the lane runner's base_policy load works."""
    from trunk import trunk_branch
    return trunk_branch()


def failure_comment(head_sha: str, gap: str | None = None, base: str | None = None) -> str:
    missing = f'Hand-merge rule not met before the merge: {gap}. ' if gap else ''
    return (f'Merged into {base or trunk()} without a triage-desk merge check on {head_sha[:7]}. {missing}'
            'If the owner merged this directly, remove the label.')


def recently_merged(recent: list[dict], hours: float, now: datetime.datetime, base: str | None = None) -> list[dict]:
    """PRs into <base> (the trunk by default) merged within the last `hours`."""
    since, base = now - datetime.timedelta(hours=hours), base or trunk()
    return [p for p in recent if p.get('merged_at') and (p.get('base') or {}).get('ref') == base
            and parse_time(p['merged_at']) >= since]


def classify_push(pushed: list[str], head: str, recent: list[dict], base: str | None = None) -> tuple[dict, bool]:
    """Which merged PRs this push brought in, and whether its tip came from no PR at all.

    recent are recently closed PRs into <base> (the trunk by default). A PR belongs to this push when its merge commit (merge,
    squash or rebase) is one of the pushed commits. GitHub's commit-to-PR lookup can't be used: for
    commits not on the default branch (main) it returns only open PRs.
    """
    pushed_set, base = set(pushed), base or trunk()
    merged = {p['number']: p for p in recent
              if p.get('merged_at') and p.get('merge_commit_sha') in pushed_set
              and (p.get('base') or {}).get('ref') == base}
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

    def recently_closed_into(self, base: str) -> list[dict]:
        return json.loads(self.api(f'repos/{self.repo}/pulls?state=closed&base={base}&sort=updated&direction=desc'
                                   '&per_page=50'))

    def ensure_label(self) -> None:
        self.api(f'repos/{self.repo}/labels', '-f', f'name={LABEL}', '-f', f'color={LABEL_COLOR}',
                 '-f', f'description={LABEL_DESCRIPTION}', check=False)  # already exists: fine

    def flag_pull(self, number: int, head_sha: str, gap: str | None = None, base: str | None = None) -> None:
        labels = {l['name'] for l in json.loads(self.api(f'repos/{self.repo}/issues/{number}'))['labels']}
        if LABEL in labels:
            return
        self.ensure_label()
        self.api('-X', 'POST', f'repos/{self.repo}/issues/{number}/labels', '-f', f'labels[]={LABEL}')
        self.api(f'repos/{self.repo}/issues/{number}/comments', '-f', f'body={failure_comment(head_sha, gap, base)}')

    def flag_direct(self, head: str, shas: list[str], base: str | None = None) -> None:
        base = base or trunk()
        self.ensure_label()
        lines = '\n'.join(f'- {sha}' for sha in shas)
        self.api(f'repos/{self.repo}/issues', '-f', f'title=merge-audit: {head[:7]} reached {base} without a pull '
                 'request', '-f', f'body=The push that moved {base} to {head} did not come from merging a pull request, '
                 f'so no triage-desk merge check could run. Pushed commits:\n{lines}\n\nIf the owner pushed '
                 'this, close the issue.', '-f', f'labels[]={LABEL}')


def audit_pull(github: 'GitHub', pull: dict, dry_run: bool, base: str | None = None) -> None:
    number, head = pull['number'], pull['head']['sha']
    comments = github.json_lines(f'repos/{github.repo}/issues/{number}/comments')
    if has_merge_check(comments, head, pull['merged_at']):
        print(f'#{number} ({head[:7]}): merge check found')
        return
    gap = hand_merge_gap(comments, head, pull['merged_at'])
    if gap is None:
        print(f'#{number} ({head[:7]}): merged by hand after a lane PASS and a clean Codex or Claude audit of the head')
        return
    print(f'#{number} ({head[:7]}): no triage-desk merge check before the merge ({gap}); flagged')
    if not dry_run:
        github.flag_pull(number, head, gap, base)


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--before')
    parser.add_argument('--after')
    parser.add_argument('--sweep-hours', type=float, help='audit PRs merged into the base within this many hours')
    parser.add_argument('--base', help='the branch the push moved, or the sweep audits (default: the trunk)')
    parser.add_argument('--dry-run', action='store_true', help='print the decisions; change nothing on GitHub')
    args = parser.parse_args(argv)
    base = args.base or trunk()
    github = GitHub(os.environ['GH_REPO'])
    if args.sweep_hours is not None:
        now = datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None, microsecond=0)
        for pull in sorted(recently_merged(github.recently_closed_into(base), args.sweep_hours, now, base),
                           key=lambda p: p['number']):
            audit_pull(github, pull, args.dry_run, base)
        return 0
    if not (args.before and args.after):
        parser.error('--before and --after are required unless --sweep-hours is given')
    pushed = github.pushed_commits(args.before, args.after)
    merged, direct = classify_push(pushed, args.after, github.recently_closed_into(base), base)
    if direct:  # the PR list can lag a merge by a moment
        time.sleep(10)
        merged, direct = classify_push(pushed, args.after, github.recently_closed_into(base), base)
    for _, pull in sorted(merged.items()):
        audit_pull(github, pull, args.dry_run, base)
    if direct:
        print(f'{args.after[:7]} reached {base} without a pull request; flagged')
        if not args.dry_run:
            github.flag_direct(args.after, pushed, base)
    return 0


if __name__ == '__main__':
    sys.exit(main())
