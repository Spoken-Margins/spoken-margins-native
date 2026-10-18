#!/usr/bin/env python3
"""Tell the owner's phone when a PR into next waits only for his merge tap (#2047).

The lane runner never merges a PR touching `scripts/lane-runner.py` or anything under `.github/` (owner rule
2026-10-09, `owner_tap_paths` in scripts/lane-runner.py); the owner merges those himself. Nothing told him when
one was ready: every agent comment is posted under his own account, and GitHub never notifies anyone of their
own activity. On 2026-10-18 #1964, #1966, #2038 and #1885 sat waiting only for his tap.

This script runs in .github/workflows/owner-tap-alert.yml as `github-actions[bot]`. For each open PR into the base
that touches those paths and is ready, it posts one comment that @mentions the owner. The GitHub mobile app pushes
mentions by default, and tapping the push opens the PR. A PR is ready when all of these hold (`readiness`):

1. it is not a draft, and its head is in this repository (no forks);
2. GitHub says it merges cleanly (`mergeable` true; an unknown answer waits for the next run);
3. no check run or commit status on the head failed or is still running (this workflow's own job is ignored);
4. if a Claude (or legacy Codex) audit names the head, the newest one opens "No blocking findings". With no audit
   of the head the PR is still ready, and the alert says so: on 2026-10-18 none of the four PRs above had a lane
   report or an audit, because nothing arms a PR the runner can't merge, so waiting for one would never alert;
5. no alert names this head yet. The alert carries `<!-- owner-tap-alert: <full head sha> -->`, so a new push
   alerts again once it is ready and a re-run never repeats one.

Only trusted comments are read (scripts/comment_trust.py, #1822), so after the repository goes public a
stranger's look-alike audit or alert marker can't start or stop an alert.

Any doubt (an API error, a head that moved during the run) posts nothing for that PR; the next run tries again.

  python3 scripts/owner_tap_alert.py --base next --mention uncomposed [--pr N] [--dry-run]

GH_TOKEN and GH_REPO (owner/name) come from the environment. Stdlib only.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import comment_trust  # noqa: E402

# The runner's owner-tap paths (scripts/lane-runner.py OWNER_TAP_FILES, OWNER_TAP_PREFIXES). A test keeps them equal.
OWNER_TAP_FILES = {'scripts/lane-runner.py'}
OWNER_TAP_PREFIXES = ('.github/',)
# The runner's audit formats (scripts/lane-runner.py AUDITS, AUDIT_SHA, CLEAN_AUDIT). A test keeps them equal.
AUDITS = ('**Codex audit (Astra)', '## Codex audit', '**Claude audit on `')
AUDIT_SHA = re.compile(r'`([0-9a-f]{7,40})`')
CLEAN_AUDIT = re.compile(r'no (blocking )?findings\b', re.I)
MARKER = '<!-- owner-tap-alert: {sha} -->'
MARKER_RE = re.compile(r'<!-- owner-tap-alert: ([0-9a-f]{40}) -->')
# This workflow's own job: it is always running on the head of the PR that started it.
OWN_CHECK = 'owner-tap-alert'
FAILED = {'failure', 'timed_out', 'cancelled', 'action_required', 'startup_failure', 'stale'}


def owner_tap_paths(files: list[dict]) -> list[str]:
    """The changed paths only the owner merges, counting both sides of a rename (REST pulls/N/files shape)."""
    paths = set()
    for f in files:
        paths.update(p for p in (f.get('filename'), f.get('previous_filename')) if p)
    return sorted(p for p in paths if p in OWNER_TAP_FILES or p.startswith(OWNER_TAP_PREFIXES))


def is_audit(body: str) -> bool:
    heading = body.partition('\n')[0].rstrip()
    return body.startswith(AUDITS[:2]) or bool(re.fullmatch(r'\*\*Claude audit on `[0-9a-f]{7,40}`\*\*', heading))


def head_audit_verdict(comments: list[dict], head: str) -> str | None:
    """The verdict line of the newest trusted audit whose heading names the head, or None when there is none."""
    verdict, newest = None, ''
    for c in comment_trust.trusted_only(comments):
        body = (c.get('body') or '').lstrip()
        if not is_audit(body):
            continue
        heading, _, rest = body.partition('\n')
        if any(head.startswith(sha) for sha in AUDIT_SHA.findall(heading)) and (c.get('created_at') or '') >= newest:
            newest = c.get('created_at') or ''
            verdict = next((line.strip() for line in rest.splitlines() if line.strip()), '')
    return verdict


def alerted(comments: list[dict], head: str) -> bool:
    return any(head in MARKER_RE.findall(c.get('body') or '') for c in comment_trust.trusted_only(comments))


def checks_state(check_runs: list[dict], statuses: list[dict]) -> tuple[str, list[str]]:
    """('failed' | 'pending' | 'ok', names) for the head's check runs (newest per name) and commit statuses."""
    failed, pending = [], []
    for run in check_runs:
        name = run.get('name') or '?'
        if name == OWN_CHECK:
            continue
        if run.get('status') != 'completed':
            pending.append(name)
        elif run.get('conclusion') in FAILED:
            failed.append(name)
    seen = set()
    for status in statuses:  # newest first from the API: the first per context is the current one
        context = status.get('context') or '?'
        if context in seen:
            continue
        seen.add(context)
        if status.get('state') in ('failure', 'error'):
            failed.append(context)
        elif status.get('state') == 'pending':
            pending.append(context)
    if failed:
        return 'failed', failed
    if pending:
        return 'pending', pending
    return 'ok', []


def readiness(pr: dict, files: list[dict], check_runs: list[dict], statuses: list[dict],
              comments: list[dict], repo: str) -> tuple[bool, str]:
    """(ready, why) for one open PR. `pr` is the REST pulls/N shape."""
    head = pr['head']['sha']
    tap = owner_tap_paths(files)
    if not tap:
        return False, 'no owner-tap paths'
    if pr.get('draft'):
        return False, 'draft'
    if (pr['head'].get('repo') or {}).get('full_name') != repo:
        return False, 'head is not in this repository'
    if pr.get('mergeable') is None:
        return False, 'GitHub has not worked out mergeability yet'
    if not pr.get('mergeable') or pr.get('mergeable_state') == 'dirty':
        return False, 'conflicts with the base'
    state, names = checks_state(check_runs, statuses)
    if state != 'ok':
        return False, f'checks {state}: {", ".join(sorted(set(names)))}'
    verdict = head_audit_verdict(comments, head)
    if verdict is not None and not CLEAN_AUDIT.match(verdict):
        return False, f'the audit of {head[:7]} has blocking findings'
    if alerted(comments, head):
        return False, f'already alerted on {head[:7]}'
    return True, 'ready: ' + ', '.join(tap)


def alert_body(pr: dict, tap: list[str], mention: str, audited: bool) -> str:
    head = pr['head']['sha']
    shown = ', '.join(f'`{p}`' for p in tap[:5]) + (f' and {len(tap) - 5} more' if len(tap) > 5 else '')
    audit = ('the Claude audit of this head found no blocking findings' if audited
             else 'no Claude audit covers this head')
    return (f'@{mention} ready for your merge tap. This PR touches {shown}, which only you merge. '
            f'On head `{head[:7]}` it merges cleanly, its checks passed, and {audit}. '
            'Tap **Merge pull request** below.\n\n'
            '_Posted by the owner-tap alert (scripts/owner_tap_alert.py, #2047): one alert per head._\n'
            + MARKER.format(sha=head))


class GitHubApi:
    def __init__(self, repo: str):
        self.repo = repo

    def _run(self, args: list[str]) -> str:
        return subprocess.run(['gh', 'api', *args], text=True, timeout=60, capture_output=True, check=True).stdout

    def get(self, path: str):
        return json.loads(self._run([f'repos/{self.repo}/{path}']))

    def get_all(self, path: str) -> list:
        pages = json.loads(self._run(['--paginate', '--slurp', f'repos/{self.repo}/{path}']))
        out = []
        for page in pages:
            if isinstance(page, dict) and 'check_runs' in page:
                out.extend(page['check_runs'])
            elif isinstance(page, list):
                out.extend(page)
            else:
                out.append(page)
        return out

    def comment(self, number: int, body: str) -> None:
        self._run(['-X', 'POST', f'repos/{self.repo}/issues/{number}/comments', '-f', f'body={body}'])


def check_pr(api: GitHubApi, number: int, mention: str, dry_run: bool) -> str:
    files = api.get_all(f'pulls/{number}/files?per_page=100')
    if not owner_tap_paths(files):
        return 'no owner-tap paths'
    pr = api.get(f'pulls/{number}')  # the single-PR read is the one that carries `mergeable`
    head = pr['head']['sha']
    runs = api.get_all(f'commits/{head}/check-runs?filter=latest&per_page=100')
    statuses = api.get_all(f'commits/{head}/statuses?per_page=100')
    comments = api.get_all(f'issues/{number}/comments?per_page=100')
    ready, why = readiness(pr, files, runs, statuses, comments, api.repo)
    if not ready:
        return why
    if api.get(f'pulls/{number}')['head']['sha'] != head:
        return 'head moved during the check'
    tap = owner_tap_paths(files)
    body = alert_body(pr, tap, mention, head_audit_verdict(comments, head) is not None)
    if dry_run:
        return why + ' (dry run, nothing posted)'
    api.comment(number, body)
    return why + ', alert posted'


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    ap.add_argument('--repo', default=os.environ.get('GH_REPO', ''))
    ap.add_argument('--base', default='next')
    ap.add_argument('--mention', required=True, help='login to @mention (the repository owner)')
    ap.add_argument('--pr', type=int, help='check only this PR')
    ap.add_argument('--dry-run', action='store_true')
    args = ap.parse_args(argv)
    if not args.repo or not re.fullmatch(r'[A-Za-z0-9_.-]+', args.mention):
        ap.error('need --repo (or GH_REPO) and a plain --mention login')
    api = GitHubApi(args.repo)
    if args.pr:
        numbers = [args.pr]
    else:
        numbers = [p['number'] for p in api.get_all(f'pulls?state=open&base={args.base}&per_page=100')]
    failures = 0
    for number in numbers:
        try:
            print(f'#{number}: {check_pr(api, number, args.mention, args.dry_run)}')
        except (subprocess.SubprocessError, ValueError, KeyError) as exc:  # this PR waits for the next run
            failures += 1
            detail = (getattr(exc, 'stderr', '') or str(exc)).strip().splitlines()
            print(f'#{number}: skipped, {type(exc).__name__}: {detail[0][:160] if detail else ""}')
    print(f'{len(numbers)} open PRs into {args.base} checked, {failures} skipped on errors')
    return 0


if __name__ == '__main__':
    sys.exit(main())
