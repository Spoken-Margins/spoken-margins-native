#!/usr/bin/env python3
"""Finds an accessibility identifier set on a bare SwiftUI container (#2898).

`.accessibilityIdentifier("x")` on a `VStack`, `HStack`, `Group`, `ViewThatFits`, `LazyVStack` or `Section` that is
not itself an accessibility element is copied onto every child and replaces the child's own identifier. A button
inside keeps its label but answers to "x". It broke eight scripted journeys at once (#2894): the playback header's
`playback.title` hid the Library chevron's neighbours, and `terms.screen` on a `ViewThatFits` hid Agree and Use iOS
Voice's own identifiers. `.accessibilityElement(children: .contain)` (or `.combine` or `.ignore`) anywhere in the
modifier chain makes the container an element, so its identifier stays on it.

  scripts/container_identifiers.py             check: fail on a row that is not in the baseline, or whose count of
                                               hidden child identifiers grew
  scripts/container_identifiers.py --list      every row with file, line and hidden child identifiers
  scripts/container_identifiers.py --update    tighten the baseline: drop fixed rows, lower counts. Never adds.

A row is a container identifier with no `.accessibilityElement` in its chain. Its `hidden` count is the number of
`.accessibilityIdentifier(` calls inside the container's braces, which the container's identifier overwrites. A row
with `hidden` 0 hides nothing today; the baseline holds those too, so adding an identified child to one fails here
instead of on a hosted journey.

A heuristic over source text, no compiler. It strips comments and string literals, walks back from the identifier
over the modifier chain to the view that starts it, and reads forward over the modifiers after it. A constant or ternary argument is a row too, named by its expression
after `=`. It misses an identifier set through a helper function, `@ViewBuilder` composition, a wrapper view or a
container returned by another function (a miss is a container this does not know is one), and a raw string
(`#"…"#`) can throw off the walk. Stdlib only, Python 3.9-compatible.
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BASELINE = ROOT / 'scripts' / 'container_identifiers_baseline.json'
SCAN_DIRS = ('App',)
SKIP_PARTS = ('Tests', 'UITests')  # test targets; their views are fixtures, not the app's screens
CONTAINERS = {'VStack', 'HStack', 'ZStack', 'Group', 'ViewThatFits', 'LazyVStack', 'LazyHStack', 'Section',
              'Grid', 'GridRow', 'LazyVGrid', 'LazyHGrid', 'ForEach', 'GeometryReader'}
IDENTIFIER = '.accessibilityIdentifier'
ELEMENT = '.accessibilityElement'
CLOSERS = {')': '(', '}': '{', ']': '['}
OPENERS = {v: k for k, v in CLOSERS.items()}


def blank_literals(text: str) -> str:
    """The same text with comments and string contents replaced by spaces (newlines and the quotes kept), so a brace
    or parenthesis inside a string or a comment never counts. Interpolations are blanked with the string. The
    identifier's own argument is blanked too; `identifier_at` reads it from the original text."""
    out = list(text)
    i, n = 0, len(text)

    def blank(a: int, b: int) -> None:
        for k in range(a, b):
            if out[k] != '\n':
                out[k] = ' '

    while i < n:
        two = text[i:i + 2]
        if two == '//':
            j = text.find('\n', i)
            j = n if j < 0 else j
            blank(i, j)
            i = j
        elif two == '/*':
            j = text.find('*/', i + 2)
            j = n if j < 0 else j + 2
            blank(i, j)
            i = j
        elif text[i] == '"':
            triple = text[i:i + 3] == '"""'
            j = i + (3 if triple else 1)
            depth = 0
            while j < n:
                c = text[j]
                if c == '\\' and j + 1 < n:
                    if text[j + 1] == '(':
                        depth += 1
                        j += 2
                        continue
                    j += 2
                    continue
                if depth:
                    if c == '(':
                        depth += 1
                    elif c == ')':
                        depth -= 1
                    j += 1
                    continue
                if triple and text[j:j + 3] == '"""':
                    j += 3
                    break
                if not triple and c == '"':
                    j += 1
                    break
                if not triple and c == '\n':
                    break  # an unterminated literal: stop at the line end rather than swallow the file
                j += 1
            blank(i + 1, max(i + 1, j - 1))
            i = j
        else:
            i += 1
    return ''.join(out)


def match_back(code: str, close: int) -> int:
    """The index of the opener for the closer at `close`, or -1."""
    stack = []
    for k in range(close, -1, -1):
        c = code[k]
        if c in CLOSERS:
            stack.append(CLOSERS[c])
        elif c in OPENERS:
            if not stack or stack.pop() != c:
                return -1
            if not stack:
                return k
    return -1


def match_forward(code: str, opener: int) -> int:
    """The index of the closer for the opener at `opener`, or -1."""
    stack = []
    for k in range(opener, len(code)):
        c = code[k]
        if c in OPENERS:
            stack.append(OPENERS[c])
        elif c in CLOSERS:
            if not stack or stack.pop() != c:
                return -1
            if not stack:
                return k
    return -1


def word_before(code: str, end: int):
    """(word, start) of the identifier ending just before `end` (whitespace skipped), or ('', end)."""
    k = end
    while k > 0 and code[k - 1] in ' \t\r\n':
        k -= 1
    stop = k
    while k > 0 and (code[k - 1].isalnum() or code[k - 1] == '_'):
        k -= 1
    return code[k:stop], k


def prev_char(code: str, end: int):
    k = end
    while k > 0 and code[k - 1] in ' \t\r\n':
        k -= 1
    return (code[k - 1], k - 1) if k > 0 else ('', -1)


def chain_before(code: str, dot: int):
    """Walks back from the `.` that starts a modifier to the view that starts the chain.
    Returns (base name, base start, modifier names before it, opening brace of the base's content or -1)."""
    modifiers = []
    pos = dot
    while True:
        ch, at = prev_char(code, pos)
        if ch not in CLOSERS:
            word, start = word_before(code, pos)
            return word, start, modifiers, -1  # a plain value (`Color.red`, `view`): nothing known about it
        opener = match_back(code, at)
        if opener < 0:
            return '', pos, modifiers, -1
        # `Section { } header: { }`: labelled trailing closures follow the first one; walk back to it.
        while ch == '}':
            colon, colon_at = prev_char(code, opener)
            if colon != ':':
                break
            label, label_start = word_before(code, colon_at)
            ch, at = prev_char(code, label_start)
            if not label or ch != '}':
                break
            opener = match_back(code, at)
            if opener < 0:
                return '', pos, modifiers, -1
        content_brace = opener if ch == '}' else -1
        # `Name(args) { ... }` or `.name(args) { ... }`: a trailing closure follows the parenthesis.
        if ch == '}':
            ch2, at2 = prev_char(code, opener)
            if ch2 == ')':
                opener2 = match_back(code, at2)
                name, start = word_before(code, opener2) if opener2 >= 0 else ('', opener)
            else:
                name, start = word_before(code, opener)
        elif ch == ')':
            name, start = word_before(code, opener)
        else:
            return '', pos, modifiers, -1  # a subscript or array literal
        if not name:
            return '', pos, modifiers, -1
        before, bat = prev_char(code, start)
        if before == '.':
            modifiers.append('.' + name)
            pos = bat
            continue
        return name, start, modifiers, content_brace


def modifiers_after(code: str, end: int):
    """The modifier names that follow position `end` in the same chain: `.a(...).b { ... }.c`."""
    names = []
    k = end
    n = len(code)
    while True:
        while k < n and code[k] in ' \t\r\n':
            k += 1
        if k >= n or code[k] != '.':
            return names, k
        j = k + 1
        while j < n and (code[j].isalnum() or code[j] == '_'):
            j += 1
        name = code[k:j]
        if j == k + 1:
            return names, k
        names.append(name)
        k = j
        while k < n:
            m = k
            while m < n and code[m] in ' \t\r\n':
                m += 1
            if m < n and code[m] in '({[' and code[m] != '[':
                close = match_forward(code, m)
                if close < 0:
                    return names, n
                k = close + 1
            else:
                break


def identifier_at(original: str, code: str, dot: int):
    """The string literal argument of `.accessibilityIdentifier("…")` starting at `dot`, with interpolations kept."""
    open_paren = dot + len(IDENTIFIER)
    if open_paren >= len(code) or code[open_paren] != '(':
        return None
    close = match_forward(code, open_paren)
    if close < 0:
        return None
    argument = original[open_paren + 1:close].strip()
    if len(argument) >= 2 and argument[0] == '"' and argument[-1] == '"':
        return argument[1:-1]
    # A constant or a ternary (`Self.sheetIdentifier`, `flag ? "a" : "b"`): the expression stands in for the name.
    return '=' + ' '.join(argument.split()) if argument else None


def scan_source(path: str, original: str):
    """Rows for one file: dicts with file, line, container, identifier, hidden."""
    code = blank_literals(original)
    rows = []
    at = 0
    while True:
        dot = code.find(IDENTIFIER, at)
        if dot < 0:
            return rows
        at = dot + len(IDENTIFIER)
        identifier = identifier_at(original, code, dot)
        if identifier is None:
            continue
        base, start, before, brace = chain_before(code, dot)
        if base not in CONTAINERS or brace < 0:
            continue
        open_paren = dot + len(IDENTIFIER)
        after, _ = modifiers_after(code, match_forward(code, open_paren) + 1)
        if ELEMENT in before or ELEMENT in after:
            continue
        close = match_forward(code, brace)
        hidden = code.count(IDENTIFIER + '(', brace, close) if close > brace else 0
        same = sum(1 for row in rows if row['identifier'] == identifier)
        rows.append({'file': path, 'line': original.count('\n', 0, dot) + 1, 'container': base,
                     'identifier': identifier, 'hidden': hidden, 'n': same + 1})


def scan_tree(root: Path = ROOT):
    rows = []
    for scan_dir in SCAN_DIRS:
        for path in sorted((root / scan_dir).rglob('*.swift')):
            relative = path.relative_to(root).as_posix()
            if any(part.endswith(SKIP_PARTS) for part in path.relative_to(root).parts):
                continue
            rows.extend(scan_source(relative, path.read_text(encoding='utf-8', errors='replace')))
    return rows


def key(row) -> str:
    """File and identifier, plus `#2`, `#3` for a second container in the same file with the same identifier (an
    if/else pair), so a new twin is not waved through on its sibling's baseline entry."""
    return f"{row['file']}::{row['identifier']}" + (f"#{row['n']}" if row.get('n', 1) > 1 else '')


def load_baseline(path: Path = BASELINE) -> dict:
    if not path.exists():
        return {}
    return {entry['key']: entry for entry in json.loads(path.read_text())['rows']}


def problems(rows, baseline) -> list:
    """What fails the check: a row not in the baseline, or one hiding more child identifiers than it did."""
    found = []
    for row in rows:
        known = baseline.get(key(row))
        if known is None:
            found.append(f"{row['file']}:{row['line']}: `{row['identifier']}` is on a bare {row['container']}, so it "
                         f"replaces {row['hidden']} child identifier(s). Add `.accessibilityElement(children: .contain)` "
                         f"to it, or give the identifier to the one child that needs it (#2898).")
        elif row['hidden'] > known['hidden']:
            found.append(f"{row['file']}:{row['line']}: `{row['identifier']}` now hides {row['hidden']} child "
                         f"identifier(s), up from {known['hidden']}. The container's identifier overwrites them: add "
                         f"`.accessibilityElement(children: .contain)` to the container (#2898).")
    return found


def render_baseline(rows, old: dict) -> str:
    entries = []
    for row in sorted(rows, key=key):
        entries.append({'key': key(row), 'container': row['container'], 'hidden': row['hidden'],
                        'why': old.get(key(row), {}).get('why', 'known at #2898; hides nothing a journey reads yet')})
    return json.dumps({'about': 'Bare-container accessibility identifiers known when the guard landed (#2898). '
                                'scripts/container_identifiers.py fails on a row not listed here or one that hides '
                                'more child identifiers. --update only removes rows and lowers counts.',
                       'rows': entries}, indent=1) + '\n'


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    parser.add_argument('--list', action='store_true')
    parser.add_argument('--update', action='store_true')
    args = parser.parse_args(argv)
    rows = scan_tree()
    baseline = load_baseline()
    if args.list:
        for row in rows:
            print(f"{row['file']}:{row['line']}  {row['container']}  {row['identifier']}  hides {row['hidden']}")
        return 0
    if args.update:
        kept = [dict(row, hidden=min(row['hidden'], baseline[key(row)]['hidden'])) for row in rows if key(row) in baseline]
        BASELINE.write_text(render_baseline(kept, baseline))
        print(f'baseline: {len(kept)} rows (was {len(baseline)})')
        return 0
    found = problems(rows, baseline)
    for line in found:
        print(line, file=sys.stderr)
    stale = sorted(set(baseline) - {key(row) for row in rows})
    if stale and not found:
        print(f'note: {len(stale)} baseline row(s) are fixed; run scripts/container_identifiers.py --update')
    return 1 if found else 0


if __name__ == '__main__':
    sys.exit(main())
