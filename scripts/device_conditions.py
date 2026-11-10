#!/usr/bin/env python3
"""Count phone-found bugs by the device condition behind them (#3899).

The list is docs/workstreams/device-conditions-bugs.tsv; the rows are defined in docs/workstreams/device-conditions.md.
The waste signal in #3899 ("over the next 30 phone-found bugs, device-condition and performance bugs are still more
than half") is read from here, with no hand count.

  scripts/device_conditions.py                     count per row, and the share that has a device condition
  scripts/device_conditions.py --after-issue 3897  count only bugs filed after that issue (the next-30 reading: pass --first 30)
  scripts/device_conditions.py --check             fail on an unknown row, a repeated issue or a malformed line
  scripts/device_conditions.py --unlisted          found-on-phone bugs on GitHub that the list does not have yet (needs gh)
"""
import argparse
from collections import Counter
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
LIST = ROOT / 'docs/workstreams/device-conditions-bugs.tsv'
ROWS = ('lock', 'background', 'relaunch', 'store', 'main-thread', 'network', 'route', 'web-packet', 'live-activity',
        'hot', 'burst', 'long-source')
NO_ROW_REASONS = ('parse-fixture', 'visual', 'design', 'logic', 'unclear', 'ears', 'ops')
REPO = 'Spoken-Margins/spoken-margins-native'


def valid_row(row):
    return row in ROWS or (row.startswith('none:') and row[5:] in NO_ROW_REASONS)


def load(path=LIST):
    """Every bug in the list as a dict. Raises ValueError on a malformed line."""
    bugs = []
    for number, line in enumerate(Path(path).read_text().splitlines(), 1):
        if not line.strip() or line.startswith('#'):
            continue
        fields = line.split('\t')
        if len(fields) != 6:
            raise ValueError(f'line {number}: want 6 tab-separated columns, got {len(fields)}')
        issue, created, state, row, also, title = fields
        if not issue.isdigit():
            raise ValueError(f'line {number}: issue {issue!r} is not a number')
        bugs.append({'issue': int(issue), 'created': created, 'state': state, 'row': row, 'also': also, 'title': title})
    return bugs


def problems(bugs):
    found = []
    seen = set()
    for bug in bugs:
        if bug['issue'] in seen:
            found.append(f"#{bug['issue']} is listed twice")
        seen.add(bug['issue'])
        if not valid_row(bug['row']):
            found.append(f"#{bug['issue']}: unknown row {bug['row']!r}")
        if bug['also'] and bug['also'] not in ROWS:
            found.append(f"#{bug['issue']}: unknown also {bug['also']!r}")
        if bug['also'] and bug['also'] == bug['row']:
            found.append(f"#{bug['issue']}: also repeats its row")
    return found


def counts(bugs):
    """(per-row counts, bugs with a device-condition row, total). `also` counts apart, never in the share."""
    primary = Counter(bug['row'] for bug in bugs)
    with_row = sum(1 for bug in bugs if bug['row'] in ROWS)
    return primary, with_row, len(bugs)


def report(bugs):
    primary, with_row, total = counts(bugs)
    also = Counter(bug['also'] for bug in bugs if bug['also'])
    lines = [f'{"row":<22}{"bugs":>5}{"also":>6}']
    for row in ROWS:
        lines.append(f'{row:<22}{primary[row]:>5}{also[row]:>6}')
    for key in sorted(k for k in primary if k.startswith('none:')):
        lines.append(f'{key:<22}{primary[key]:>5}')
    share = f'{with_row / total:.0%}' if total else 'n/a'
    lines.append(f'{with_row} of {total} have a device condition ({share})')
    return '\n'.join(lines)


def after_issue(bugs, number, first=None):
    """The bugs filed after issue `number`, oldest first, at most `first` of them."""
    later = sorted((bug for bug in bugs if bug['issue'] > number), key=lambda bug: bug['issue'])
    return later[:first] if first else later


def unlisted(bugs):
    listed = {bug['issue'] for bug in bugs}
    out = subprocess.run(
        ['gh', 'api', '-X', 'GET', 'search/issues', '--paginate', '-f', f'q=repo:{REPO} is:issue label:found-on-phone label:bug',
         '-f', 'per_page=100', '--jq', '.items[] | [.number, .title] | @tsv'],
        capture_output=True, text=True, check=True).stdout
    rows = [line.split('\t', 1) for line in out.splitlines() if line.strip()]
    return sorted((int(n), title) for n, title in rows if int(n) not in listed)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--after-issue', type=int, help='only bugs whose issue number is above this one')
    parser.add_argument('--first', type=int, help='with --after-issue, only the first N of them (lowest issue numbers)')
    parser.add_argument('--check', action='store_true')
    parser.add_argument('--unlisted', action='store_true')
    args = parser.parse_args(argv)
    bugs = load()
    if args.check:
        found = problems(bugs)
        print('\n'.join(found) if found else f'{len(bugs)} bugs, all rows valid')
        return 1 if found else 0
    if args.unlisted:
        missing = unlisted(bugs)
        for number, title in missing:
            print(f'{number}\t{title}')
        print(f'{len(missing)} not in the list', file=sys.stderr)
        return 0
    if args.after_issue is not None:
        bugs = after_issue(bugs, args.after_issue, args.first)
    print(report(bugs))
    return 0


if __name__ == '__main__':
    sys.exit(main())
