#!/usr/bin/env python3
"""Lane open ping (#1215): tell the coordinator when a Mac lane runner has nothing to do.

The coordinator acts only when something wakes it. When a lane or automerge job ends and a lane
runner is left idle with no queued Mac job waiting for it, `lane-open` (the last job in
.github/workflows/lane.yml) runs this. It POSTs `Lane open-<UTC time>: <free> free, <queued> queued`
to the "Dial relay" routine's /fire endpoint, which posts the text into the project chat, the same
way the Dial gate (#589, ops/dial/dial_gate.py) wakes it. The coordinator then fills the slot from
PRs that can use a lane and clears "waiting on you" and idle threads.

Rules, all of them failing toward quiet:
- Free means an online runner labelled sm-lane, sm-lane-build or sm-lane-priority that is not busy.
  It says a runner is idle, not that RAM, disk or the Mac's one simulator slot are free.
- It pings only when an idle runner has no waiting Mac job that could take it (a queued job is
  about to). Waiting Mac jobs are any jobs of any workflow's runs that are queued for a runner and ask
  for a lane label (so lane.yml's `lane` and `automerge` and shipped-build-compat's `compat` all count);
  each is matched to one idle runner that has all of its labels.
- At most one ping per 10 minutes (state file), so a burst of finishes is one message.
- No relay URL or token (`SM_LANE_OPEN_URL`, `SM_LANE_OPEN_TOKEN`), an unreadable runner list or
  queue, or a failed POST sends nothing and exits 0: this must never turn a lane run red.

Stdlib only, Python 3.9+. `--dry-run` prints the decision and neither sends nor writes.
Environment: GH_REPO, GH_TOKEN (runs and jobs), RUNNERS_TOKEN (runner list; falls back to GH_TOKEN),
SM_LANE_OPEN_STATE.
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

DEFAULT_REPO = 'Spoken-Margins/spoken-margins-native'
LANE_LABELS = ('sm-lane', 'sm-lane-build', 'sm-lane-priority')
WAITING = ('queued',)     # `pending` waits on its PR's concurrency group, not on a runner
ACTIVE_RUNS = ('queued', 'in_progress', 'pending', 'waiting')
MIN_GAP = dt.timedelta(minutes=10)
SETTLE_TRIES = 3          # the runner that just finished can read busy for a second or two
SETTLE_SECONDS = 5
PAGE = 100


class Unreadable(Exception):
    """A fact the decision needs couldn't be read; the ping is skipped."""


def idle_runners(runners: list[dict]) -> list[set[str]]:
    """The label sets of online lane runners that are not busy."""
    return [{label['name'].lower() for label in r.get('labels', [])} for r in runners
            if r.get('status') == 'online' and not r.get('busy')
            and any(label.get('name') in LANE_LABELS for label in r.get('labels', []))]


def waiting_jobs(jobs: list[dict]) -> list[set[str]]:
    """The label sets of jobs queued for a lane runner, whichever workflow they belong to."""
    labelled = [{str(label).lower() for label in job.get('labels', [])} for job in jobs
                if job.get('status') in WAITING]
    return [labels for labels in labelled if labels & set(LANE_LABELS)]


def spare_runners(idle: list[set[str]], waiting: list[set[str]]) -> int:
    """Idle runners left once each waiting job has taken one that has all of its labels."""
    free = list(idle)
    for labels in sorted(waiting, key=lambda l: (len(l), sorted(l))):
        for index, runner in enumerate(free):
            if labels <= runner:
                del free[index]
                break
    return len(free)


def decide(spare: int, free: int, queued: int, now: dt.datetime, last: dt.datetime | None,
           gap: dt.timedelta = MIN_GAP) -> tuple[bool, str]:
    """(send, why). Sends when an idle runner has no waiting job to take it, at most once per gap."""
    if spare < 1:
        return False, f'{free} runner(s) idle, {queued} Mac job(s) waiting: they take the slots'
    if last is not None and now - last < gap:
        return False, (f'last ping was {int((now - last).total_seconds() // 60)} min ago '
                       f'(limit {int(gap.total_seconds() // 60)})')
    return True, f'{free} idle, {queued} waiting'


def ping_text(now: dt.datetime, free: int, queued: int) -> str:
    return f'Lane open-{now.strftime("%Y%m%dT%H%MZ")}: {free} free, {queued} queued'


def parse_time(stamp: str) -> dt.datetime:
    return dt.datetime.strptime(stamp, '%Y-%m-%dT%H:%M:%SZ').replace(tzinfo=dt.timezone.utc)


class GitHub:
    def __init__(self, repo: str, token: str, runners_token: str | None = None):
        # The runner list needs more than the workflow token (admin read); runs and jobs need only actions: read.
        self.repo, self.token, self.runners_token = repo, token, runners_token or token

    def get(self, path: str):
        token = self.runners_token if path.startswith('actions/runners') else self.token
        req = urllib.request.Request(
            f'https://api.github.com/repos/{self.repo}/{path}',
            headers={'Authorization': f'Bearer {token}', 'Accept': 'application/vnd.github+json',
                     'X-GitHub-Api-Version': '2022-11-28', 'User-Agent': 'sm-lane-open'})
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                return json.loads(resp.read())
        except (urllib.error.URLError, OSError, ValueError) as error:
            raise Unreadable(f'{path}: {error}') from error


def read_runners(api) -> list[dict]:
    page = api.get(f'actions/runners?per_page={PAGE}')
    if page.get('total_count', 0) > len(page.get('runners', [])):
        raise Unreadable('more than one page of runners')
    return page['runners']


def read_waiting(api) -> list[set[str]]:
    """Jobs waiting for a lane runner, across the repository's runs that are not finished."""
    run_ids = set()
    for status in ACTIVE_RUNS:
        page = api.get(f'actions/runs?status={status}&per_page={PAGE}')
        if page.get('total_count', 0) > len(page.get('workflow_runs', [])):
            raise Unreadable(f'more than one page of {status} runs')
        run_ids.update(run['id'] for run in page.get('workflow_runs', []))
    waiting: list[set[str]] = []
    for run_id in sorted(run_ids):
        jobs = api.get(f'actions/runs/{run_id}/jobs?per_page={PAGE}')
        if jobs.get('total_count', 0) > len(jobs.get('jobs', [])):
            raise Unreadable(f'more than one page of jobs in run {run_id}')
        waiting += waiting_jobs(jobs.get('jobs', []))
    return waiting


def read_idle(api, sleep=time.sleep) -> tuple[int, int, int]:
    """(spare, free, queued), re-reading a few times while no runner looks spare, because the runner of
    the job that just ended can still read busy for a moment."""
    spare = free = queued = 0
    for attempt in range(SETTLE_TRIES):
        idle, waiting = idle_runners(read_runners(api)), read_waiting(api)
        spare, free, queued = spare_runners(idle, waiting), len(idle), len(waiting)
        if spare >= 1:
            break
        if attempt + 1 < SETTLE_TRIES:
            sleep(SETTLE_SECONDS)
    return spare, free, queued


def fire_relay(url: str, token: str, text: str) -> None:
    req = urllib.request.Request(
        url, method='POST', data=json.dumps({'text': text}).encode(),
        headers={'Authorization': f'Bearer {token}', 'Content-Type': 'application/json',
                 'anthropic-beta': 'experimental-cc-routine-2026-04-01',
                 'anthropic-version': '2023-06-01', 'User-Agent': 'sm-lane-open'})
    with urllib.request.urlopen(req, timeout=30) as resp:
        resp.read()


def load_last(path: Path) -> dt.datetime | None:
    try:
        return parse_time(json.loads(path.read_text())['last_ping_at'])
    except (OSError, ValueError, KeyError, TypeError):
        return None


def save_last(path: Path, now: dt.datetime) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix('.tmp')
    tmp.write_text(json.dumps({'last_ping_at': now.strftime('%Y-%m-%dT%H:%M:%SZ')}))
    tmp.replace(path)


def summary(line: str) -> None:
    print(line)
    target = os.environ.get('GITHUB_STEP_SUMMARY')
    if target:
        try:
            with open(target, 'a') as handle:
                handle.write(line + '\n')
        except OSError:
            pass


def run(api, now: dt.datetime, state: Path, url: str, token: str, dry_run=False,
        send=fire_relay, sleep=time.sleep) -> str:
    """One check. Returns the one line it reports; never raises for a skipped ping."""
    if not (url and token):
        return 'lane-open: no relay set up (SM_LANE_OPEN_URL / SM_LANE_OPEN_TOKEN); nothing sent.'
    try:
        spare, free, queued = read_idle(api, sleep)
    except Unreadable as error:
        return f'lane-open: could not read the lane ({error}); nothing sent.'
    ok, why = decide(spare, free, queued, now, load_last(state))
    if not ok:
        return f'lane-open: not sent, {why}.'
    text = ping_text(now, free, queued)
    if dry_run:
        return f'lane-open: dry run, would send "{text}".'
    try:
        send(url, token, text)
    except (urllib.error.URLError, OSError, ValueError) as error:
        return f'lane-open: the relay failed ({error}); nothing sent.'
    try:
        save_last(state, now)
    except OSError as error:
        return f'lane-open: sent "{text}", but could not record it ({error}); the 10-minute limit may not hold.'
    return f'lane-open: sent "{text}".'


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument('--dry-run', action='store_true', help='print the decision; send and write nothing')
    args = ap.parse_args(argv)
    token = os.environ.get('GH_TOKEN') or os.environ.get('RUNNERS_TOKEN') or ''
    repo = os.environ.get('GH_REPO', DEFAULT_REPO)
    try:
        state = Path(os.environ.get('SM_LANE_OPEN_STATE') or Path.home() / '.sm-lane-open' / 'state.json')
        line = run(GitHub(repo, token, os.environ.get('RUNNERS_TOKEN')), dt.datetime.now(dt.timezone.utc), state,
                   os.environ.get('SM_LANE_OPEN_URL', ''), os.environ.get('SM_LANE_OPEN_TOKEN', ''),
                   dry_run=args.dry_run)
    except Exception as error:  # noqa: BLE001 - a ping must never turn a lane run red
        line = f'lane-open: stopped ({error!r}); nothing sent.'
    summary(line)
    return 0


if __name__ == '__main__':
    sys.exit(main())
