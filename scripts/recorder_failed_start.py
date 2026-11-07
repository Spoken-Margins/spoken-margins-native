#!/usr/bin/env python3
"""Guard: a recorder whose start failed is stopped before it is let go (#3633).

`AVAudioRecorder.prepareToRecord()` (and a `record()` that gets part way) starts the recorder's audio queue. When
`record()` then returns false and the code throws, the last reference goes with the throw. Freed without `stop()`,
the queue's next input callback reads the freed recorder (`AudioRecorderAQInputCallback` -> `objc_loadWeak`) and
the app crashes. The owner hit it tapping record in the app while playing over AirPlay to a HomePod (build 36).

The scan finds every `guard ... .record() else {` in app and package sources and makes its else block call
`.stop()`. Fixes go in the else block itself, so a reader sees the stop next to the failure.

  scripts/recorder_failed_start.py   exit 1 and print each row

Blind spots: an `if !recorder.record()` or a stored result checked later, and a recorder started some other way
(AVAudioEngine taps have their own failure path). Stdlib only, Python 3.9-compatible.
"""
from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
GUARD = re.compile(r'\bguard\b[^\n{]*\.record\(\)\s*else\s*\{')


def tree_sources():
    out = subprocess.run(['git', 'ls-files', 'App', 'Packages'], cwd=ROOT, capture_output=True, text=True,
                         check=True).stdout.split()
    for path in out:
        if path.endswith('.swift') and '/Tests/' not in path and 'UITests' not in path:
            yield path, (ROOT / path).read_text(encoding='utf-8')


def else_block(source, open_brace):
    depth = 0
    for i in range(open_brace, len(source)):
        if source[i] == '{':
            depth += 1
        elif source[i] == '}':
            depth -= 1
            if depth == 0:
                return source[open_brace + 1:i]
    return source[open_brace + 1:]


def scan(sources):
    rows = []
    for path, source in sources:
        for match in GUARD.finditer(source):
            body = else_block(source, match.end() - 1)
            if not re.search(r'\.stop\(\)', body):
                line = source.count('\n', 0, match.start()) + 1
                rows.append((path, line))
    return rows


def main():
    rows = scan(tree_sources())
    for path, line in rows:
        print(f'{path}:{line}: a failed record() throws without stop(); the running audio queue then reads the '
              f'freed recorder (#3633). Call stop() in the else block.')
    return 1 if rows else 0


if __name__ == '__main__':
    sys.exit(main())
