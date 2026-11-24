#!/usr/bin/env python3
"""Dispatch backstop (#4866): start the 15-minute workflows from the VPS when GitHub's own schedule drops them.

GitHub runs a `schedule:` late or not at all when it is busy: in the 24 hours to 2026-11-21 `claude-audit` ran 4 of 96
times, `merge-stall` 3 of 96, `merge-queue-label-bridge` 4 of 96, `lane-conflicts` 3 of 24 and `main-t3` 6 of 8. Each of
these now starts on an event where one exists. This timer (every 15 minutes, next to the Dial gate) is the backstop for
the time-based part: for each workflow it asks when the newest run of any kind began and fires `workflow_dispatch` only
when that is older than the workflow's interval. A workflow an event started a few minutes ago is left alone, so this is a
backstop and not a second trigger.

One log line per workflow per tick, to stdout (journald). Exit 1 if any dispatch or lookup failed, so the unit shows red.
Nobody reads journald, so the coordinator's wake sweep (scripts/sm_sweep.py, rule 15) is what notices: it reports any of
these workflows that has gone twice its interval without a run, whatever the reason (#4937).
Stdlib only, Python 3.9+. `--dry-run` asks GitHub but dispatches nothing.

Since #4937: every token found is tried in order when GitHub answers 401 or 403, so a dispatch token that lacks
`actions: write` falls back to the Dial's; a failure logs GitHub's status and message with what the token needs; a run
still queued or running is not dispatched over (it would only queue behind it); a dropped connection is a logged
failure, not a crash that skips the remaining workflows.
"""
from __future__ import annotations

import argparse
import datetime as dt
import http.client
import json
import os
import sys
import urllib.error
import urllib.request
from pathlib import Path

REPO = os.environ.get('SM_DISPATCH_REPO', 'Spoken-Margins/spoken-margins-native')
TRUNK = os.environ.get('SM_TRUNK', 'main')
# Every token found is tried, in this order, when GitHub refuses the one before (401 or 403). It needs `actions: write` on this repository (fine-grained) or `workflow`
# scope (classic). The Dial's token is the fallback so a host that already has one that can dispatch needs nothing new,
# and a dispatch token that turns out to be read-only does not silence the backstop.
TOKEN_FILES = (Path(os.environ.get('SM_DISPATCH_CONFIG', '/etc/sm-dispatch')) / 'github-token',
               Path(os.environ.get('SM_DIAL_CONFIG', '/etc/sm-dial')) / 'github-token')

# workflow file -> the interval it should not go without a run, in minutes. Keep in step with the `schedule:` comments in
# each file; scripts/tests/test_scheduled_workflows.py holds every name here to a real workflow with workflow_dispatch.
WORKFLOWS = {
    'claude-audit.yml': 15,
    'merge-stall.yml': 15,
    'merge-queue-label-bridge.yml': 15,
    'lane-conflicts.yml': 60,
    'main-t3.yml': 180,
    'open-cloud-prs.yml': 20,  # a cloud session's own dispatch is the start (#4915); this catches a failed one
}


# Events whose runs count for a workflow, where not every event does the whole job. The label bridge's `pull_request_target`
# run checks one PR; only a `schedule` or `workflow_dispatch` run sweeps every armed PR, and a PR armed with a token-made
# label (which starts no event) waits for that sweep. Counting the one-PR runs would let a busy queue hold the sweep off.
# A workflow not listed counts every event: its event runs read every PR or armed PR.
COUNTED_EVENTS = {'merge-queue-label-bridge.yml': {'schedule', 'workflow_dispatch'}}


def parse_time(text: str) -> dt.datetime:
    return dt.datetime.strptime(text, '%Y-%m-%dT%H:%M:%SZ').replace(tzinfo=dt.timezone.utc)


def gh(method: str, path: str, token: str, body: dict | None = None):
    req = urllib.request.Request(
        f'https://api.github.com/{path}', method=method,
        data=json.dumps(body).encode() if body is not None else None,
        headers={'Authorization': f'Bearer {token}', 'Accept': 'application/vnd.github+json',
                 'X-GitHub-Api-Version': '2022-11-28', 'User-Agent': 'sm-dispatch-backstop',
                 **({'Content-Type': 'application/json'} if body is not None else {})})
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.loads(resp.read() or b'null')


REFUSED = (401, 403)
TOKEN_HINT = ('the token needs `actions: write` on this repository (fine-grained) or `workflow` scope (classic); '
              'put one in ' + ' or '.join(str(p) for p in TOKEN_FILES))


def call(get, method: str, path: str, tokens, body: dict | None = None):
    """`get` with the first token GitHub accepts. A 401 or 403 moves to the next token; the last refusal is raised."""
    tokens = [tokens] if isinstance(tokens, str) else list(tokens)
    for index, token in enumerate(tokens):
        try:
            return get(method, path, token, body)
        except urllib.error.HTTPError as error:
            if error.code not in REFUSED or index == len(tokens) - 1:
                raise


def describe(error: BaseException) -> str:
    """One log line's worth: GitHub's status and message, and for a refusal what the token needs."""
    if isinstance(error, urllib.error.HTTPError):
        try:
            message = json.loads(error.read() or b'{}').get('message', '')
        except (ValueError, OSError, AttributeError):
            message = ''
        text = f'HTTP {error.code} {message or error.reason}'.strip()
        return f'{text}: {TOKEN_HINT}' if error.code in REFUSED else text
    return f'{type(error).__name__}: {error}'


def newest_run(workflow: str, token, get=gh) -> dict | None:
    """The newest run of any event that did something, or None. A run whose conclusion is `skipped` (every job's `if:`
    was false: a merge group's check, an unarmed PR's push) did no work, so it must not hold the backstop off; on a busy
    day those arrive every few minutes. A queued or running run has no conclusion yet and counts. For a workflow in
    COUNTED_EVENTS only a run of those events counts."""
    return pick(workflow, call(get, 'GET', f'repos/{REPO}/actions/workflows/{workflow}/runs?per_page=30',
                               token)['workflow_runs'])


def pick(workflow: str, runs: list[dict]) -> dict | None:
    """newest_run's choice from a runs list, newest first. scripts/sm_sweep.py (rule 15) uses it too."""
    counted = COUNTED_EVENTS.get(workflow)
    return next((run for run in runs if run.get('conclusion') != 'skipped'
                 and (counted is None or run.get('event') in counted)), None)


# The timer's own jitter (RandomizedDelaySec=60 on each tick) can make a run look a minute or two younger than the
# interval at the next tick; without this margin about half the ticks would skip a workflow that is due, and the real gap
# would double.
SLACK = dt.timedelta(minutes=2)


UNFINISHED = {'queued', 'in_progress', 'waiting', 'pending', 'requested'}


def decide(now: dt.datetime, interval_minutes: int, run: dict | None) -> tuple[bool, str]:
    """(dispatch?, why). A run counts from the moment it was created, whatever its event. A run still queued or running
    is never dispatched over: a second one would wait behind it in the workflow's concurrency group, or cancel it."""
    if run is None:
        return True, 'no worked run yet'
    age = now - parse_time(run['created_at'])
    minutes = int(age.total_seconds() // 60)
    if run.get('status') in UNFINISHED:
        return False, f"last run {minutes}m ago ({run.get('event')}) is still {run['status']}"
    if age < dt.timedelta(minutes=interval_minutes) - SLACK:
        return False, f"last run {minutes}m ago ({run.get('event')}), inside {interval_minutes}m"
    return True, f"last run {minutes}m ago ({run.get('event')}), past {interval_minutes}m"


def tick(token, now: dt.datetime, out=sys.stdout, dry_run: bool = False, get=gh, workflows=None) -> int:
    """Look at each workflow once and dispatch the ones that are overdue. Returns how many lookups or dispatches failed.
    `token` is one token or a list tried in order (see `call`)."""
    failures = 0
    stamp = now.strftime('%Y-%m-%dT%H:%M:%SZ')
    for workflow, interval in (workflows or WORKFLOWS).items():
        try:
            go, why = decide(now, interval, newest_run(workflow, token, get))
            if not go:
                print(f'{stamp} {workflow} skipped: {why}', file=out)
            elif dry_run:
                print(f'{stamp} {workflow} would dispatch: {why}', file=out)
            else:
                call(get, 'POST', f'repos/{REPO}/actions/workflows/{workflow}/dispatches', token, {'ref': TRUNK})
                print(f'{stamp} {workflow} dispatched: {why}', file=out)
        except (urllib.error.URLError, http.client.HTTPException, OSError, ValueError, KeyError, TypeError) as error:
            failures += 1
            print(f'{stamp} {workflow} FAILED: {describe(error)}', file=out)
    return failures


def read_tokens() -> list[str]:
    """Every distinct token: the environment's, then each file's, in order."""
    found = [os.environ.get('SM_DISPATCH_GITHUB_TOKEN', '').strip()]
    for path in TOKEN_FILES:
        try:
            found.append(path.read_text().strip())
        except OSError:
            continue
    tokens = list(dict.fromkeys(t for t in found if t))
    if not tokens:
        raise SystemExit('no GitHub token: put one in ' + ' or '.join(str(p) for p in TOKEN_FILES))
    return tokens


def main(argv=None, now: dt.datetime | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('--dry-run', action='store_true', help='look up each workflow, dispatch nothing')
    args = parser.parse_args(argv)
    now = now or dt.datetime.now(dt.timezone.utc)
    return 1 if tick(read_tokens(), now, dry_run=args.dry_run) else 0


if __name__ == '__main__':
    sys.exit(main())
