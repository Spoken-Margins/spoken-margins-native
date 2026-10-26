"""Hosted CI cost and catch (#2459, #2596): what the hosted checks cost, how long hosted Macs queue, and what they catch.

lane_ledger.py only sees the build Mac's lane. The hosted checks (hosted-portable.yml: portable, SessionKit core,
Mac rest; hosted-app-macos.yml; hosted-integration.yml) run on GitHub, so this reads their runs from the Actions
API in bulk and writes the raw jobs to one JSON file, then summarises that file. Nothing is read into an agent's context.

    python3 scripts/hosted_ci_ledger.py fetch [--days 7] [--out FILE]   # Actions API -> FILE (raw runs and jobs)
    python3 scripts/hosted_ci_ledger.py report FILE [--hours N]         # numbers from FILE (last N hours only)

Per job name: runs, failures, and minutes. For "hosted fast: Mac rest" (the fast-mac-rest plan) a failure is a
catch candidate only when the cheap hosted pair ("portable", "SessionKit core") did not fail in the same run,
since only then did Mac rest alone see the problem. Each such failure is classed by what happened next:

- flake: the same head passed Mac rest later (a rerun or a later attempt);
- fixed: a later head on the same branch passed it;
- unresolved: neither within the window.

Hosted macOS queue wait is started_at minus created_at of each job that ran on a macOS label (xcode-*, macos-*),
with p50, p90, max and count. #2596's plan is wrong if the p90 is above QUEUE_P90_LIMIT_MIN.

Stdlib only; needs the gh CLI for `fetch`.
"""
from __future__ import annotations

import json
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone
from pathlib import Path

REPO = 'Spoken-Margins/spoken-margins-native'
WORKFLOWS = ('hosted-portable.yml', 'hosted-app-macos.yml', 'hosted-integration.yml')
MAC_LABEL_PREFIXES = ('xcode', 'macos')
PAIR = ('hosted fast: portable', 'hosted fast: SessionKit core')
MAC_REST = 'hosted fast: Mac rest'
QUEUE_P90_LIMIT_MIN = 15


def _ts(value):
    return datetime.fromisoformat(value.replace('Z', '+00:00')) if value else None


def is_mac(job: dict) -> bool:
    return any(str(label).lower().startswith(MAC_LABEL_PREFIXES) for label in job.get('labels') or [])


def ran(job: dict) -> bool:
    """A job that really started: skipped jobs have no runner and a zero-length wait."""
    return bool(job.get('runner_name')) and job.get('conclusion') not in ('skipped', None)


def percentile(values: list, pct: float) -> float:
    """Nearest-rank percentile, so the p90 of 10 values is the 9th and is always a value that happened."""
    if not values:
        return 0.0
    ordered = sorted(values)
    rank = max(1, -(-len(ordered) * pct // 100))
    return ordered[int(rank) - 1]


def queue_waits(runs: list) -> list:
    """Seconds from queued to started for each hosted macOS job that ran."""
    waits = []
    for run in runs:
        for job in run.get('jobs', []):
            if is_mac(job) and ran(job) and job.get('created_at') and job.get('started_at'):
                waits.append(max(0.0, (_ts(job['started_at']) - _ts(job['created_at'])).total_seconds()))
    return waits


def _minutes(job: dict) -> float:
    if not (job.get('started_at') and job.get('completed_at')):
        return 0.0
    return max(0.0, (_ts(job['completed_at']) - _ts(job['started_at'])).total_seconds() / 60)


def job_totals(runs: list) -> dict:
    totals: dict = {}
    for run in runs:
        for job in run.get('jobs', []):
            if not ran(job):
                continue
            t = totals.setdefault(job['name'], {'runs': 0, 'fail': 0, 'minutes': 0.0, 'mac': is_mac(job)})
            t['runs'] += 1
            t['fail'] += job.get('conclusion') == 'failure'
            t['minutes'] += _minutes(job)
    return totals


def _job(run: dict, name: str):
    return next((j for j in run.get('jobs', []) if j['name'] == name and ran(j)), None)


def mac_rest_catches(runs: list) -> list:
    """Mac rest failures where the hosted pair did not fail in the same run, each with what happened next."""
    rows = []
    ordered = sorted(runs, key=lambda r: r.get('created_at', ''))
    for i, run in enumerate(ordered):
        job = _job(run, MAC_REST)
        if not job or job.get('conclusion') != 'failure':
            continue
        if any((_job(run, p) or {}).get('conclusion') == 'failure' for p in PAIR):
            continue
        later = [r for r in ordered[i + 1:] if r.get('head_branch') == run.get('head_branch')
                 and (_job(r, MAC_REST) or {}).get('conclusion') == 'success']
        if any(r['head_sha'] == run['head_sha'] for r in later):
            outcome = 'flake'
        elif later:
            outcome = 'fixed'
        else:
            outcome = 'unresolved'
        rows.append({'run': run['id'], 'branch': run.get('head_branch'), 'head': run['head_sha'][:7], 'class': outcome})
    return rows


def report(runs: list) -> str:
    out = []
    totals = job_totals(runs)
    out.append(f'{"job":<44} {"runs":>5} {"fail":>5} {"min total":>9} {"min/run":>8}  where')
    for name, t in sorted(totals.items(), key=lambda kv: -kv[1]['minutes']):
        per = t['minutes'] / t['runs'] if t['runs'] else 0
        out.append(f'{name:<44} {t["runs"]:>5} {t["fail"]:>5} {t["minutes"]:>9.1f} {per:>8.1f}  {"hosted Mac" if t["mac"] else "hosted Linux"}')
    mac_minutes = sum(t['minutes'] for t in totals.values() if t['mac'])
    out.append(f'\nHosted macOS job minutes in window: {mac_minutes:.1f}')
    catches = mac_rest_catches(runs)
    classes = {c: sum(1 for r in catches if r['class'] == c) for c in ('flake', 'fixed', 'unresolved')}
    rest = totals.get(MAC_REST, {'runs': 0, 'fail': 0, 'minutes': 0.0})
    out.append(f'\nfast-mac-rest ({MAC_REST}): {rest["runs"]} runs, {rest["fail"]} failed, '
               f'{rest["minutes"]:.1f} min; failed with the hosted pair not failing: {len(catches)} '
               f'(flake {classes["flake"]}, fixed by a later head {classes["fixed"]}, unresolved {classes["unresolved"]}).')
    for r in catches:
        out.append(f'  run {r["run"]} {r["branch"]} @{r["head"]}: {r["class"]}')
    waits = queue_waits(runs)
    if waits:
        p90 = percentile(waits, 90) / 60
        verdict = 'WRONG (p90 above limit)' if p90 > QUEUE_P90_LIMIT_MIN else 'ok'
        out.append(f'\nHosted macOS queue wait over {len(waits)} jobs: p50 {percentile(waits, 50) / 60:.1f} min, '
                   f'p90 {p90:.1f} min, max {max(waits) / 60:.1f} min. Plan limit p90 <= {QUEUE_P90_LIMIT_MIN} min: {verdict}.')
    else:
        out.append('\nNo hosted macOS jobs in the window.')
    return '\n'.join(out)


def since_hours(runs: list, hours: float, now=None) -> list:
    """Only the runs created in the last `hours` hours, to see whether a fix changed the numbers."""
    cutoff = (now or datetime.now(timezone.utc)) - timedelta(hours=hours)
    return [r for r in runs if _ts(r['created_at']) >= cutoff]


def _api(*args) -> dict:
    return json.loads(subprocess.run(['gh', 'api', *args], capture_output=True, text=True, check=True).stdout)


def _run_jobs(run: dict) -> dict:
    jobs = _api(f'repos/{REPO}/actions/runs/{run["id"]}/jobs?per_page=100&filter=all')
    keep = ('name', 'labels', 'created_at', 'started_at', 'completed_at', 'conclusion', 'runner_name')
    return {'id': run['id'], 'workflow': run['path'].rsplit('/', 1)[-1], 'event': run['event'],
            'head_branch': run['head_branch'], 'head_sha': run['head_sha'], 'run_attempt': run['run_attempt'],
            'created_at': run['created_at'], 'jobs': [{k: j.get(k) for k in keep} for j in jobs.get('jobs', [])]}


def fetch(days: int = 7) -> list:
    since = (datetime.now(timezone.utc) - timedelta(days=days)).strftime('%Y-%m-%dT%H:%M:%SZ')
    runs = []
    for wf in WORKFLOWS:
        for page in range(1, 30):
            data = _api(f'repos/{REPO}/actions/workflows/{wf}/runs?per_page=100&page={page}&created=%3E%3D{since}')
            runs.extend(data.get('workflow_runs', []))
            if len(data.get('workflow_runs', [])) < 100:
                break
    with ThreadPoolExecutor(max_workers=8) as pool:
        return list(pool.map(_run_jobs, runs))


def main(argv=None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    if argv[:1] == ['fetch']:
        days = int(argv[argv.index('--days') + 1]) if '--days' in argv else 7
        out = Path(argv[argv.index('--out') + 1]) if '--out' in argv else Path('hosted-ci-runs.json')
        runs = fetch(days)
        out.write_text(json.dumps(runs))
        print(f'{len(runs)} runs written to {out}')
        return 0
    if argv[:1] == ['report'] and len(argv) in (2, 4):
        runs = json.loads(Path(argv[1]).read_text())
        if len(argv) == 4:
            if argv[2] != '--hours':
                print('usage: hosted_ci_ledger.py report FILE [--hours N]', file=sys.stderr)
                return 2
            runs = since_hours(runs, float(argv[3]))
        print(report(runs))
        return 0
    print('usage: hosted_ci_ledger.py fetch [--days N] [--out FILE] | report FILE [--hours N]', file=sys.stderr)
    return 2


if __name__ == '__main__':
    sys.exit(main())
