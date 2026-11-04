#!/usr/bin/env python3
"""Guard for ordered store requests started from a separate Task (#3335, found while fixing #3331).

`StoreReader.readInOrder` is `async`, so it hops off the caller's actor before it takes its place in line. Two
`Task { await readInOrder(…) }` blocks started one after the other can therefore take their places in either order,
and the older request's value is written last. `StoreReader.enqueueInOrder` takes the place before it returns; a caller
that starts a request from a Task takes the place first and awaits the task it gets back.

  scripts/ordered_store_requests.py              check: fail on a `readInOrder(` inside a Task closure that is not marked
  scripts/ordered_store_requests.py --inventory  print every such call, marked or not, with its reason

A call is allowed with a comment on its own line or on the comment lines directly above it:

    // ordered-ok: <why the order of this call against its neighbours does not matter, or is kept by awaiting>

Use it for a call that is awaited in sequence inside one flow, or that only reads. The reason is printed by --inventory.

Known blind spots: this sees the direct shape only (`Task`, `Task.detached`, `.task`, `addTask`), and not a Task that
calls a helper which wraps `readInOrder` (such as the audio-preparation pass's `preparationWrite`), whose callers run
in sequence inside one pass. A stale `ordered-ok` marker is not reported. A `Task { await model.someAsyncFunction() }` whose function calls
`readInOrder` inside is not found; make that function take its place with `enqueueInOrder` before it returns (see
`skipAudioPreparationJob`) so the Task is not what orders it.
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCAN_DIRS = ('App', 'Packages/SessionKit/Sources')
CALL = re.compile(r'\breadInOrder\s*[(<]')
# `Task {`, `Task<Void, Never> {`, `Task(priority: .utility) {`, `Task.detached(priority: f(x)) {`, `.task {`, `.task(id: x) {`
# and `group.addTask {`; the text before the brace may also carry a capture list or `in` only after the brace.
TASK_OPEN = re.compile(r'(?:\bTask(?:\.detached)?(?:\s*<[^<>{}]*>)?|\.(?:task|addTask|addTaskUnlessCancelled))(?:\s*\([^{}]*\))?\s*$')
MARKER = re.compile(r'//\s*ordered-ok:\s*(\S.*)')


def blank_comments_and_strings(text: str) -> str:
    """The text with comments and string literals replaced by spaces, keeping every newline and offset."""
    out = list(text)
    i, n = 0, len(text)
    while i < n:
        two = text[i:i + 2]
        if two == '//':
            j = text.find('\n', i)
            j = n if j < 0 else j
            for k in range(i, j):
                out[k] = ' '
            i = j
        elif two == '/*':
            j = text.find('*/', i + 2)
            j = n if j < 0 else j + 2
            for k in range(i, j):
                if text[k] != '\n':
                    out[k] = ' '
            i = j
        elif text[i] == '"':
            triple = text.startswith('"""', i)
            end = '"""' if triple else '"'
            j = i + len(end)
            while j < n and not text.startswith(end, j):
                j += 2 if text[j] == '\\' else 1
            j = min(n, j + len(end))
            for k in range(i, j):
                if text[k] != '\n':
                    out[k] = ' '
            i = j
        else:
            i += 1
    return ''.join(out)


def task_closure_calls(text: str) -> list[int]:
    """Offsets of `readInOrder` calls that sit inside a Task closure, however deep."""
    code = blank_comments_and_strings(text)
    stack: list[bool] = []  # one entry per open brace: is it a Task closure's?
    calls = []
    call_offsets = {m.start() for m in CALL.finditer(code)}
    for i, ch in enumerate(code):
        if ch == '{':
            stack.append(bool(TASK_OPEN.search(code[max(0, i - 120):i])))
        elif ch == '}':
            if stack:
                stack.pop()
        elif i in call_offsets and any(stack):
            calls.append(i)
    return calls


def marker_reason(lines: list[str], line: int) -> str | None:
    """The `ordered-ok` reason on the call's own line, else on the comment-only lines directly above it."""
    found = MARKER.search(lines[line])
    above = line - 1
    while not found and above >= 0 and lines[above].strip().startswith('//'):
        found = MARKER.search(lines[above])
        above -= 1
    return found.group(1).strip() if found else None


def scan(root: Path = ROOT) -> list[dict]:
    rows = []
    for base in SCAN_DIRS:
        for path in sorted((root / base).rglob('*.swift')):
            rel = path.relative_to(root).as_posix()
            if any(part.endswith('Tests') for part in path.relative_to(root).parts):
                continue
            text = path.read_text(encoding='utf-8', errors='replace')
            lines = text.split('\n')
            for offset in task_closure_calls(text):
                line = text.count('\n', 0, offset)
                reason = marker_reason(lines, line)
                rows.append({'file': rel, 'line': line + 1, 'reason': reason, 'source': lines[line].strip()})
    return rows


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--inventory', action='store_true', help='print every call inside a Task closure')
    args = parser.parse_args(argv)
    rows = scan()
    unmarked = [row for row in rows if not row['reason']]
    if args.inventory:
        for row in rows:
            status = f"ordered-ok: {row['reason']}" if row['reason'] else 'UNMARKED'
            print(f"{row['file']}:{row['line']}: {status}\n    {row['source']}")
        print(f"{len(rows)} readInOrder call(s) inside a Task closure; {len(unmarked)} unmarked")
        return 0
    if unmarked:
        for row in unmarked:
            print(f"{row['file']}:{row['line']}: readInOrder inside a Task closure\n    {row['source']}", file=sys.stderr)
        print(
            f"\n{len(unmarked)} call(s) take their place in line only after the Task has hopped, so two of them can run "
            "in either order (#3335). Take the place first with StoreReader.enqueueInOrder, before the Task starts, "
            "and await the task it returns; or, if the order against its neighbours does not matter, add "
            "`// ordered-ok: <why>` on or above the call.", file=sys.stderr)
        return 1
    print(f"ordered store requests: ok ({len(rows)} marked)")
    return 0


if __name__ == '__main__':
    sys.exit(main())
