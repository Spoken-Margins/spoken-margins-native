#!/usr/bin/env python3
"""Self-hosted runner queue (#2271): how long lane jobs waited for a Mac runner, per runner label, and what one more
runner carrying that label would have saved.

GitHub gives a self-hosted job to any idle runner carrying every label in its `runs-on`, and none of the others. So a
label only one runner carries makes its jobs run single file, however idle the other runners are. On 2026-10-21 the
merge runs queued behind `sm-lane-mac-2`, the only `sm-lane-build` runner, while both other Mac runners sat idle.
lane_ledger.py sees steps, not runner queues, and hosted_ci_ledger.py sees hosted runners only, so this reads
lane.yml's jobs from the Actions API in bulk, writes them to one JSON file with a snapshot of the runners, and
summarises that file. Nothing is read into an agent's context.

    python3 scripts/runner_queue.py fetch [--days 7] [--out FILE]   # Actions API -> FILE (runners and jobs)
    python3 scripts/runner_queue.py report FILE                     # numbers from FILE

Queue wait is started_at minus created_at of each self-hosted job that ran. The "modelled" columns replay the jobs,
first come first served, on as many runners as carry the label now, then on one more: the first should land near the
real total (a check on the model), the second is what another runner would save. Both use today's runners for the
whole window, so a label change inside the window blurs them. A label is flagged single file when its p90 wait is at
least SINGLE_FILE_P90_MIN while an online Mac runner ran none of the window's jobs: a coarse flag, judged over the
window, not minute by minute.

Run by hand; no recurring cost. Stdlib only; needs the gh CLI for `fetch`.
"""
from __future__ import annotations

import heapq
import json
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone
from pathlib import Path

REPO = 'Spoken-Margins/spoken-margins-native'
WORKFLOW = 'lane.yml'
SINGLE_FILE_P90_MIN = 15


def _ts(value: str) -> datetime:
    return datetime.fromisoformat(value.replace('Z', '+00:00'))


def _minutes(start: str, end: str) -> float:
    return max(0.0, (_ts(end) - _ts(start)).total_seconds() / 60)


def asked_for(job: dict) -> str:
    """The runner labels a job asked for beyond self-hosted, OS and architecture, e.g. `sm-lane-build`."""
    return ','.join(sorted(label for label in job.get('labels') or []
                           if label not in ('self-hosted', 'macOS', 'Linux', 'ARM64', 'X64')))


def self_hosted_jobs(jobs: list) -> list:
    """Jobs that ran on a self-hosted runner: asked for `self-hosted`, were picked up by a runner, and have a start
    and an end. A run cancelled while it queued can carry both times without ever reaching a runner."""
    return [j for j in jobs if 'self-hosted' in (j.get('labels') or []) and j.get('conclusion') != 'skipped'
            and j.get('runner_name') and j.get('created_at') and j.get('started_at') and j.get('completed_at')]


def percentile(values: list, pct: float) -> float:
    """Nearest-rank percentile, as hosted_ci_ledger.py's: the p90 of 10 values is the 9th."""
    if not values:
        return 0.0
    ordered = sorted(values)
    return ordered[int(max(1, -(-len(ordered) * pct // 100))) - 1]


def modelled_queue(jobs: list, runners: int) -> tuple[float, float]:
    """(total, longest) queue minutes when `jobs` run first come first served on `runners` runners, each job taking
    as long as it really ran."""
    free = [0.0] * runners
    total = longest = 0.0
    timed = sorted((_ts(j['created_at']).timestamp() / 60, _minutes(j['started_at'], j['completed_at'])) for j in jobs)
    for created, took in timed:
        start = max(heapq.heappop(free), created)
        total, longest = total + start - created, max(longest, start - created)
        heapq.heappush(free, start + took)
    return total, longest


def mac_runners(runners: list) -> list:
    return [r for r in runners if 'macOS' in r.get('labels', [])]


def carriers(runners: list, label: str) -> list:
    """Online runners carrying every label in `label` (comma-joined)."""
    wanted = set(filter(None, label.split(',')))
    return [r for r in runners if r.get('status') == 'online' and wanted <= set(r.get('labels', []))]


def summarise(data: dict) -> dict:
    """Per label asked for: jobs, queue and run minutes, the modelled queue now and with one more runner; per Mac
    runner: jobs and busy minutes; and the labels that ran single file beside an idle Mac runner."""
    jobs = self_hosted_jobs(data.get('jobs', []))
    runners = data.get('runners', [])
    by_runner = {r['name']: {'jobs': 0, 'busy': 0.0} for r in mac_runners(runners)}
    for j in jobs:
        if j.get('runner_name') in by_runner:
            by_runner[j['runner_name']]['jobs'] += 1
            by_runner[j['runner_name']]['busy'] += _minutes(j['started_at'], j['completed_at'])
    idle = sorted(name for name, seen in by_runner.items()
                  if not seen['jobs'] and any(r['name'] == name and r.get('status') == 'online' for r in runners))
    labels = {}
    for label in sorted({asked_for(j) for j in jobs}):
        group = [j for j in jobs if asked_for(j) == label]
        waits = [_minutes(j['created_at'], j['started_at']) for j in group]
        count = max(1, len(carriers(runners, label)))
        labels[label] = {
            'jobs': len(group), 'runners': count, 'queue_total': sum(waits), 'queue_p90': percentile(waits, 90),
            'queue_max': max(waits), 'run_total': sum(_minutes(j['started_at'], j['completed_at']) for j in group),
            'modelled_now': modelled_queue(group, count), 'modelled_one_more': modelled_queue(group, count + 1)}
    single_file = [label for label, s in labels.items() if s['queue_p90'] >= SINGLE_FILE_P90_MIN and idle]
    return {'labels': labels, 'runners': by_runner, 'idle': idle, 'single_file': single_file}


def report(data: dict) -> str:
    s = summarise(data)
    out = [f'Self-hosted lane jobs, {data.get("since", "?")} to {data.get("until", "?")} (runners as of '
           f'{data.get("until", "?")})', '',
           '| asked for | jobs | runners | queue total | p90 | max | run total | modelled now | with one more |',
           '|---|---|---|---|---|---|---|---|---|']
    for label, x in s['labels'].items():
        now, more = x['modelled_now'], x['modelled_one_more']
        out.append(f'| {label or "(none)"} | {x["jobs"]} | {x["runners"]} | {x["queue_total"]:.0f}m | '
                   f'{x["queue_p90"]:.0f}m | {x["queue_max"]:.0f}m | {x["run_total"]:.0f}m | '
                   f'{now[0]:.0f}m (max {now[1]:.0f}m) | {more[0]:.0f}m (max {more[1]:.0f}m) |')
    out += ['', '| Mac runner | jobs | busy |', '|---|---|---|']
    out += [f'| {name} | {x["jobs"]} | {x["busy"]:.0f}m |' for name, x in sorted(s['runners'].items())]
    out.append('')
    for label in s['single_file']:
        out.append(f'Single file: `{label}` jobs waited (p90 {s["labels"][label]["queue_p90"]:.0f}m) while '
                   f'{", ".join(s["idle"])} ran no job.')
    if not s['single_file']:
        out.append('No label ran single file beside an idle Mac runner.')
    return '\n'.join(out)


def _api(*args) -> dict:
    return json.loads(subprocess.run(['gh', 'api', *args], capture_output=True, text=True, check=True).stdout)


def _run_jobs(run: dict) -> list:
    keep = ('name', 'labels', 'created_at', 'started_at', 'completed_at', 'conclusion', 'runner_name', 'run_id')
    jobs = []
    for page in range(1, 30):
        data = _api(f'repos/{REPO}/actions/runs/{run["id"]}/jobs?per_page=100&filter=all&page={page}')
        jobs.extend({k: j.get(k) for k in keep} for j in data.get('jobs', []))
        if len(data.get('jobs', [])) < 100:
            break
    return jobs


def fetch(days: int = 7, now=None) -> dict:
    now = now or datetime.now(timezone.utc)
    since = (now - timedelta(days=days)).strftime('%Y-%m-%dT%H:%M:%SZ')
    runs, total = [], 0
    for page in range(1, 30):
        data = _api(f'repos/{REPO}/actions/workflows/{WORKFLOW}/runs?per_page=100&page={page}&created=%3E%3D{since}')
        runs.extend(data.get('workflow_runs', []))
        total = max(total, data.get('total_count', 0))
        if len(data.get('workflow_runs', [])) < 100:
            break
    if len(runs) < total:  # GitHub stops a filtered run query at 1,000 results
        raise RuntimeError(f'{WORKFLOW}: got {len(runs)} of {total} runs; use a shorter --days')
    runners = [{'name': r['name'], 'status': r['status'], 'labels': [label['name'] for label in r['labels']]}
               for r in _api(f'repos/{REPO}/actions/runners?per_page=100').get('runners', [])]
    with ThreadPoolExecutor(max_workers=8) as pool:
        jobs = [j for found in pool.map(_run_jobs, runs) for j in found]
    return {'since': since, 'until': now.strftime('%Y-%m-%dT%H:%M:%SZ'), 'runners': runners,
            'jobs': self_hosted_jobs(jobs)}


def main(argv=None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    if argv[:1] == ['fetch']:
        days = int(argv[argv.index('--days') + 1]) if '--days' in argv else 7
        out = Path(argv[argv.index('--out') + 1]) if '--out' in argv else Path('runner-queue.json')
        data = fetch(days)
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(json.dumps(data))
        print(f'{len(data["jobs"])} self-hosted jobs and {len(data["runners"])} runners written to {out}')
        return 0
    if argv[:1] == ['report'] and len(argv) == 2:
        print(report(json.loads(Path(argv[1]).read_text())))
        return 0
    print('usage: runner_queue.py fetch [--days N] [--out FILE] | report FILE', file=sys.stderr)
    return 2


if __name__ == '__main__':
    sys.exit(main())
