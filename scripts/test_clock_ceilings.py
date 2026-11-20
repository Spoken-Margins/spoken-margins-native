#!/usr/bin/env python3
"""Wall-clock ceilings in Swift tests: "the work took under N seconds" asserted on a real clock (#4573).

On 2026-11-20 a LibraryFolderQueryTests check that a Library read finished in under 2 s took 2.26 s on a busy hosted
Mac. It failed every merge group and held the merge queue for about an hour, though the app was fine (#4743, #4760).
A ceiling on a real clock measures the machine as much as the code. A test that means "the caller never waits" or
"the read does not wait for the writer" proves it on state instead: a gate or semaphore the test holds while it checks
the call came back, an expectation, a check that the blocking resource was still held. See docs/testing.md
(Waiting in tests).

  scripts/test_clock_ceilings.py            list the ceilings found; exit 1 on one that is not on the allowlist,
                                            or an allowlist entry that no longer has one
  scripts/test_clock_ceilings.py --write F  also write every ceiling found to the JSON file F (use artifacts/)

What counts as a ceiling, inside one Swift func:
  * a start reading: `let t = Date()`, `Date.now`, `ContinuousClock.now`, `SuspendingClock.now`,
    `CFAbsoluteTimeGetCurrent()`, `DispatchTime.now()`, `ProcessInfo.processInfo.systemUptime`, `mach_absolute_time()`;
  * a duration: `Date().timeIntervalSince(t)`, `ContinuousClock.now - t` (any clock reading minus a start), a
    `.measure {` on a clock, and any variable assigned or appended from a duration (`elapsed`, `elapsedMs`, `sorted`);
  * a ceiling: `XCTAssertLessThan`/`XCTAssertLessThanOrEqual` with a duration in the first argument,
    `XCTAssertGreaterThan`/`XCTAssertGreaterThanOrEqual` with one in the second, or `XCTAssert`/`XCTAssertTrue`/
    `#expect` comparing one with `<` or `<=`.
Not counted: lower bounds ("it waited at least the delay"), a stored timestamp checked against now
(`abs(record.at.timeIntervalSinceNow) < 60`, `Date().timeIntervalSince(record.checkedAt)` when `record.checkedAt` is not
a start reading taken in the test), and fake clocks the test advances.

A genuine performance budget ("3000 notes in one pass") stays only with a loose ceiling, at least 5x the typical local
time, and a comment naming the scaling bug it guards, and is listed with that reason in
scripts/test_clock_ceilings_allowlist.json as "<folder>/<file>::<func>".
"""
import argparse
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ALLOWLIST = ROOT / 'scripts' / 'test_clock_ceilings_allowlist.json'


def default_folders(root=ROOT):
    """Every Swift test folder: each package's Tests/ and each App/*Tests target."""
    folders = sorted(path for path in (root / 'Packages').glob('*/Tests') if path.is_dir())
    folders += sorted(path for path in (root / 'App').glob('*Tests') if path.is_dir())
    return folders


CLOCK = (r'(?:Date\(\)|Date\.now|ContinuousClock\.now|SuspendingClock\.now|ContinuousClock\(\)\.now'
         r'|SuspendingClock\(\)\.now|CFAbsoluteTimeGetCurrent\(\)|DispatchTime\.now\(\)'
         r'|ProcessInfo\.processInfo\.systemUptime|mach_absolute_time\(\))')
START = re.compile(r'\b(?:let|var)\s+(\w+)(?:\s*:\s*[\w.]+)?\s*=\s*' + CLOCK + r'(?:\.uptimeNanoseconds)?\s*$')
ASSIGN = re.compile(r'^\s*(?:(?:let|var)\s+)?(\w+)(?:\s*:\s*[^=]+)?\s*(?:=|\+=)\s*(.+)$')
APPEND = re.compile(r'^\s*(\w+)\.append\((.+)$')
MEASURE = re.compile(r'\b(?:let|var)\s+(\w+)\s*=\s*(?:try\s+)?(?:await\s+)?\w*(?:[Cc]lock\(\)|clock)\.measure\b')
FUNC = re.compile(r'\bfunc\s+(\w+)\s*[(<]')
ASSERT_START = re.compile(r'(XCTAssertLessThanOrEqual|XCTAssertLessThan|XCTAssertGreaterThanOrEqual|XCTAssertGreaterThan'
                          r'|XCTAssertTrue|XCTAssert|#expect)\s*\(')


def strip_comment(line):
    """The line without a trailing // comment (a // inside a string literal is kept)."""
    out, in_string = [], False
    i = 0
    while i < len(line):
        ch = line[i]
        if ch == '"' and (i == 0 or line[i - 1] != '\\'):
            in_string = not in_string
        if not in_string and line.startswith('//', i):
            break
        out.append(ch)
        i += 1
    return ''.join(out)


def split_args(text):
    """Top-level comma-separated arguments of the call whose open paren starts `text`."""
    depth, args, current, in_string = 0, [], [], False
    for i, ch in enumerate(text):
        if ch == '"' and (i == 0 or text[i - 1] != '\\'):
            in_string = not in_string
        if in_string:
            if depth >= 1:
                current.append(ch)
            continue
        if ch in '([{':
            depth += 1
            if depth == 1:
                continue
        elif ch in ')]}':
            depth -= 1
            if depth == 0:
                args.append(''.join(current).strip())
                return args
        elif ch == ',' and depth == 1:
            args.append(''.join(current).strip())
            current = []
            continue
        if depth >= 1:
            current.append(ch)
    args.append(''.join(current).strip())
    return args


def statement_from(lines, index, start_col):
    """The text from `start_col` of line `index` until its parentheses balance (an assertion spanning lines)."""
    text = strip_comment(lines[index])[start_col:]
    j = index
    while True:
        depth = text.count('(') - text.count(')')
        if depth <= 0 or j + 1 >= len(lines) or j - index > 12:
            return text
        j += 1
        text += ' ' + strip_comment(lines[j]).strip()


class Func:
    def __init__(self, name):
        self.name = name
        self.starts = set()
        self.durations = set()

    def is_duration(self, expr):
        """True when `expr` measures elapsed real time from a start reading taken in this func."""
        for var in self.durations:
            if re.search(r'(?<![\w.])' + re.escape(var) + r'\b', expr):
                return True
        for var in self.starts:
            v = re.escape(var)
            if re.search(CLOCK + r'\s*\.timeIntervalSince\(\s*' + v + r'\s*\)', expr):
                return True
            if re.search(CLOCK + r'(?:\.uptimeNanoseconds)?\s*-\s*' + v + r'\b', expr):
                return True
            if re.search(r'\b' + v + r'\.(?:duration\(to:|timeIntervalSinceNow)', expr):
                return True
        return False


def is_ceiling(kind, args, func):
    if not args:
        return False
    if kind in ('XCTAssertLessThan', 'XCTAssertLessThanOrEqual'):
        return func.is_duration(args[0])
    if kind in ('XCTAssertGreaterThan', 'XCTAssertGreaterThanOrEqual'):
        return len(args) > 1 and func.is_duration(args[1])
    condition = args[0]
    for match in re.finditer(r'(<=?|>=?)(?!=)', condition):
        op = match.group(1)
        left, right = condition[:match.start()], condition[match.end():]
        if op.startswith('<') and func.is_duration(left):
            return True
        if op.startswith('>') and func.is_duration(right):
            return True
    return False


def scan_source(source):
    """Every wall-clock ceiling in `source`, in order: {'line', 'func', 'assert'}."""
    lines = source.split('\n')
    found = []
    func = Func('?')
    for index, raw in enumerate(lines):
        line = strip_comment(raw)
        named = FUNC.search(line)
        if named:
            func = Func(named.group(1))
        start = START.search(line)
        if start:
            func.starts.add(start.group(1))
            continue
        measure = MEASURE.search(line)
        if measure:
            func.durations.add(measure.group(1))
            continue
        assigned = ASSIGN.match(line) or APPEND.match(line)
        if assigned and not ASSERT_START.search(line) and func.is_duration(assigned.group(2)):
            func.durations.add(assigned.group(1))
            continue
        call = ASSERT_START.search(line)
        if not call:
            continue
        kind = call.group(1)
        text = statement_from(lines, index, call.end() - 1)
        if is_ceiling(kind, split_args(text), func):
            found.append({'line': index + 1, 'func': func.name, 'assert': (kind + text).strip()[:160]})
    return found


def scan_tree(folders=None, root=ROOT):
    found = []
    for folder in folders or default_folders(root):
        folder = Path(folder)
        for path in sorted(folder.rglob('*.swift')):
            for item in scan_source(path.read_text(encoding='utf-8')):
                found.append({'file': f'{folder.parent.name}/{folder.name}/{path.relative_to(folder).as_posix()}', **item})
    return found


def key(item):
    return f'{item["file"]}::{item["func"]}'


def load_allowlist(path=ALLOWLIST):
    path = Path(path)
    return json.loads(path.read_text()) if path.exists() else {}


def compare(found, allowlist):
    """(new, stale): ceilings in tests the allowlist does not name, and listed tests that no longer have one."""
    keys = {key(item) for item in found}
    new = [item for item in found if key(item) not in allowlist]
    stale = sorted(name for name in allowlist if name not in keys)
    return new, stale


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    parser.add_argument('--write', metavar='FILE', help='write every ceiling found to this JSON file')
    parser.add_argument('--folder', action='append', help=argparse.SUPPRESS)
    parser.add_argument('--allowlist', default=str(ALLOWLIST), help=argparse.SUPPRESS)
    args = parser.parse_args(argv)
    found = scan_tree(args.folder)
    if args.write:
        out = Path(args.write)
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(json.dumps(found, indent=1) + '\n')
    allowlist = load_allowlist(args.allowlist)
    new, stale = compare(found, allowlist)
    print(f'{len(found)} wall-clock ceiling(s) in Swift tests; {len(allowlist)} test(s) on the allowlist; '
          f'{len(new)} not allowed; {len(stale)} stale allowlist entr{"y" if len(stale) == 1 else "ies"}.')
    for item in new[:20]:
        print(f'  not allowed: {item["file"]}:{item["line"]} {item["func"]}: {item["assert"][:100]}')
    if new:
        print('Prove "it did not wait" on state (a gate the test holds, an expectation), not on a clock. A real '
              'performance budget takes a ceiling at least 5x the local time, a comment naming the scaling bug, and an '
              'entry with that reason in scripts/test_clock_ceilings_allowlist.json (docs/testing.md, Waiting in tests).')
    for name in stale[:20]:
        print(f'  stale: {name} has no ceiling now; remove it from scripts/test_clock_ceilings_allowlist.json')
    return 1 if new or stale else 0


if __name__ == '__main__':
    sys.exit(main())
