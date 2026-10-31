#!/usr/bin/env python3
"""Finds "should the source resume" state declared outside its owner, kept as a ratchet (#3032).

Every "playback did or didn't resume" bug (after a system interruption, a Margin capture, a hands-free capture, a
relaunch, a Live Activity or Watch action) is one instance of the same flaw: the decision whether the source resumes,
and from where, is computed in several places, each with its own flag, and they disagree at the edges. #1705 took five
audit rounds because each fix touched one copy. This scanner is the inventory of those copies and the guard that keeps
a new one out. The end state is one SessionKit type that owns the decision (the audit's "Done when"); until it exists
the baseline names every remaining instance, and it only shrinks.

  scripts/resume_owners.py             check: fail on a declaration that is not in the baseline, or whose count of
                                       writes grew
  scripts/resume_owners.py --list      every declaration with file, line and write count
  scripts/resume_owners.py --update    tighten the baseline: drop fixed rows, lower counts. Never adds.

A row is a declaration (`var`, `let`, `func`, `struct`, `enum`, `class`, `actor`, `protocol`, `typealias`, `case`, or
a `func` parameter such as `interruptionEnded(shouldResume:)`) in a
production Swift file under App/ or Packages/*/Sources whose name contains one of RESUME_NAMES. A file listed in
OWNING_FILES is the owner and is not scanned; it is empty until the owning type lands. A row's `writes` is the number
of assignments to that name in the same file (the audit counted `shouldResumeAfterInterruption` written in eight
places), so a new write site in a file that already has the flag fails too.

A heuristic over source text, no compiler. It strips comments and string literals first. It misses a flag with a
name outside RESUME_NAMES, a flag passed only as a parameter or closure argument, and a write through another name.
Add a name to RESUME_NAMES when a new copy turns up under it. Stdlib only, Python 3.9-compatible.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BASELINE = ROOT / 'scripts' / 'resume_owners_baseline.json'

# Names that carry a resume decision (the audit's inventory, #3032). Matched anywhere in a declared name, ignoring case, so
# `shouldResumeAfterInterruption` and `lastShouldResume` are both rows.
RESUME_NAMES = (
    'shouldResume',
    'pendingResume',
    'resumePolicy',
    'priorPhase',
    'rejoinAttempted',
    'pendingInterjectionPause',
    'systemPause',
    'pendingPlaybackPosition',
    'recordingOnFinishedSource',
    'playbackStartAttempt', 'playbackStartPending', 'playbackStartDeadline',
)
# Repo-relative paths of the type that owns the decision. Nothing is exempt until #3032's one-owner type exists.
OWNING_FILES: tuple = ()
SCAN_DIRS = ('App', 'Packages')
SKIP_PARTS = ('Tests', 'UITests', '.build', 'Fixtures')  # test targets and build output are not production code
DECLARATION = re.compile(r'\b(?:var|let|func|struct|enum|class|actor|protocol|typealias|case)\s+(`?\w+`?)')
# A function's parameter, by label or by internal name: `func interruptionEnded(shouldResume: Bool)`. One level of
# parentheses inside the list (a closure type) is enough for a signature.
SIGNATURE = re.compile(r'\bfunc\s+`?\w+`?\s*(?:<[^>]*>)?\s*\(((?:[^()]|\([^()]*\))*)\)')
PARAMETER = re.compile(r'(?:^|,)\s*(\w+)(?:\s+(\w+))?\s*:')


def blank_literals(text: str) -> str:
    """The text with comments and string literals blanked to spaces, newlines kept, so line numbers still match."""
    out = []
    i, n = 0, len(text)
    while i < n:
        two = text[i:i + 2]
        if two == '//':
            while i < n and text[i] != '\n':
                out.append(' ')
                i += 1
        elif two == '/*':
            depth = 0
            while i < n:
                if text[i:i + 2] == '/*':
                    depth += 1
                    out.append('  ')
                    i += 2
                elif text[i:i + 2] == '*/':
                    depth -= 1
                    out.append('  ')
                    i += 2
                    if depth == 0:
                        break
                else:
                    out.append('\n' if text[i] == '\n' else ' ')
                    i += 1
        elif text[i] == '"':
            triple = text[i:i + 3] == '"""'
            end = '"""' if triple else '"'
            out.append(' ' * len(end))
            i += len(end)
            while i < n and text[i:i + len(end)] != end:
                if text[i] == '\\' and not triple:
                    out.append('  ')
                    i += 2
                    continue
                if text[i] == '\n':
                    if not triple:
                        break  # an unterminated string ends at the line, so one stray quote cannot eat the file
                    out.append('\n')
                else:
                    out.append(' ')
                i += 1
            if text[i:i + len(end)] == end:
                out.append(' ' * len(end))
                i += len(end)
        else:
            out.append(text[i])
            i += 1
    return ''.join(out)


def carries_resume(name: str) -> bool:
    lowered = name.lower()
    return any(part.lower() in lowered for part in RESUME_NAMES)


def scan_source(path: str, original: str):
    """Rows for one file: one per declared name, with its first line and the writes to it in this file."""
    code = blank_literals(original)
    rows = {}
    for match in DECLARATION.finditer(code):
        name = match.group(1).strip('`')
        if not carries_resume(name):
            continue
        line = code.count('\n', 0, match.start()) + 1
        row = rows.setdefault(name, {'file': path, 'name': name, 'line': line, 'decls': 0, 'writes': 0})
        row['decls'] += 1
    for signature in SIGNATURE.finditer(code):
        line = code.count('\n', 0, signature.start()) + 1
        for parameter in PARAMETER.finditer(signature.group(1)):
            for name in {n for n in parameter.groups() if n}:
                if carries_resume(name):
                    row = rows.setdefault(name, {'file': path, 'name': name, 'line': line, 'decls': 0, 'writes': 0})
                    row['decls'] += 1
    for name, row in rows.items():
        # `name = x`, `self.name = x`, `state.name = x`, `name += x`; not `name == x`, `name != x`, `var name: T = x` (a declaration).
        writes = re.compile(r'(?<!\w)' + re.escape(name) + r'\s*(?:[-+*/|&]?=)(?!=)')
        decl_inits = re.compile(r'\b(?:var|let)\s+`?' + re.escape(name) + r'`?\s*(?::[^=\n{]*)?=(?!=)')
        row['writes'] = max(0, len(writes.findall(code)) - len(decl_inits.findall(code)))
    return sorted(rows.values(), key=lambda r: r['name'])


def scan_tree(root: Path = ROOT):
    rows = []
    for top in SCAN_DIRS:
        for file in sorted((root / top).rglob('*.swift')):
            relative = file.relative_to(root).as_posix()
            if any(part in SKIP_PARTS or part.endswith('Tests') for part in file.relative_to(root).parts):
                continue
            if relative in OWNING_FILES:
                continue
            rows.extend(scan_source(relative, file.read_text(encoding='utf-8', errors='replace')))
    return rows


def key(row) -> str:
    return f"{row['file']}::{row['name']}"


def load_baseline(path: Path = BASELINE) -> dict:
    if not path.exists():
        return {}
    return {entry['key']: entry for entry in json.loads(path.read_text())['rows']}


def problems(rows, baseline) -> list:
    """What fails the check: a declaration not in the baseline, or one with more write sites than it had."""
    found = []
    for row in rows:
        known = baseline.get(key(row))
        if known is None:
            found.append(f"{row['file']}:{row['line']}: `{row['name']}` is a new copy of the resume decision. Ask the "
                         f"one owner (#3032) whether the source resumes instead of keeping a flag of your own; if "
                         f"this really is the owner, list its file in OWNING_FILES in scripts/resume_owners.py.")
        elif row['writes'] > known['writes']:
            found.append(f"{row['file']}:{row['line']}: `{row['name']}` is written in {row['writes']} places, up from "
                         f"{known['writes']}. Another write site is another place the resume decision can disagree "
                         f"(#3032).")
    return found


def render_baseline(rows, old: dict) -> str:
    entries = []
    for row in sorted(rows, key=key):
        entries.append({'key': key(row), 'writes': row['writes'],
                        'why': old.get(key(row), {}).get('why', 'known when the guard landed (#3032); retired by the one-owner type')})
    return json.dumps({'about': 'Resume-decision state known when the guard landed (#3032). scripts/resume_owners.py '
                                'fails on a declaration not listed here or one written in more places. --update only '
                                'removes rows and lowers counts.',
                       'rows': entries}, indent=1) + '\n'


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    parser.add_argument('--list', action='store_true')
    parser.add_argument('--update', action='store_true')
    parser.add_argument('--seed', action='store_true', help='write today\'s rows as the first baseline (used once)')
    args = parser.parse_args(argv)
    rows = scan_tree()
    baseline = load_baseline()
    if args.list:
        for row in rows:
            print(f"{row['file']}:{row['line']}  {row['name']}  writes {row['writes']}")
        print(f'{len(rows)} declarations in {len({r["file"] for r in rows})} files')
        return 0
    if args.seed:
        BASELINE.write_text(render_baseline(rows, baseline))
        print(f'baseline: {len(rows)} rows')
        return 0
    if args.update:
        kept = [dict(row, writes=min(row['writes'], baseline[key(row)]['writes'])) for row in rows if key(row) in baseline]
        BASELINE.write_text(render_baseline(kept, baseline))
        print(f'baseline: {len(kept)} rows (was {len(baseline)})')
        return 0
    found = problems(rows, baseline)
    for line in found:
        print(line, file=sys.stderr)
    stale = sorted(set(baseline) - {key(row) for row in rows})
    if stale and not found:
        print(f'note: {len(stale)} baseline row(s) are fixed; run scripts/resume_owners.py --update')
    return 1 if found else 0


if __name__ == '__main__':
    sys.exit(main())
