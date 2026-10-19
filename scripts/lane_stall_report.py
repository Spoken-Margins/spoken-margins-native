#!/usr/bin/env python3
"""Count T3 startup stalls against the host's conditions at launch (#2176).

Reads every verify-app and verify-adapters manifest under the lane's evidence folders and treats each launch attempt
of an `xcode-tests` step as one row: stalled or not, with the conditions recorded as it started (lane_conditions.py;
older manifests have only the step's load average, which stands for its first attempt). It prints the stall rate in
buckets of each signal, and how long clean launches took to start their tests, by app size, so a threshold for a
launch gate (#2176 step 2) comes from data, not a guess.

  .venv/bin/python scripts/lane_stall_report.py                     # the main checkout's artifacts/lane
  .venv/bin/python scripts/lane_stall_report.py --since 2026-10-19 artifacts/lane
  .venv/bin/python scripts/lane_stall_report.py --json
"""
import argparse
import datetime
import json
from pathlib import Path
import statistics
import sys

ROOT = Path(__file__).resolve().parent.parent
PLANS = ('verify-app', 'verify-adapters')

# Signal name -> (how to read it from a row's conditions, bucket lower edges).
SIGNALS = {
    'load_1m': (lambda c: (c.get('load_average') or [None])[0], (0, 100, 150, 200, 300)),
    'load_5m': (lambda c: (c.get('load_average') or [None, None])[1], (0, 100, 150, 200)),
    'memory_pressure': (lambda c: c.get('memory_pressure'), None),
    'swap_used_mb': (lambda c: c.get('swap_used_mb'), (0, 1000, 2000, 4000)),
    'free_disk_gb': (lambda c: c.get('free_disk_gb'), (0, 20, 25, 40, 80)),
    'simulator_jobs': (lambda c: _count(c, 'simulator'), None),
    'build_jobs': (lambda c: _count(c, 'build'), None),
    'host_test_jobs': (lambda c: _count(c, 'host_test'), None),
}


def _count(conditions, kind):
    jobs = (conditions.get('lane_jobs') or {}).get(kind)
    return None if jobs is None else len(jobs)


def default_folders():
    """The main checkout's artifacts/lane (a worktree has none of its own)."""
    here = ROOT / 'artifacts/lane'
    if here.is_dir():
        return [here]
    main = ROOT.parent.parent.parent / 'artifacts/lane' if ROOT.parent.name == 'worktrees' else None
    return [main] if main and main.is_dir() else [here]


def launch_rows(manifest, plan, day):
    """One row per launch attempt of the manifest's xcode-tests step."""
    rows = []
    for step in manifest.get('steps', []):
        if step.get('name') != 'xcode-tests':
            continue
        stalls = {stall.get('attempt'): stall for stall in step.get('startup_stalls', [])}
        attempts = step.get('startup_attempts') or 1
        noted = step.get('launch_conditions', [])
        for attempt in range(1, attempts + 1):
            start = next((n for n in noted if n.get('attempt') == attempt and n.get('at') == 'start'), None)
            if start is None and attempt == 1 and step.get('load_average_start'):
                start = {'load_average': step['load_average_start']}  # manifests before #2176
            started = next((n for n in noted if n.get('attempt') == attempt and n.get('at') == 'tests_started'), None)
            stall = stalls.get(attempt)
            rows.append({'plan': plan, 'day': day, 'attempt': attempt, 'stalled': stall is not None,
                         'session_last_step': (stall or {}).get('session_last_step'),
                         'conditions': start or {}, 'tests_started_seconds': (started or {}).get('seconds'),
                         'app_bundle_mb': manifest.get('app_bundle_mb')})
    return rows


def collect(folders, since=None):
    rows = []
    for folder in folders:
        for path in sorted(Path(folder).glob('*/verify-*/manifest.json')):
            plan = path.parent.name
            if plan not in PLANS:
                continue
            try:
                manifest = json.loads(path.read_text())
                day = datetime.date.fromtimestamp(path.stat().st_mtime).isoformat()
            except (OSError, ValueError):
                continue
            if since and day < since:
                continue
            rows.extend({**row, 'run': path.parent.parent.name} for row in launch_rows(manifest, plan, day))
    return rows


def bucket_label(value, edges):
    if edges is None:
        return str(value)
    lower = [edge for edge in edges if value >= edge]
    if not lower:
        return f'< {edges[0]}'
    index = edges.index(lower[-1])
    return f'{lower[-1]}-{edges[index + 1]}' if index + 1 < len(edges) else f'{lower[-1]}+'


def table(rows, key):
    """[(bucket, stalled, launches)] for a signal, rows without a reading left out, in bucket order."""
    read, edges = SIGNALS.get(key, (None, None))
    counts = {}
    for row in rows:
        value = read(row['conditions']) if read else row.get(key)
        if value is None:
            continue
        label = bucket_label(value, edges)
        stalled, total, order = counts.get(label, (0, 0, value))
        counts[label] = (stalled + row['stalled'], total + 1, min(order, value) if edges else order)
    ordered = sorted(counts.items(), key=lambda item: (item[1][2] if edges else str(item[0])))
    return [(label, stalled, total) for label, (stalled, total, _) in ordered]


def startup_times(rows):
    """Median seconds from launch to the first test line, for clean launches, by app bundle size."""
    found = {}
    for row in rows:
        if row['tests_started_seconds'] is not None and row['app_bundle_mb'] is not None:
            found.setdefault(f'{round(row["app_bundle_mb"] / 50) * 50:.0f} MB', []).append(row['tests_started_seconds'])
    return {size: {'launches': len(times), 'median_seconds': round(statistics.median(times), 1)}
            for size, times in sorted(found.items())}


def report(rows):
    out = {'launches': len(rows), 'stalled': sum(row['stalled'] for row in rows),
           'by_day': table(rows, 'day'), 'by_plan': table(rows, 'plan'), 'by_attempt': table(rows, 'attempt'),
           'session_last_step': {}, 'signals': {}, 'startup_seconds_by_app_size': startup_times(rows)}
    for row in rows:
        if row['stalled']:
            step = row['session_last_step'] or 'none recorded'
            out['session_last_step'][step] = out['session_last_step'].get(step, 0) + 1
    for key in SIGNALS:
        out['signals'][key] = table(rows, key)
    return out


def print_report(out, file=None):
    file = file or sys.stdout
    print(f'{out["stalled"]} of {out["launches"]} launch attempts stalled', file=file)
    for title, key in (('By day', 'by_day'), ('By plan', 'by_plan'), ('By attempt', 'by_attempt')):
        print(f'\n{title}:', file=file)
        for label, stalled, total in out[key]:
            print(f'  {label:>16}: {stalled} of {total}', file=file)
    print('\nWhere stalled launches stopped (session log):', file=file)
    for step, count in sorted(out['session_last_step'].items(), key=lambda item: -item[1]):
        print(f'  {count:3} {step}', file=file)
    for key, rows in out['signals'].items():
        read = sum(total for _, _, total in rows)
        print(f'\n{key} at launch ({read} of {out["launches"]} launches have it):', file=file)
        for label, stalled, total in rows:
            print(f'  {label:>16}: {stalled} of {total} stalled ({100 * stalled / total:.0f}%)', file=file)
    if out['startup_seconds_by_app_size']:
        print('\nSeconds from launch to the first test line (clean launches), by app size:', file=file)
        for size, found in out['startup_seconds_by_app_size'].items():
            print(f'  {size:>8}: median {found["median_seconds"]}s over {found["launches"]}', file=file)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('folders', nargs='*', type=Path, help='lane evidence folders (default: artifacts/lane)')
    parser.add_argument('--since', help='only manifests written on or after this day (YYYY-MM-DD)')
    parser.add_argument('--json', action='store_true', help='print the counts as JSON')
    args = parser.parse_args(argv)
    out = report(collect(args.folders or default_folders(), args.since))
    if args.json:
        print(json.dumps(out, indent=2))
    else:
        print_report(out)
    return 0


if __name__ == '__main__':
    sys.exit(main())
