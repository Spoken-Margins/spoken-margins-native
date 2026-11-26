#!/usr/bin/env python3
"""Tell the owner's phone when a deploy waits for his environment approval (#5255).

A deploy gated by GitHub environment protection sits in status `waiting` until the owner approves it, and GitHub
sends him nothing he sees. On 2026-11-23 deploy-web run 45214454131 waited from 16:15Z all day. deploy-web.yml's
concurrency group has `cancel-in-progress: false`, so every newer deploy queued as `pending` behind it and was
cancelled when a still newer one arrived (runs 45251344745, 45273031128, 45322626191). He learned of it when asked.

Run from owner-tap-alert.yml's half-hourly schedule as `github-actions[bot]` (its comments notify him; his own would
not, and the GitHub mobile app pushes @mentions). Each run:

1. lists runs in status `waiting` and keeps those with pending deployments (`.../runs/N/pending_deployments`),
   noting the environment names. `current_user_can_approve` is not read: a bot token cannot answer it;
2. keeps one standing issue titled "Deploys waiting for you" (exact title, authored by github-actions[bot], open or
   closed). For each waiting run no comment mentions yet (`<!-- deploy-wait-alert: <run id> -->`) it reopens the issue
   when closed and posts one comment: workflow, environment, commit, how long it has waited, the run link and what
   to do;
3. when a newer run of the same workflow is `pending`, `queued` or was recently `cancelled` behind a waiting one,
   one follow-up per waiting run (`<!-- deploy-wait-stale: <run id> -->`) says the old run blocks the newer one:
   reject the old, approve the newer. The follow-up exists because the newer runs usually arrive after the first alert;
4. when nothing waits it closes the issue, with a short comment only if it was open.

It never approves, rejects or cancels anything: read-only on Actions, writes only issues and comments. Only comments
from github-actions[bot] count as markers. Any API error ends the run non-zero; the next half hour tries again.

  python3 scripts/deploy_wait_alert.py [--mention LOGIN] [--dry-run]

GH_TOKEN and GH_REPO come from the environment. Stdlib only.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from datetime import datetime, timedelta, timezone

OWNER_LOGIN = 'uncomposed'  # the same owner owner_tap_alert.py mentions
BOT = 'github-actions[bot]'
ISSUE_TITLE = 'Deploys waiting for you'
ISSUE_BODY = ('Deploys waiting for your approval, one comment per run. Opened and closed by '
              'scripts/deploy_wait_alert.py (#5255). Nothing here approves or rejects a deploy.')
ALERT_MARKER = '<!-- deploy-wait-alert: {id} -->'
ALERT_RE = re.compile(r'<!-- deploy-wait-alert: (\d+) -->')
STALE_MARKER = '<!-- deploy-wait-stale: {id} -->'
STALE_RE = re.compile(r'<!-- deploy-wait-stale: (\d+) -->')
RECENT_CANCEL = timedelta(hours=24)  # a cancelled newer run counts as blocked only when it ended this recently
BLOCKED_STATUSES = {'pending', 'queued'}


def parse_time(text: str) -> datetime:
    return datetime.fromisoformat(text.replace('Z', '+00:00'))


def waited(created_at: str, now: datetime) -> str:
    minutes = max(0, int((now - parse_time(created_at)).total_seconds() // 60))
    hours, mins = divmod(minutes, 60)
    return f'{hours} h {mins} min' if hours else f'{mins} min'


def blocked_runs(waiting: dict, siblings: list[dict], now: datetime) -> list[dict]:
    """Newer runs of the waiting run's workflow that its approval is holding up (or that were cancelled for it)."""
    out = []
    for run in siblings:
        if run['id'] == waiting['id'] or run.get('workflow_id') != waiting.get('workflow_id'):
            continue
        if run['created_at'] <= waiting['created_at']:
            continue
        if run.get('status') in BLOCKED_STATUSES:
            out.append(run)
        elif run.get('conclusion') == 'cancelled' and \
                now - parse_time(run.get('updated_at') or run['created_at']) <= RECENT_CANCEL:
            out.append(run)
    return sorted(out, key=lambda r: r['created_at'])


def alert_body(mention: str, run: dict, envs: list[str], now: datetime) -> str:
    return (f"{ALERT_MARKER.format(id=run['id'])}\n"
            f"@{mention} a deploy is waiting for your approval.\n\n"
            f"- Workflow: {run.get('name')}\n"
            f"- Environment: {', '.join(envs)}\n"
            f"- Commit: `{run['head_sha'][:7]}`\n"
            f"- Waiting: {waited(run['created_at'], now)}\n"
            f"- Run: {run['html_url']}\n\n"
            "To do: open the run, tap Review deployments, then Approve (or Reject).")


def stale_body(mention: str, run: dict, newer: list[dict]) -> str:
    latest = newer[-1]
    return (f"{STALE_MARKER.format(id=run['id'])}\n"
            f"@{mention} the old deploy is blocking a newer one.\n\n"
            f"Run {run['id']} is still waiting, so {len(newer)} newer run(s) of {run.get('name')} queued behind it "
            f"or were cancelled. To do: Reject the old run ({run['html_url']}), then Approve the newer one "
            f"({latest['html_url']}) once it shows Review deployments.")


class Gh:
    """`gh api` through an injectable runner (args list -> stdout), so tests need no network."""

    def __init__(self, repo: str, runner=None):
        self.repo = repo
        self.runner = runner or self._real

    @staticmethod
    def _real(args: list[str]) -> str:
        return subprocess.run(['gh', 'api', *args], text=True, timeout=60, capture_output=True, check=True).stdout

    def get(self, path: str):
        return json.loads(self.runner([f'repos/{self.repo}/{path}']))

    def get_all(self, path: str) -> list:
        pages = json.loads(self.runner(['--paginate', '--slurp', f'repos/{self.repo}/{path}']))
        out = []
        for page in pages:
            if isinstance(page, dict) and 'workflow_runs' in page:
                out.extend(page['workflow_runs'])
            elif isinstance(page, list):
                out.extend(page)
            else:
                out.append(page)
        return out

    def write(self, method: str, path: str, **fields) -> dict:
        args = ['-X', method, f'repos/{self.repo}/{path}']
        for key, value in fields.items():
            args += ['-f', f'{key}={value}']
        return json.loads(self.runner(args) or '{}')


def waiting_runs(api: Gh) -> list[tuple[dict, list[str]]]:
    out = []
    for run in api.get_all('actions/runs?status=waiting&per_page=100'):
        pending = api.get(f"actions/runs/{run['id']}/pending_deployments")
        envs = [d['environment']['name'] for d in pending if (d.get('environment') or {}).get('name')]
        if envs:
            out.append((run, envs))
    return out


def find_issue(api: Gh) -> dict | None:
    found = api.get_all('issues?state=all&creator=github-actions%5Bbot%5D&per_page=100')
    mine = [i for i in found if i.get('title') == ISSUE_TITLE and (i.get('user') or {}).get('login') == BOT
            and 'pull_request' not in i]
    return min(mine, key=lambda i: i['number']) if mine else None


def run_once(api: Gh, mention: str, now: datetime, dry_run: bool = False) -> list[str]:
    log = []

    def post(number, body):
        log.append(f'comment: {body.partition(chr(10))[0]}')
        if not dry_run:
            api.write('POST', f'issues/{number}/comments', body=body)

    waiting = waiting_runs(api)
    issue = find_issue(api)
    if not waiting:
        if issue and issue['state'] == 'open':
            post(issue['number'], 'No deploy is waiting for approval any more. Closing until the next one.')
            log.append('close issue')
            if not dry_run:
                api.write('PATCH', f"issues/{issue['number']}", state='closed')
        else:
            log.append('nothing waiting')
        return log
    if issue is None:
        log.append('create issue')
        if dry_run:
            return log
        issue = api.write('POST', 'issues', title=ISSUE_TITLE, body=ISSUE_BODY)
        issue['state'] = 'open'
        comments = []
    else:
        comments = [c for c in api.get_all(f"issues/{issue['number']}/comments?per_page=100")
                    if (c.get('user') or {}).get('login') == BOT]
    text = '\n'.join(c.get('body') or '' for c in comments)
    alerted, staled = set(ALERT_RE.findall(text)), set(STALE_RE.findall(text))
    is_open = issue['state'] == 'open'
    for run, envs in waiting:
        rid = str(run['id'])
        newer = blocked_runs(run, api.get_all(f"actions/workflows/{run['workflow_id']}/runs?per_page=30"), now)
        todo = []
        if rid not in alerted:
            todo.append(alert_body(mention, run, envs, now))
        if newer and rid not in staled:
            todo.append(stale_body(mention, run, newer))
        if todo and not is_open:
            log.append('reopen issue')
            if not dry_run:
                api.write('PATCH', f"issues/{issue['number']}", state='open')
            is_open = True
        for body in todo:
            post(issue['number'], body)
    if not any(line.startswith('comment') for line in log):
        log.append('all waiting runs already alerted')
    return log


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    ap.add_argument('--repo', default=os.environ.get('GH_REPO', ''))
    ap.add_argument('--mention', default=OWNER_LOGIN)
    ap.add_argument('--dry-run', action='store_true')
    args = ap.parse_args(argv)
    if not args.repo or not re.fullmatch(r'[A-Za-z0-9_.-]+', args.mention):
        ap.error('need --repo (or GH_REPO) and a plain --mention login')
    try:
        for line in run_once(Gh(args.repo), args.mention, datetime.now(timezone.utc), args.dry_run):
            print(line)
    except (subprocess.SubprocessError, ValueError, KeyError) as exc:
        detail = (getattr(exc, 'stderr', '') or str(exc)).strip().splitlines()
        print(f'deploy-wait-alert: {type(exc).__name__}: {detail[0][:200] if detail else ""}')
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
