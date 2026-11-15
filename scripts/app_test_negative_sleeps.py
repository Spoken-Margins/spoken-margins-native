#!/usr/bin/env python3
"""Fixed sleeps before "must not happen" assertions in the app and UI tests (#4313).

A test that sleeps a fixed time and then asserts that something did not happen (`XCTAssertNil(model.marginMoment)`,
`XCTAssertEqual(failures, [])`, "the sheet closed by itself") passes whenever the thing it guards against is slower than
the sleep. On a loaded runner that is often, so a broken build goes green. Such a test waits on the signal that would
have caused the event instead: the task that would have done it finishing, a counter reaching the point after which it
would have happened, a clock that has visibly advanced past it (#3714, #4313).

  scripts/app_test_negative_sleeps.py              list the sleeps (count, then the first few); exit 1 on a new one
  scripts/app_test_negative_sleeps.py --write F    also write every sleep found to the JSON file F
                                                   (use artifacts/app-test-negative-sleeps.json; artifacts/ is git-ignored)
  scripts/app_test_negative_sleeps.py --update     shrink the baseline to what is still found (never adds or raises a test)
  scripts/app_test_negative_sleeps.py --update --allow-new
                                                   list everything found; only when the scan itself is widened, and
                                                   say so in the PR, since it is the one way the baseline grows

A sleep is flagged when it is a statement of its own (`try await Task.sleep(...)`, `Thread.sleep(...)`, `usleep(...)`,
`RunLoop.main.run(until:)`, `_ = XCTWaiter().wait(...)`, a clock's `sleep`) and
the run of assertions right after it (blank and comment lines skipped) holds a negative one: `XCTAssertFalse`,
`XCTAssertNil`, `XCTAssertEqual(x, [])` (or `[:]`, `0`, `nil`, `false`, `""`, either way round), `XCTAssertTrue(x.isEmpty)`,
or any assertion whose message says "not", "no", "never", "nothing", "by itself", "still" or a word ending in "n't".
A sleep that is itself the point (the test claims something holds for that long, and no signal marks the end) carries
`// fixed-sleep ok: <why>` on its line or in the comment lines just above it, and is not flagged.
The sleeps that were there when the guard came in are listed per test in scripts/app_test_negative_sleeps_baseline.json;
a test may keep at most its listed count, and a listed test that no longer has them fails until --update drops it.
"""
import argparse
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FOLDERS = (ROOT / 'App' / 'SpokenMarginsAppTests', ROOT / 'App' / 'SpokenMarginsAppUITests')
BASELINE = ROOT / 'scripts' / 'app_test_negative_sleeps_baseline.json'

# A wait of fixed length: Task, Thread, clock and C sleeps, a run loop run for a while, and an XCTWaiter wait (which
# ends at its timeout when nothing fulfils it). `_ =` and `try?` in front are allowed.
SLEEP = re.compile(r'^\s*(?:_\s*=\s*)?(?:try\??\s+)?(?:await\s+)?'
                   r'(?:Task\.sleep\(|Thread\.sleep\(|usleep\(|sleep\(|\w*[Cc]lock(?:\(\))?\.sleep\('
                   r'|RunLoop\.\w+\.run\(until|XCTWaiter(?:\(\))?\.wait\()')
ASSERT = re.compile(r'^(?:XCTAssert|XCTFail)')
NEGATIVE = re.compile(
    r'XCTAssertFalse\(|XCTAssertNil\('
    r'|XCTAssertEqual\(.*,\s*(?:\[\]|\[:\]|0|nil|false|"")\s*[,)]'
    r'|XCTAssertEqual\(\s*(?:\[\]|\[:\])\s*,'
    r'|XCTAssert(?:True)?\(.*\.isEmpty\b')
NEGATIVE_MESSAGE = re.compile(
    r'XCTAssert\w*\(.*"[^"]*(?:\b(?:must not|not|no|never|nothing|by itself|no longer|still)\b|n\'t\b)', re.I)
REASON = re.compile(r'//\s*fixed-sleep ok:\s*\S')
FUNC = re.compile(r'\bfunc\s+(\w+)\s*[(<]')


def assertions_after(lines, index):
    """The run of assertion lines right after line `index`, skipping blank and comment lines; stops at other code."""
    run = []
    for line in lines[index + 1:]:
        text = line.strip()
        if not text or text.startswith('//'):
            continue
        if not ASSERT.match(text):
            break
        run.append(text)
    return run


def has_reason(lines, index):
    """`// fixed-sleep ok:` on the sleep's line or in the unbroken comment block just above it."""
    if REASON.search(lines[index]):
        return True
    for line in reversed(lines[:index]):
        text = line.strip()
        if not text.startswith('//'):
            return False
        if REASON.search(text):
            return True
    return False


def enclosing_func(lines, index):
    for line in reversed(lines[:index]):
        found = FUNC.search(line)
        if found:
            return found.group(1)
    return '?'


def scan_source(source):
    """Every sleep statement followed by a negative assertion in `source`, in order."""
    lines = source.split('\n')
    found = []
    for index, line in enumerate(lines):
        if not SLEEP.match(line):
            continue
        negative = [text for text in assertions_after(lines, index) if NEGATIVE.search(text) or NEGATIVE_MESSAGE.search(text)]
        if not negative:
            continue
        found.append({'line': index + 1, 'func': enclosing_func(lines, index), 'sleep': line.strip(),
                      'asserts': negative[0], 'exempt': has_reason(lines, index)})
    return found


def scan_tree(folders=FOLDERS):
    found = []
    for folder in folders:
        folder = Path(folder)
        for path in sorted(folder.rglob('*.swift')):
            for item in scan_source(path.read_text(encoding='utf-8')):
                found.append({'file': f'{folder.name}/{path.relative_to(folder).as_posix()}', **item})
    return found


def flagged(found):
    return [item for item in found if not item['exempt']]


def per_test(items):
    counts = {}
    for item in items:
        key = f'{item["file"]}::{item["func"]}'
        counts[key] = counts.get(key, 0) + 1
    return dict(sorted(counts.items()))


def compare(found, baseline):
    """(new, stale): sleeps beyond a test's listed count, and listed tests that now have fewer than their count."""
    counts = per_test(flagged(found))
    new = [item for item in flagged(found)
           if counts[f'{item["file"]}::{item["func"]}'] > baseline.get(f'{item["file"]}::{item["func"]}', 0)]
    stale = sorted(key for key, listed in baseline.items() if counts.get(key, 0) < listed)
    return new, stale


def load_baseline(path=BASELINE):
    path = Path(path)
    return json.loads(path.read_text()) if path.exists() else {}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    parser.add_argument('--write', metavar='FILE', help='write every sleep found to this JSON file')
    parser.add_argument('--update', action='store_true', help='shrink the baseline to what is still found')
    parser.add_argument('--allow-new', action='store_true', help=argparse.SUPPRESS)  # with --update: list new ones too
    parser.add_argument('--folder', action='append', help=argparse.SUPPRESS)
    parser.add_argument('--baseline', default=str(BASELINE), help=argparse.SUPPRESS)
    args = parser.parse_args(argv)
    found = scan_tree(args.folder or FOLDERS)
    if args.write:
        out = Path(args.write)
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(json.dumps(found, indent=1) + '\n')
    if args.update:
        # Only ever shrinks: a test keeps the smaller of its listed and found counts, and a test not listed stays out.
        listed = load_baseline(args.baseline)
        counts = per_test(flagged(found))
        kept = dict(counts) if args.allow_new else {key: min(n, counts[key]) for key, n in listed.items() if counts.get(key)}
        Path(args.baseline).write_text(json.dumps(dict(sorted(kept.items())), indent=1) + '\n')
    baseline = load_baseline(args.baseline)
    new, stale = compare(found, baseline)
    print(f'{len(flagged(found))} fixed sleep(s) before a negative assertion; {sum(baseline.values())} listed in the '
          f'baseline; {sum(item["exempt"] for item in found)} marked `fixed-sleep ok`; {len(new)} new; {len(stale)} stale.')
    for item in new[:10]:
        print(f'  new: {item["file"]}:{item["line"]} {item["func"]}: {item["sleep"]} then {item["asserts"][:80]}')
    if new:
        print('Wait for the signal that would have caused the event (a task finishing, a counter, a clock that advanced), '
              'not a fixed time; a sleep that is the point carries `// fixed-sleep ok: <why>` (#4313).')
    for key in stale[:10]:
        print(f'  stale: {key} has fewer than its listed count; run scripts/app_test_negative_sleeps.py --update')
    return 1 if new or stale else 0


if __name__ == '__main__':
    sys.exit(main())
