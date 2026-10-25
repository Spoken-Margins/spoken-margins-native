#!/usr/bin/env python3
"""Guard for the #2626 class: a "do this once after a trigger" check that stays true after it has run (#2633).

#2626: the tap cut a post-seek landmark whenever `continuityEpoch > 0`. The epoch counts seeks and is never reset, so
after one seek the check was true on every buffer for the rest of the session. Each pass generated a signature, rewrote
the spine and wrote files until iOS killed the backgrounded app. The fix compares the epoch with a "served" marker the
branch advances when it fires (`continuityEpoch > stablePostSeekServedEpoch`).

This scanner fails on the shape that caused it: a monotonic counter (a name ending in Epoch, Generation, Seq, Sequence,
Revision or Counter) compared with `>` or `>=` against a bare number, or against a name that does not say it is a
served marker (served, handled, seen, last, done, processed, consumed, applied, published, reported, fired, shown,
told, cued, announced, captured, committed, observed, previous, prior, baseline, saved, sent). `!=` and `<` compares
are edge or staleness checks, and `>= 0` is a validity check (a counter starts at 0), so those are left alone.

  scripts/repeat_trigger_scan.py            check: exit 1 on a flagged line without an exemption
  scripts/repeat_trigger_scan.py --list     print every line it looks at, flagged or not

A flagged line that is right as written carries `// once-per-trigger: <what marks it served>` on the same or the
previous line. The comment is the point: it names the marker, so the next reader can check it is advanced when the
branch fires. Test files are not scanned. Every other repeated-work site is listed in the #2633 inventory; the
runaway-work test for the first one is SeekLandmarkRepeatTests.

Blind spots: it reads names, not types, so a counter called something else, or compared through a helper, is missed. A
cursor compared through `!=` can repeat only if it is never advanced, which a name scan cannot see.

Stdlib only, Python 3.9-compatible.
"""
from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE_DIRS = ('Packages/SessionKit/Sources', 'App/SpokenMarginsApp/Sources', 'App/SharedSources')
COUNTER = r'[A-Za-z_][A-Za-z0-9_.]*(?:Epoch|Generation|Seq|Sequence|Revision|Counter)'
SERVED = ('served', 'handled', 'seen', 'last', 'done', 'processed', 'consumed', 'applied', 'published', 'reported',
          'fired', 'shown', 'told', 'cued', 'announced', 'captured', 'committed', 'observed', 'previous', 'prior',
          'baseline', 'saved', 'sent')
COMPARE = re.compile(r'\b(' + COUNTER + r')\s*(>=|>)\s*([A-Za-z0-9_.]+)')
EXEMPT = '// once-per-trigger:'


def swift_files() -> list[Path]:
    out = subprocess.run(['git', 'ls-files', *SOURCE_DIRS], cwd=ROOT, capture_output=True, text=True, check=True).stdout
    return [ROOT / line for line in out.splitlines() if line.endswith('.swift')]


def judge(line: str, previous: str) -> list[tuple[str, str, str]]:
    """Return (counter, operator, right-hand side) for each compare on `line` that is not a served-marker compare."""
    code = line.split('//', 1)[0]
    if EXEMPT in line or EXEMPT in previous:
        return []
    flagged = []
    for counter, operator, rhs in COMPARE.findall(code):
        if any(word in rhs.lower() for word in SERVED):
            continue
        if operator == '>=' and rhs == '0':
            continue
        flagged.append((counter, operator, rhs))
    return flagged


def scan(files: list[Path]) -> list[tuple[str, int, str, str, str, str]]:
    rows = []
    for path in files:
        lines = path.read_text(encoding='utf-8', errors='replace').splitlines()
        for number, line in enumerate(lines, 1):
            previous = lines[number - 2] if number > 1 else ''
            for counter, operator, rhs in judge(line, previous):
                rows.append((str(path.relative_to(ROOT)), number, counter, operator, rhs, line.strip()))
    return rows


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    parser.add_argument('--list', action='store_true', help='print every flagged line and exit 0')
    args = parser.parse_args()
    rows = scan(swift_files())
    for path, number, counter, operator, rhs, text in rows:
        print(f'{path}:{number}: {counter} {operator} {rhs}\n    {text}')
    if args.list:
        return 0
    if rows:
        print(f'\n{len(rows)} counter compare(s) can stay true after they fire (#2626 class). Compare against a marker the '
              f'branch advances, or add `{EXEMPT} <marker>` naming it.', file=sys.stderr)
        return 1
    print('repeat-trigger-scan: no unguarded counter compares')
    return 0


if __name__ == '__main__':
    sys.exit(main())
