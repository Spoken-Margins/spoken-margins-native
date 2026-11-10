#!/usr/bin/env python3
"""Count the Test Desk's agent-driven journey runs and the bugs they found, from the `record:` lines in lane reports (#3903).

Nothing used to keep a record of an agent-driven run, so catches per Test Desk hour could not be computed (the
what-catches-what report, 2026-11-09). Each desk report now carries one line per journey it ran (test-lane.md, Report
format), next to the verdict:

  record: J7 · build bb00725 · steps 0/3 · bugs #3931, #3932
  record: J1 · build bb00725 · steps 9/9 · bugs none
  record: scenario · build 3997dbb · steps 2/3 · bugs #3940      (a one-off scenario from a request)

  scripts/journey_runs.py                   the last 30 days: runs, steps passed, bugs filed, per journey
  scripts/journey_runs.py --window-days 7   another window
  scripts/journey_runs.py --json            the same as JSON

Only the desk's own reports count (the runner's `pr<N>-r<run>`, `integration-` and `journeys-` ids are scripted, not
agent-driven), from trusted commenters (comment_trust). A desk report with no valid `record:` line (none, or a malformed or impossible one) is counted as
unrecorded, so the audit sees how much of the Test Desk's work the record covers. The script only reads GitHub.
"""
from __future__ import annotations

import argparse
import datetime as dt
import importlib.util
import json
from pathlib import Path
import re
import sys

SCRIPTS = Path(__file__).resolve().parent
_spec = importlib.util.spec_from_file_location('desk_batch', SCRIPTS / 'desk-batch.py')
desk = importlib.util.module_from_spec(_spec)
sys.modules.setdefault('desk_batch', desk)
_spec.loader.exec_module(desk)

SEP = r'\s*[·|]\s*'
RECORD = re.compile(
    rf'^\s*record:\s*(J\d+|scenario){SEP}build\s+(\S+){SEP}steps\s+(\d+)\s*/\s*(\d+){SEP}bugs\s+'
    r'(none|#\d+(?:\s*,\s*#\d+)*)\s*$', re.I | re.M | re.A)
BUG = re.compile(r'#(\d+)')


def parse_records(body):
    """The run records in one report body: journey, build, steps passed and total, bug issue numbers."""
    records = []
    for match in RECORD.finditer(body or ''):
        journey, build, passed, total, bugs = match.groups()
        if int(total) == 0 or int(passed) > int(total):
            continue  # not a possible count: left unrecorded, so the audit sees it
        records.append({'journey': journey.upper() if journey.lower() != 'scenario' else 'scenario', 'build': build,
                        'steps_passed': int(passed), 'steps_total': int(total),
                        'bugs': sorted({int(n) for n in BUG.findall(bugs)})})
    return records


def summarize(comments):
    """Counts over desk reports among `comments` (GitHub issue-comment dicts with a `body`)."""
    reports = [c for c in comments if desk.is_desk_report(c.get('body') or '')]
    runs, unrecorded = [], 0
    for report in reports:
        found = parse_records(report['body'])
        if not found:
            unrecorded += 1
        runs += found
    per_journey = {}
    for run in runs:
        row = per_journey.setdefault(run['journey'], {'runs': 0, 'steps_passed': 0, 'steps_total': 0, 'bugs': set()})
        row['runs'] += 1
        row['steps_passed'] += run['steps_passed']
        row['steps_total'] += run['steps_total']
        row['bugs'].update(run['bugs'])
    bugs = sorted({n for run in runs for n in run['bugs']})
    return {'desk_reports': len(reports), 'unrecorded_reports': unrecorded, 'runs': len(runs),
            'runs_with_bugs': sum(1 for run in runs if run['bugs']),
            'steps_passed': sum(run['steps_passed'] for run in runs),
            'steps_total': sum(run['steps_total'] for run in runs), 'bugs': bugs,
            'per_journey': {key: {**row, 'bugs': sorted(row['bugs'])} for key, row in sorted(per_journey.items())}}


def render(summary, days):
    lines = [f'Test Desk journey runs, last {days} days',
             f"desk reports: {summary['desk_reports']} ({summary['unrecorded_reports']} with no record line)",
             f"runs: {summary['runs']}, {summary['runs_with_bugs']} found at least one bug",
             f"steps passed: {summary['steps_passed']} of {summary['steps_total']}",
             'bugs filed: ' + (', '.join(f'#{n}' for n in summary['bugs']) or 'none')]
    for key, row in summary['per_journey'].items():
        found = ', '.join(f'#{n}' for n in row['bugs']) or 'none'
        lines.append(f"  {key}: {row['runs']} runs, steps {row['steps_passed']}/{row['steps_total']}, bugs {found}")
    return '\n'.join(lines)


def main(argv=None, api=None, now=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--window-days', type=int, default=30)
    parser.add_argument('--json', action='store_true')
    args = parser.parse_args(argv)
    now = now or dt.datetime.now(dt.timezone.utc)
    since = (now - dt.timedelta(days=args.window_days)).strftime('%Y-%m-%dT%H:%M:%SZ')
    try:
        comments = desk.comments_since(api or desk.GitHub(), since)
    except RuntimeError as error:
        print(f'cannot read GitHub: {error}', file=sys.stderr)
        return 2
    summary = summarize(comments)
    print(json.dumps(summary, indent=2) if args.json else render(summary, args.window_days))
    return 0


if __name__ == '__main__':
    sys.exit(main())
