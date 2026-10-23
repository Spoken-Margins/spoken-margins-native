#!/usr/bin/env python3
"""Tell the owner's phone when a PR into next waits only for his merge tap (#2047).

The lane runner never merges a PR touching `scripts/lane-runner.py` or anything under `.github/` (owner rule
2026-10-09, `owner_tap_paths` in scripts/lane-runner.py); the owner merges those himself. Nothing told him when
one was ready: every agent comment is posted under his own account, and GitHub never notifies anyone of their
own activity. On 2026-10-18 #1964, #1966, #2038 and #1885 sat waiting only for his tap.

Run in GitHub Actions as `github-actions[bot]` (see "Where it runs" below), for each open PR into the base that
touches those paths and is ready, it posts one comment that @mentions the owner. The GitHub mobile app pushes
mentions by default, and tapping the push opens the PR. A PR is ready when all of these hold (`readiness`):

1. it is not a draft, and its head is in this repository (no forks);
2. GitHub says it merges cleanly (`mergeable` true; an unknown answer waits for the next run);
3. no check run or commit status on the head failed or is still running (this workflow's own job is ignored);
4. if a Claude (or legacy Codex) audit names the head, the newest one opens "No blocking findings". With no audit
   of the head the PR is still ready, and the alert says so: on 2026-10-18 none of the four PRs above had a lane
   report or an audit, because nothing arms a PR the runner can't merge, so waiting for one would never alert;
5. no alert names this head yet. The alert carries `<!-- owner-tap-alert: <full head sha> -->`, so a new push
   alerts again once it is ready and a re-run never repeats one.

Persistent label (owner, 2026-10-22). While a PR qualifies for his tap (every rule above except "no alert names this
head yet", so it keeps the label after the alert), it carries `needs-owner-tap`, so he can filter for what waits on
him. The label is created when missing. It comes off when the PR stops qualifying (new head with failing or pending
checks, a blocking audit, a conflict, a draft) or no longer touches the owner-tap paths, and a sweep of every open
PR also strips it from closed and merged PRs. Adding and removing it only needs `issues: write` on the job token.

An alert posted before the audit says so. When the audit of that head lands afterwards (the audit script audits an
owner-tap PR once its checks finish and then asks for a check, #2052), one follow-up comment says "no blocking
findings" or names the blocking verdict, so his tap rests on the audit either way. One follow-up per head.

Only trusted comments are read (scripts/comment_trust.py, #1822), so after the repository goes public a
stranger's look-alike audit or alert marker can't start or stop an alert.

Any doubt (an API error, a head that moved during the run) posts nothing for that PR; the next run tries again.

Where it runs. The alert must come from the bot, so it is posted only inside GitHub Actions:
  * at the end of hosted-portable.yml and shipped-build-compat.yml (their `owner-tap-alert` job, `--pr N`), so it is
    decided when a PR's checks finish. A workflow_dispatch can't start it: GitHub reads a workflow's dispatch
    trigger from main, which doesn't carry this one until #1492 (hosted-app-macos.yml records the same limit);
  * in owner-tap-alert.yml when the PR gets the `owner-tap-check` label (`--pr N --clear-label owner-tap-check`).
From the Mac, where `gh` is the owner and a comment would notify nobody, `--via-label owner-tap-check` checks the
same rules and, for a ready PR, removes and re-adds that label instead of commenting; the labeled run posts. The
audit script re-adds the label after auditing an owner-tap PR.

  python3 scripts/owner_tap_alert.py --pr N [--clear-label owner-tap-check]       (in Actions)
  python3 scripts/owner_tap_alert.py --via-label owner-tap-check [--pr N]           (on the Mac)
  python3 scripts/owner_tap_alert.py --dry-run

GH_TOKEN (Actions) and GH_REPO (owner/name) come from the environment; --mention defaults to the repository's
owner. Stdlib only.
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
OWNER_LOGIN = 'uncomposed'  # who to @mention; the repo's owner is the org after #2169
OWNER_TAP_FILES = {'scripts/lane-runner.py'}
OWNER_TAP_PREFIXES = ('.github/',)
# The runner's audit formats (scripts/lane-runner.py AUDITS, AUDIT_SHA, CLEAN_AUDIT). A test keeps them equal.
AUDITS = ('**Codex audit (Astra)', '## Codex audit', '**Claude audit on `')
AUDIT_SHA = re.compile(r'`([0-9a-f]{7,40})`')
CLEAN_AUDIT = re.compile(r'no (blocking )?findings\b', re.I)
MARKER = '<!-- owner-tap-alert: {sha} -->'
MARKER_RE = re.compile(r'<!-- owner-tap-alert: ([0-9a-f]{40}) -->')
FOLLOWUP_MARKER = '<!-- owner-tap-audit: {sha} -->'
FOLLOWUP_RE = re.compile(r'<!-- owner-tap-audit: ([0-9a-f]{40}) -->')
NO_AUDIT_TEXT = 'no Claude audit covers this head'  # what an alert posted before the audit says (alert_body)
# The job that runs this script (the same name in all three workflows): it is running on the head while it checks it.
OWN_CHECKS = {'owner-tap-alert'}
LABEL = 'owner-tap-check'  # the Mac's and the audit script's way to ask Actions for a check (--via-label)
TAP_LABEL = 'needs-owner-tap'  # persistent: this PR waits only for the owner's merge tap
TAP_LABEL_DESCRIPTION = "Waits only for the owner's merge tap (.github or lane-runner change)"
TAP_LABEL_COLOR = '0075ca'  # blue
ALREADY_ALERTED = 'already alerted on'
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
        if name in OWN_CHECKS:
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


def qualifies(ready: bool, why: str) -> bool:
    """Whether a `readiness` answer means the PR waits for the owner's tap: ready, or ready but already alerted."""
    return ready or why.startswith(ALREADY_ALERTED)


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
        return False, f'{ALREADY_ALERTED} {head[:7]}'
    return True, 'ready: ' + ', '.join(tap)


def alert_body(pr: dict, tap: list[str], mention: str, audited: bool) -> str:
    head = pr['head']['sha']
    shown = ', '.join(f'`{p}`' for p in tap[:5]) + (f' and {len(tap) - 5} more' if len(tap) > 5 else '')
    audit = ('the Claude audit of this head found no blocking findings' if audited else NO_AUDIT_TEXT)
    return (f'@{mention} ready for your merge tap. This PR touches {shown}, which only you merge. '
            f'On head `{head[:7]}` it merges cleanly, its checks passed, and {audit}. '
            'Tap **Merge pull request** below.\n\n'
            '_Posted by the owner-tap alert (scripts/owner_tap_alert.py, #2047): one alert per head._\n'
            + MARKER.format(sha=head))


def followed_up(comments: list[dict], head: str) -> bool:
    return any(head in FOLLOWUP_RE.findall(c.get('body') or '') for c in comment_trust.trusted_only(comments))


def alerted_without_audit(comments: list[dict], head: str) -> bool:
    """An alert named this head and said no audit covered it."""
    return any(head in MARKER_RE.findall(c.get('body') or '') and NO_AUDIT_TEXT in (c.get('body') or '')
               for c in comment_trust.trusted_only(comments))


def followup_verdict(pr: dict, comments: list[dict], repo: str) -> str | None:
    """The audit verdict line when a follow-up is due: the head was alerted before its audit, the audit has landed
    since, and no follow-up names the head. None for a draft, a fork, or anything else."""
    head = pr['head']['sha']
    if pr.get('draft') or (pr['head'].get('repo') or {}).get('full_name') != repo:
        return None
    if not alerted_without_audit(comments, head) or followed_up(comments, head):
        return None
    return head_audit_verdict(comments, head)


def followup_body(head: str, mention: str, verdict: str) -> str:
    if CLEAN_AUDIT.match(verdict):
        result = 'it found no blocking findings.'
    else:
        result = f'it has blocking findings, so hold your tap until they are fixed. Its verdict: {verdict[:200]}'
    return (f'@{mention} the Claude audit of head `{head[:7]}` landed after the alert above: {result}\n\n'
            '_Posted by the owner-tap alert (scripts/owner_tap_alert.py, #2052): one follow-up per head._\n'
            + FOLLOWUP_MARKER.format(sha=head))


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

    def remove_label(self, number: int, label: str) -> None:
        """Remove a label from the PR; one it doesn't carry is not an error."""
        try:
            self._run(['-X', 'DELETE', f'repos/{self.repo}/issues/{number}/labels/{label}'])
        except subprocess.CalledProcessError as exc:
            if 'HTTP 404' not in (exc.stderr or ''):
                raise

    def add_tap_label(self, number: int) -> None:
        """Add `needs-owner-tap`, creating the label first when the repository lacks it."""
        try:
            self._run(['-X', 'POST', f'repos/{self.repo}/labels', '-f', f'name={TAP_LABEL}',
                       '-f', f'color={TAP_LABEL_COLOR}', '-f', f'description={TAP_LABEL_DESCRIPTION}'])
        except subprocess.CalledProcessError as exc:
            if 'HTTP 422' not in (exc.stderr or ''):  # 422: the label exists already
                raise
        self._run(['-X', 'POST', f'repos/{self.repo}/issues/{number}/labels', '-f', f'labels[]={TAP_LABEL}'])

    def closed_with_tap_label(self) -> list[int]:
        """Closed or merged PRs that still carry `needs-owner-tap` (one call, newest first)."""
        found = self.get_all(f'issues?state=closed&labels={TAP_LABEL}&per_page=100')
        return [i['number'] for i in found if 'pull_request' in i]

    def readd_label(self, number: int, label: str) -> None:
        """Remove and add the label, so GitHub sends a `labeled` event even when the PR already carried it."""
        self.remove_label(number, label)
        self._run(['-X', 'POST', f'repos/{self.repo}/issues/{number}/labels', '-f', f'labels[]={label}'])


def sync_tap_label(api: GitHubApi, number: int, pr: dict, waits: bool, dry_run: bool) -> None:
    """Make the PR carry `needs-owner-tap` exactly while it waits for the owner's tap; no write when it already does."""
    has = any(label.get('name') == TAP_LABEL for label in pr.get('labels') or [])
    if dry_run or waits == has:
        return
    try:
        if waits:
            api.add_tap_label(number)
        else:
            api.remove_label(number, TAP_LABEL)
    except subprocess.SubprocessError as exc:  # a label is a convenience: never block the alert, the next run retries
        print(f'#{number}: could not update `{TAP_LABEL}`: {(getattr(exc, "stderr", "") or "").strip()[:160]}')


def check_pr(api: GitHubApi, number: int, mention: str, dry_run: bool, via_label: str | None = None) -> str:
    files = api.get_all(f'pulls/{number}/files?per_page=100')
    if not owner_tap_paths(files):
        sync_tap_label(api, number, api.get(f'pulls/{number}'), False, dry_run)  # it may carry the label from before
        return 'no owner-tap paths'
    pr = api.get(f'pulls/{number}')  # the single-PR read is the one that carries `mergeable`
    head = pr['head']['sha']
    runs = api.get_all(f'commits/{head}/check-runs?filter=latest&per_page=100')
    statuses = api.get_all(f'commits/{head}/statuses?per_page=100')
    comments = api.get_all(f'issues/{number}/comments?per_page=100')
    if pr.get('mergeable') is not None:  # GitHub still working it out: leave the label as it is until the next run
        sync_tap_label(api, number, pr, qualifies(*readiness(pr, files, runs, statuses, comments, api.repo)), dry_run)
    verdict = followup_verdict(pr, comments, api.repo)
    if verdict is not None:  # alerted before the audit, which has landed since (#2052)
        if dry_run:
            return 'audit follow-up due (dry run, nothing posted)'
        if via_label:
            api.readd_label(number, via_label)
            return f'audit follow-up due, `{via_label}` re-added for Actions to post it'
        if api.get(f'pulls/{number}')['head']['sha'] != head:
            return 'head moved during the check'
        if followed_up(api.get_all(f'issues/{number}/comments?per_page=100'), head):
            return f'already followed up on {head[:7]}'
        api.comment(number, followup_body(head, mention, verdict))
        return 'audit follow-up posted'
    ready, why = readiness(pr, files, runs, statuses, comments, api.repo)
    if not ready:
        return why
    if api.get(f'pulls/{number}')['head']['sha'] != head:
        return 'head moved during the check'
    tap = owner_tap_paths(files)
    body = alert_body(pr, tap, mention, head_audit_verdict(comments, head) is not None)
    if dry_run:
        return why + ' (dry run, nothing posted)'
    if via_label:  # the owner's own comment would notify nobody: ask the labeled Actions run to post it
        api.readd_label(number, via_label)
        return why + f', `{via_label}` re-added for Actions to post the alert'
    if alerted(api.get_all(f'issues/{number}/comments?per_page=100'), head):  # another run posted meanwhile
        return f'already alerted on {head[:7]}'
    api.comment(number, body)
    return why + ', alert posted'


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    ap.add_argument('--repo', default=os.environ.get('GH_REPO', ''))
    ap.add_argument('--base', help='the base branch (default: the trunk)')
    ap.add_argument('--mention', help='login to @mention (default: the repository owner)')
    ap.add_argument('--pr', type=int, help='check only this PR')
    ap.add_argument('--dry-run', action='store_true')
    ap.add_argument('--via-label', metavar='LABEL', help='for a ready PR, re-add this label instead of commenting')
    ap.add_argument('--clear-label', metavar='LABEL', help='with --pr: remove this label after the check')
    args = ap.parse_args(argv)
    args.mention = args.mention or OWNER_LOGIN
    if not args.repo or not re.fullmatch(r'[A-Za-z0-9_.-]+', args.mention):
        ap.error('need --repo (or GH_REPO) and a plain --mention login')
    if args.clear_label and not args.pr:
        ap.error('--clear-label needs --pr')
    if args.base is None and not args.pr:  # #1492: the trunk (scripts/trunk.py). A single PR needs no trunk (#2270).
        from trunk import trunk_branch
        args.base = trunk_branch()
    api = GitHubApi(args.repo)
    if args.pr:
        numbers = [args.pr]
    else:
        numbers = [p['number'] for p in api.get_all(f'pulls?state=open&base={args.base}&per_page=100')]
    failures = 0
    for number in numbers:
        try:
            print(f'#{number}: {check_pr(api, number, args.mention, args.dry_run, args.via_label)}')
        except (subprocess.SubprocessError, ValueError, KeyError) as exc:  # this PR waits for the next run
            failures += 1
            detail = (getattr(exc, 'stderr', '') or str(exc)).strip().splitlines()
            print(f'#{number}: skipped, {type(exc).__name__}: {detail[0][:160] if detail else ""}')
    if args.clear_label and not args.dry_run:
        try:  # so the next re-add sends a fresh labeled event
            api.remove_label(args.pr, args.clear_label)
        except subprocess.SubprocessError as exc:
            print(f'#{args.pr}: could not remove `{args.clear_label}`: {(getattr(exc, "stderr", "") or "").strip()[:160]}')
    if not args.pr and not args.dry_run:  # a full sweep also clears the label from PRs that closed or merged
        try:
            for number in api.closed_with_tap_label():
                api.remove_label(number, TAP_LABEL)
                print(f'#{number}: closed, `{TAP_LABEL}` removed')
        except (subprocess.SubprocessError, ValueError, KeyError) as exc:
            print(f'could not clear `{TAP_LABEL}` from closed PRs: {(getattr(exc, "stderr", "") or str(exc)).strip()[:160]}')
    print(f'{len(numbers)} open PRs{f" into {args.base}" if args.base else ""} checked, {failures} skipped on errors')
    return 0


if __name__ == '__main__':
    sys.exit(main())
