#!/usr/bin/env python3
"""Fixed-count poll loops in the app tests (#4131).

An app test that waits for real work (a packet export, a render, a download, a player reaching a time) with
`for _ in 0..<100 where ... { try await Task.sleep(for: .milliseconds(20)) }` has a two-second deadline written as a
loop count. On a loaded runner (load average above 300 in #4130's lane run) the work is slow, the loop runs out, and
the test fails though the code is fine. Such a wait uses `pollUntil` (App/SpokenMarginsAppTests/PollUntil.swift), which
takes a deadline in seconds, or a `while ContinuousClock.now < deadline` loop.

  scripts/app_test_poll_loops.py              list the loops (counts, then the first few); exit 1 if there are any
  scripts/app_test_poll_loops.py --write F    also write every loop, with what it waits for, to the JSON file F
                                              (use artifacts/app-test-poll-loops.json; artifacts/ is git-ignored)

A loop is flagged when it counts `for _ in 0..<N` (with or without a `where` clause) and its body calls `Task.sleep`.
A loop whose count is itself the point (it runs a fixed number of ticks and does not wait for anything) carries the
comment `// fixed-count ok: <why>` on its `for` line or the line above it, and is not flagged. Loops that only
`Task.yield()` are listed as informational (they spend no time, so they don't miss a deadline) and are not flagged.
"""
import argparse
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TESTS = ROOT / 'App' / 'SpokenMarginsAppTests'

FOR = re.compile(r'^(?P<indent>\s*)for _ in 0\.\.<(?P<count>[\d_]+)(?P<where>\s+where\s+(?P<cond>.+?))?\s*\{(?P<rest>.*)$')
SLEEP = re.compile(r'Task\.sleep\(')
YIELD = re.compile(r'Task\.yield\(\)')
REASON = re.compile(r'//\s*fixed-count ok:\s*\S')
# the duration of one tick: `.milliseconds(20)`, `.seconds(1)`, `nanoseconds: 10_000_000`
TICK = re.compile(r'Task\.sleep\((?:for:\s*\.(?P<unit>milliseconds|seconds|microseconds)\((?P<n>[\d_.]+)\)|nanoseconds:\s*(?P<ns>[\d_]+))')


def body_of(lines, index, match):
    """The loop's text from its opening line to its closing brace: one line if it closes on the same line, else
    every line down to the first `}` at the `for` line's indent."""
    first = lines[index]
    if match.group('rest').rstrip().endswith('}'):
        return first
    indent = match.group('indent')
    out = [first]
    for line in lines[index + 1:]:
        out.append(line)
        if line.startswith(indent + '}') and not line.startswith(indent + ' '):
            break
    return '\n'.join(out)


def tick_ms(text):
    found = TICK.search(text)
    if not found:
        return None
    if found.group('ns'):
        return int(found.group('ns').replace('_', '')) / 1_000_000
    n = float(found.group('n').replace('_', ''))
    return n * {'milliseconds': 1, 'seconds': 1000, 'microseconds': 0.001}[found.group('unit')]


def scan_source(source):
    """Every counted loop that sleeps (kind 'sleep') or only yields (kind 'yield') in `source`, in order."""
    lines = source.split('\n')
    loops = []
    for index, line in enumerate(lines):
        match = FOR.match(line)
        if not match:
            continue
        text = body_of(lines, index, match)
        if SLEEP.search(text):
            kind = 'sleep'
        elif YIELD.search(text):
            kind = 'yield'
        else:
            continue
        count = int(match.group('count').replace('_', ''))
        tick = tick_ms(text)
        reason = REASON.search(line) or (index > 0 and REASON.search(lines[index - 1]))
        loops.append({
            'line': index + 1, 'kind': kind, 'count': count,
            'waits_for': (match.group('cond') or 'a count of ticks, no condition').strip(),
            'deadline_s': round(count * tick / 1000, 2) if tick else None,
            'exempt': bool(reason),
        })
    return loops


def scan_tree(folder=TESTS):
    found = []
    for path in sorted(Path(folder).rglob('*.swift')):
        for loop in scan_source(path.read_text(encoding='utf-8')):
            found.append({'file': path.relative_to(folder).as_posix(), **loop})
    return found


def flagged(loops):
    return [loop for loop in loops if loop['kind'] == 'sleep' and not loop['exempt']]


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    parser.add_argument('--write', metavar='FILE', help='write every loop to this JSON file')
    parser.add_argument('--folder', default=str(TESTS), help=argparse.SUPPRESS)
    args = parser.parse_args(argv)
    loops = scan_tree(args.folder)
    bad = flagged(loops)
    if args.write:
        out = Path(args.write)
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(json.dumps(loops, indent=1) + '\n')
    files = sorted({loop['file'] for loop in bad})
    print(f'{len(bad)} fixed-count poll loop(s) in {len(files)} file(s); '
          f'{sum(loop["kind"] == "yield" for loop in loops)} yield-only (not flagged); '
          f'{sum(loop["exempt"] for loop in loops)} marked `fixed-count ok`.')
    for loop in bad[:10]:
        print(f'  {loop["file"]}:{loop["line"]}  {loop["count"]} ticks'
              f'{" = " + str(loop["deadline_s"]) + " s" if loop["deadline_s"] else ""}  waits for: {loop["waits_for"]}')
    if bad:
        print('Wait with pollUntil { ... } (App/SpokenMarginsAppTests/PollUntil.swift) or a ContinuousClock deadline, '
              'not a tick count (#4131).')
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())
