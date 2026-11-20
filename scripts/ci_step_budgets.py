#!/usr/bin/env python3
"""Step time limits from measured durations, and a drift alarm (2026-11-20).

On 2026-11-20 the runner-tests ceiling, set by hand, was raised three times (600, 1200, 1800 s) while the step drifted
toward each new limit, and every time it got close some PRs went red with no failing test. This script replaces the
hand-set numbers with numbers from the runs themselves.

    python3 scripts/ci_step_budgets.py collect [--days 28]   # Actions runs -> artifacts/ci-step-durations/samples.json
    python3 scripts/ci_step_budgets.py table                 # samples -> scripts/ci_step_budgets.json (checked in)
    python3 scripts/ci_step_budgets.py drift [--issue]       # samples + table -> drift report (and the issue)
    python3 scripts/ci_step_budgets.py profile               # samples -> per-job and per-step timings, for planning

`collect` reads the successful runs of hosted-portable.yml (merge groups, pushes, dispatches and PRs: a passed step is
a passed step whichever event ran it) through `gh`. For each successful job it keeps the job's own time, each workflow
step's time, and each verify-tests.py step line (`runner-tests: 1180.376s — passed`) from the job's log. The logs are
cached under artifacts/ci-step-durations/logs/ and never printed.

The rule (`table`): a limit is LIMIT_FACTOR x the p95 of the last WINDOW passing samples of its steps, rounded up to a
whole minute, never below its FLOOR_SECONDS. Percentiles, not mean plus standard deviations: step durations are
right-skewed (a busy runner is slow, never fast), and one slow run widens a standard deviation far more than it moves
a p95. With fewer than MIN_SAMPLES samples the limit is not derived and the table keeps its previous value.

The alarm (`drift`): a step drifts when its p50 over the last DRIFT_RECENT_DAYS is more than DRIFT_P50_RISE above its p50
DRIFT_BASELINE_DAYS earlier, or its p95 is above DRIFT_P95_SHARE of its limit (a checked-in limit, or a job's
timeout-minutes). It changes no limit: a person or agent runs `collect` and `table` and opens a PR with the new numbers.

Stdlib only.
"""
from __future__ import annotations

import argparse
import json
import math
import os
import re
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
WORKFLOW = 'hosted-portable.yml'
OUT = ROOT / 'artifacts' / 'ci-step-durations'
TABLE = ROOT / 'scripts' / 'ci_step_budgets.json'
DRIFT_ISSUE_TITLE = 'CI step drift'

WINDOW = 30
MIN_SAMPLES = 10
LIMIT_FACTOR = 1.5
DRIFT_P50_RISE = 0.25
DRIFT_P95_SHARE = 0.75
DRIFT_RECENT_DAYS = 7
DRIFT_BASELINE_DAYS = 14  # the baseline is the week that ended this many days ago
DRIFT_MIN_SAMPLES = 5

# Each hand-set limit in verify-tests.py, the plan steps whose durations it bounds, and its floor. A ceiling is how
# long a step that has used up its budget (verify-tests.py's *_TIMEOUT) may go on while it is still printing results.
# The floor is that budget and half again: the samples are hosted runners only, and the same plan runs on developers'
# Macs, where #1767 measured the SessionKit tests two to three times slower under load.
LIMITS = {
    'RUNNER_TESTS_CEILING': {'steps': ['runner-tests'], 'floor': 900},  # RUNNER_TESTS_TIMEOUT 600
    'PARALLEL_CORE_CEILING': {'steps': ['package-core'], 'floor': 450},  # PARALLEL_CORE_TIMEOUT 300
    'PACKAGE_TEST_CEILING': {'steps': ['package', 'package-core-serial'], 'floor': 900},  # PACKAGE_TEST_TIMEOUT 600
}

STEP_LINE = re.compile(r'^(?:\S+Z )?([a-z][a-z0-9-]*): ([0-9]+(?:\.[0-9]+)?)s — passed\s*$')


def repo():
    return os.environ.get('GITHUB_REPOSITORY') or 'Spoken-Margins/spoken-margins-native'


def gh_json(path):
    out = subprocess.run(['gh', 'api', '--paginate', '--slurp', path], capture_output=True, text=True, check=True).stdout
    return json.loads(out)


def parse_time(text):
    return datetime.fromisoformat(text.replace('Z', '+00:00')) if text else None


def seconds_between(start, end):
    a, b = parse_time(start), parse_time(end)
    return round((b - a).total_seconds(), 1) if a and b else None


def plan_steps(log_text):
    """Each verify-tests.py step line that passed, in order: [(step, seconds)]."""
    found = []
    for line in log_text.splitlines():
        match = STEP_LINE.match(line.strip())
        if match:
            found.append((match.group(1), float(match.group(2))))
    return found


def job_log(job_id, cache):
    path = cache / f'{job_id}.txt'
    if not path.exists():
        result = subprocess.run(['gh', 'api', '--allow-escape-sequences', f'repos/{repo()}/actions/jobs/{job_id}/logs'],
                                capture_output=True, check=False)
        if result.returncode:
            return ''
        # Keep only the step lines: the full logs are megabytes each.
        text = result.stdout.decode(errors='replace')
        path.write_text(''.join(f'{s}: {t}s — passed\n' for s, t in plan_steps(text)))
    return path.read_text()


def choose_runs(runs, now, per_window=40):
    """The runs worth reading: on 2026-11-20 hosted-portable had 1,865 successful runs in 28 days, mostly PR pushes,
    and a portable job's log is about 4 MB. So: the newest `per_window` runs of each event in the recent week (the
    table's window and drift's "now"), and as many from the baseline week (drift's "then")."""
    recent_from = now - timedelta(days=DRIFT_RECENT_DAYS)
    base_to = now - timedelta(days=DRIFT_BASELINE_DAYS)
    base_from = base_to - timedelta(days=DRIFT_RECENT_DAYS)
    chosen = {}
    for event in sorted({run['event'] for run in runs}):
        mine = sorted((run for run in runs if run['event'] == event), key=lambda run: run['created_at'], reverse=True)
        for low, high in ((recent_from, now + timedelta(days=1)), (base_from, base_to)):
            inside = [run for run in mine if low <= parse_time(run['created_at']) < high]
            # The table wants WINDOW runs even in a quiet week, so the recent pick reaches back past the week if needed.
            if high > now and len(inside) < per_window:
                inside = [run for run in mine if parse_time(run['created_at']) < high]
            for run in inside[:per_window]:
                chosen[run['id']] = run
    return sorted(chosen.values(), key=lambda run: run['created_at'], reverse=True)


def collect(days, out=OUT, per_window=40):
    now = datetime.now(timezone.utc)
    # The Actions API returns at most 1,000 runs for a filtered listing (1,865 passed in 28 days on 2026-11-20), so
    # list one week at a time.
    listed = {}
    for week in range(0, days, 7):
        start = (now - timedelta(days=min(week + 7, days))).strftime('%Y-%m-%dT%H:%M:%SZ')
        end = (now - timedelta(days=week)).strftime('%Y-%m-%dT%H:%M:%SZ')
        pages = gh_json(f'repos/{repo()}/actions/workflows/{WORKFLOW}/runs?status=success&per_page=100&created={start}..{end}')
        listed.update((run['id'], run) for page in pages for run in page['workflow_runs'])
    listed = list(listed.values())
    runs = choose_runs(listed, now, per_window)
    cache = out / 'logs'
    cache.mkdir(parents=True, exist_ok=True)

    def one(run):
        jobs = [job for page in gh_json(f'repos/{repo()}/actions/runs/{run["id"]}/jobs?per_page=100') for job in page['jobs']]
        rows = []
        base = {'run': run['id'], 'event': run['event'], 'created': run['created_at'], 'attempt': run.get('run_attempt', 1)}
        for job in jobs:
            if job.get('conclusion') != 'success':
                continue
            queued = seconds_between(job.get('created_at'), job.get('started_at'))
            rows.append({**base, 'kind': 'job', 'job': job['name'], 'step': '', 'queued': queued,
                         'seconds': seconds_between(job['started_at'], job['completed_at']),
                         'job_started': job['started_at'], 'job_completed': job['completed_at']})
            for step in job.get('steps') or []:
                if step.get('conclusion') == 'success':
                    rows.append({**base, 'kind': 'workflow-step', 'job': job['name'], 'step': step['name'],
                                 'seconds': seconds_between(step.get('started_at'), step.get('completed_at'))})
            if (job['completed_at'] and parse_time(job['completed_at']) - parse_time(job['started_at'])
                    > timedelta(minutes=2)):
                for name, seconds in plan_steps(job_log(job['id'], cache)):
                    rows.append({**base, 'kind': 'plan-step', 'job': job['name'], 'step': name, 'seconds': seconds})
        return rows

    with ThreadPoolExecutor(max_workers=6) as pool:
        samples = [row for rows in pool.map(one, runs) for row in rows]
    out.mkdir(parents=True, exist_ok=True)
    (out / 'samples.json').write_text(json.dumps({'collected': now.isoformat(timespec='seconds'), 'days': days,
                                                  'listed': len(listed), 'runs': len(runs), 'samples': samples}, indent=1))
    print(f'read {len(runs)} of {len(listed)} successful runs, {len(samples)} samples -> {out / "samples.json"}')


def percentile(values, share):
    """Linear interpolation between the closest ranks (numpy's default)."""
    ordered = sorted(values)
    if not ordered:
        return None
    position = (len(ordered) - 1) * share
    low, high = math.floor(position), math.ceil(position)
    return ordered[low] + (ordered[high] - ordered[low]) * (position - low)


def load_samples(out=OUT):
    data = json.loads((out / 'samples.json').read_text())
    return data, data['samples']


def newest_first(rows):
    return sorted(rows, key=lambda row: (row['created'], row['run']), reverse=True)


def derive(samples, previous=None, window=WINDOW):
    """The table: each limit from the last `window` passing samples of its steps, in any job."""
    previous = previous or {}
    limits = {}
    for name, spec in LIMITS.items():
        rows = newest_first([row for row in samples if row['kind'] == 'plan-step' and row['step'] in spec['steps']])
        # One sample per run and step: the slowest job that ran it (runner-tests runs in two jobs; the slow one bounds it).
        best = {}
        for row in rows:
            key = (row['run'], row['step'])
            if key not in best or row['seconds'] > best[key]['seconds']:
                best[key] = row
        by_step = {step: newest_first([r for r in best.values() if r['step'] == step])[:window] for step in spec['steps']}
        p95s = {step: percentile([r['seconds'] for r in rows_], 0.95) for step, rows_ in by_step.items() if len(rows_) >= MIN_SAMPLES}
        old = previous.get(name, {})
        if not p95s:
            limits[name] = {**old, 'note': f'fewer than {MIN_SAMPLES} samples; kept the previous value'} if old else None
            continue
        step, p95 = max(p95s.items(), key=lambda item: item[1])
        used = by_step[step]
        seconds = max(spec['floor'], int(math.ceil(LIMIT_FACTOR * p95 / 60.0)) * 60)
        limits[name] = {
            'seconds': seconds,
            'bounded_by': step,
            'p50': round(percentile([r['seconds'] for r in used], 0.5), 1),
            'p95': round(p95, 1),
            'max': round(max(r['seconds'] for r in used), 1),
            'samples': len(used),
            'from': min(r['created'] for r in used)[:10],
            'to': max(r['created'] for r in used)[:10],
            'runs': sorted({r['run'] for r in used}),
        }
    return {
        'rule': f'{LIMIT_FACTOR} x p95 of the last {WINDOW} passing samples, rounded up to a minute, never below the '
                f'floor; regenerate with `python3 scripts/ci_step_budgets.py collect && python3 scripts/ci_step_budgets.py table`',
        'limits': {name: value for name, value in limits.items() if value},
    }


def table(out=OUT, path=TABLE):
    _, samples = load_samples(out)
    previous = json.loads(path.read_text()).get('limits', {}) if path.exists() else {}
    fresh = derive(samples, previous)
    path.write_text(json.dumps(fresh, indent=1) + '\n')
    for name, value in fresh['limits'].items():
        was = previous.get(name, {}).get('seconds')
        print(f'{name}: {value["seconds"]} s (was {was}); {value.get("bounded_by")} p50 {value.get("p50")} s, '
              f'p95 {value.get("p95")} s over {value.get("samples")} runs')


def job_timeouts(workflow=ROOT / '.github' / 'workflows' / WORKFLOW):
    """{check name: timeout seconds} from the workflow's jobs, read line by line (no YAML library in stdlib)."""
    timeouts, name = {}, None
    for line in workflow.read_text().splitlines():
        if re.match(r'^  [A-Za-z0-9_-]+:\s*$', line):
            name = None
        match = re.match(r"^    name: '?([^'#]+?)'?\s*$", line)
        if match:
            name = match.group(1)
        match = re.match(r'^    timeout-minutes: (\d+)', line)
        if match and name:
            timeouts[name] = int(match.group(1)) * 60
    return timeouts


def drift(samples, limits, timeouts, now=None):
    """[finding text] for each step or job whose p50 rose too far or whose p95 nears its limit."""
    now = now or datetime.now(timezone.utc)
    findings = []
    groups = {}
    for row in samples:
        if row['kind'] in ('plan-step', 'job') and row['seconds'] is not None:
            groups.setdefault((row['kind'], row['job'], row['step']), []).append(row)
    recent_from = now - timedelta(days=DRIFT_RECENT_DAYS)
    base_to = now - timedelta(days=DRIFT_BASELINE_DAYS)
    base_from = base_to - timedelta(days=DRIFT_RECENT_DAYS)
    step_limit = {step: (name, value['seconds']) for name, value in limits.items() for step in LIMITS.get(name, {}).get('steps', [])}
    for (kind, job, step), rows in sorted(groups.items()):
        label = f'{job} / {step}' if step else f'{job} (whole job)'
        recent = [r['seconds'] for r in rows if parse_time(r['created']) >= recent_from]
        base = [r['seconds'] for r in rows if base_from <= parse_time(r['created']) < base_to]
        if len(recent) >= DRIFT_MIN_SAMPLES and len(base) >= DRIFT_MIN_SAMPLES:
            now_p50, then_p50 = percentile(recent, 0.5), percentile(base, 0.5)
            if then_p50 >= 30 and now_p50 > then_p50 * (1 + DRIFT_P50_RISE):
                findings.append(f'{label}: p50 rose {100 * (now_p50 / then_p50 - 1):.0f}% in two weeks, '
                                f'{then_p50:.0f} s to {now_p50:.0f} s ({len(base)} and {len(recent)} runs)')
        last = [r['seconds'] for r in newest_first(rows)[:WINDOW]]
        if kind == 'plan-step' and step in step_limit:
            limit_name, limit = step_limit[step]
        elif kind == 'job' and job in timeouts:
            limit_name, limit = f'timeout-minutes of "{job}"', timeouts[job]
        else:
            continue
        if len(last) >= MIN_SAMPLES:
            p95 = percentile(last, 0.95)
            if p95 > DRIFT_P95_SHARE * limit:
                findings.append(f'{label}: p95 {p95:.0f} s is {100 * p95 / limit:.0f}% of its limit '
                                f'({limit_name}, {limit} s) over the last {len(last)} runs')
    return findings


def drift_report(findings, data):
    head = (f'Read {data["runs"]} of the {data.get("listed", data["runs"])} successful hosted-portable runs from the last '
            f'{data["days"]} days at {data["collected"]}. '
            f'Rule: a step drifts when its p50 rises more than {int(DRIFT_P50_RISE * 100)}% over two weeks, or its '
            f'p95 passes {int(DRIFT_P95_SHARE * 100)}% of its limit.\n\n')
    if not findings:
        return head + 'No step is drifting.\n'
    return (head + '\n'.join(f'{i}. {text}' for i, text in enumerate(findings, 1)) +
            '\n\nThis job changes no limit. To propose new ones: run `python3 scripts/ci_step_budgets.py collect` then '
            '`python3 scripts/ci_step_budgets.py table`, and open a PR with the new scripts/ci_step_budgets.json '
            '(and any timeout-minutes) under a Cost and catch heading.\n')


def update_issue(findings, body):
    found = subprocess.run(['gh', 'issue', 'list', '--repo', repo(), '--state', 'open', '--search',
                            f'"{DRIFT_ISSUE_TITLE}" in:title', '--json', 'number,title'],
                           capture_output=True, text=True, check=True).stdout
    issue = next((item['number'] for item in json.loads(found) if item['title'] == DRIFT_ISSUE_TITLE), None)
    if findings and issue is None:
        subprocess.run(['gh', 'issue', 'create', '--repo', repo(), '--title', DRIFT_ISSUE_TITLE, '--body', body], check=True)
    elif findings:
        subprocess.run(['gh', 'issue', 'edit', str(issue), '--repo', repo(), '--body', body], check=True)
    elif issue is not None:
        subprocess.run(['gh', 'issue', 'close', str(issue), '--repo', repo(), '--comment', body], check=True)


def profile(samples):
    """Per job and per step: runs, p50, p95. For choosing what runs first on a PR."""
    groups = {}
    for row in samples:
        if row['seconds'] is not None:
            groups.setdefault((row['job'], row['kind'], row['step']), []).append(row['seconds'])
    lines = ['job | kind | step | runs | p50 s | p95 s', '--- | --- | --- | --- | --- | ---']
    for (job, kind, step), values in sorted(groups.items()):
        lines.append(f'{job} | {kind} | {step} | {len(values)} | {percentile(values, 0.5):.0f} | {percentile(values, 0.95):.0f}')
    return '\n'.join(lines) + '\n'


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    sub = parser.add_subparsers(dest='command', required=True)
    c = sub.add_parser('collect')
    c.add_argument('--days', type=int, default=28)
    c.add_argument('--per-window', type=int, default=40, help='runs per event in each of the two weeks read')
    sub.add_parser('table')
    d = sub.add_parser('drift')
    d.add_argument('--issue', action='store_true', help='open, update or close the "CI step drift" issue')
    sub.add_parser('profile')
    args = parser.parse_args(argv)
    if args.command == 'collect':
        collect(args.days, per_window=args.per_window)
    elif args.command == 'table':
        table()
    elif args.command == 'drift':
        data, samples = load_samples()
        limits = json.loads(TABLE.read_text())['limits']
        findings = drift(samples, limits, job_timeouts())
        body = drift_report(findings, data)
        print(body)
        if args.issue:
            update_issue(findings, body)
    elif args.command == 'profile':
        _, samples = load_samples()
        text = profile(samples)
        (OUT / 'profile.md').write_text(text)
        print(f'{text.count(chr(10)) - 2} rows -> {OUT / "profile.md"}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
