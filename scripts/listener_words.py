#!/usr/bin/env python3
"""Guard: the word "item" is ours, not the listener's (#3599).

"Item" is the internal word for anything in the Library. A listener knows episodes, articles, PDFs and books. The
owner met "Skip to the item" on the Now screen in Build 36 and said: "the user is not going to know what an item is."

This scan reads the app's and SessionKit's Swift sources (not tests) and finds every string literal that holds the
word "item" or "items" on its own (so `itemId`, `ItemRow` and `"items.json"`-style names don't count). Each literal is
sorted into one of three kinds:

  words        what a listener reads (a label, a title, a sentence)
  voiceover    what VoiceOver reads (accessibilityLabel, Hint, Value)
  identifier   an accessibility identifier, a log or diagnostic line, an assertion message, or a lone
               identifier-shaped token with no spaces ("item.lastFailure")

Identifiers and logs stay: the rule excludes them, so they need no list. `words` and `voiceover` literals are the
baseline in scripts/listener_words_baseline.json, the inventory the replacement slices (#3599, step 3) work down.
A new listener-facing literal with "item" fails the check; a replaced one leaves the baseline with --update.

  scripts/listener_words.py                       check: exit 1 on a literal the baseline doesn't hold
  scripts/listener_words.py --list                every matched literal with its kind, file and line
  scripts/listener_words.py --inventory [PATH]    write the full inventory as JSON (default artifacts/listener-words-item.json)
  scripts/listener_words.py --update              drop baseline rows that no longer exist (never adds one)
  scripts/listener_words.py --accept "reason"     also add the new literals, each with the reason

The baseline is keyed by kind and literal text, with a count, so moving code between files or lines changes nothing.
Do not accept a row to make the check pass: say episode, article or PDF (SourceNoun in SessionKit picks the word from
the source), or "this" when you can't tell.

Blind spots: raw strings (`#"..."#`), a literal built from pieces ("Add " + noun), a multi-line string literal, and text that reaches the
listener from a file or the server. Stdlib only, Python 3.9-compatible.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BASELINE = ROOT / 'scripts' / 'listener_words_baseline.json'
SOURCE_DIRS = ('App', 'Packages/SessionKit/Sources')
SKIP_PARTS = ('Tests', 'UITests', '.build', 'Pods')

ITEM_WORD = re.compile(r'\bitems?\b', re.IGNORECASE)
# A lone token such as `item.lastFailure`, `item-row`, `row.item`: identifier-shaped, so it isn't read to anyone.
IDENTIFIER = re.compile(r'^[A-Za-z0-9_.:/\-#\[\]()%$@{}\u2026,]+$')
VOICEOVER_LINE = re.compile(r'accessibility(?:Label|Hint|Value|InputLabels)|\.accessibilityLabel|AccessibilityLabel')
# In the code before the literal: logs and assertion messages are never read to a listener.
LOG_LINE = re.compile(
    r'\bLogger\b|\blogger\.|\bos_log\b|\bprint\(|\bNSLog\b|\bdebugPrint\b|\bfatalError\b|'
    r'\bprecondition(?:Failure)?\b|\bassert(?:ionFailure)?\b')
# Only in the code before the literal, so a later `.accessibilityIdentifier(...)` or `kind:` argument can't hide
# readable text that comes first on the line.
IDENTIFIER_BEFORE = re.compile(
    r'accessibilityIdentifier\s*\(?\s*$|\bidentifier\s*(?::|==|=)\s*$|\bdiag(?:nostic)?[A-Za-z]*\(\s*$|\.record\(\s*$|'
    r'\bNotification\.Name\(\s*$|\bURL\(string\s*:\s*$|\bUTType\w*\(\s*$|\bBGTask\w*\(\s*$|'
    r'\brawValue\s*==\s*$|\btargetType\s*:\s*$|\bUserDefaults\b.*\(\s*$')
# Not here on purpose: `label:`, `name:`, `key:`, `kind:`, `category:`, `event:` and `case x =`. In this app those
# arguments carry readable text too (`TypeDisplayRepresentation(name: "Library Item")`, `Choice(label: "Your Margins")`).
# A lone lowercase value after them is already an identifier by the no-spaces rule in kind_of.
# A line that picks a word to put in a sentence: the bare token is read.
SENTENCE_NOUN = re.compile(r'[Nn]oun|\bsingular\b|\bplural\b|\(\s*one\s*,\s*many\s*\)|\bone\s*:\s*"')
SQL = re.compile(r'\b(?:SELECT|DELETE FROM|INSERT INTO|UPDATE|WHERE|CREATE TABLE|ALTER TABLE)\b')
COMMENT = re.compile(r'^\s*(?://|\*|/\*)')


def kind_of(line: str, text: str, offset: int = 0) -> str:
    before = line[:offset]
    if LOG_LINE.search(before) or IDENTIFIER_BEFORE.search(before):
        return 'identifier'
    if SQL.search(text):
        return 'identifier'
    token = text.strip()
    # A lone lowercase token with no spaces ("item.lastFailure", "item", "item:…") is a key or a name, not read to
    # anyone, unless the line builds a sentence from it (`(one, many) = ("item", "items")`, an `itemNoun`).
    in_sentence = False
    start = before.rfind('\\(')
    if start >= 0:
        tail = before[start:]
        in_sentence = tail.count('(') > tail.count(')')  # a word picked inside a sentence's interpolation
    if (not in_sentence and token.lower() in ('item', 'items') and '?' in before and re.search(r'[?:]\s*$', before)
            and re.search(r'(?:==|!=|>|<)\s*1\b|\bcount\b', before)):
        in_sentence = True  # a word picked by a ternary: `n == 1 ? "item" : "items"`
    if ' ' not in token and IDENTIFIER.match(token) and not token[:1].isupper() and not in_sentence and not SENTENCE_NOUN.search(line):
        return 'identifier'
    if VOICEOVER_LINE.search(before):
        return 'voiceover'
    return 'words'


def read_string(code: str, start: int, out: list) -> int:
    """Read the string literal whose opening quote is at `start`; add (text, start) for it and for any literal nested
    in its interpolations to `out`. The outer text has each interpolation blanked. Returns the index after it."""
    text = []
    index = start + 1
    slot = len(out)
    out.append(None)  # keeps the outer literal ahead of the ones nested in it
    while index < len(code):
        char = code[index]
        if char == '\\' and index + 1 < len(code):
            if code[index + 1] == '(':
                depth, index = 1, index + 2
                while index < len(code) and depth:
                    if code[index] == '"':
                        index = read_string(code, index, out)
                        continue
                    depth += (code[index] == '(') - (code[index] == ')')
                    index += 1
                text.append('\u2026')
            else:
                text.append(code[index:index + 2])
                index += 2
            continue
        if char == '"':
            out[slot] = (''.join(text), start)
            return index + 1
        text.append(char)
        index += 1
    out[slot] = (''.join(text), start)
    return index


def literals_in(code: str) -> list[tuple[str, int]]:
    """Every single-line string literal in `code` as (text, offset), nested ones included. A triple-quoted block
    is a blind spot and is skipped to the end of its line."""
    out: list = []
    index = 0
    while index < len(code):
        if code.startswith('"""', index):
            break
        if code[index] == '"':
            index = read_string(code, index, out)
            continue
        index += 1
    return out


def strip_trailing_comment(line: str) -> str:
    """The line without a `// ...` comment that follows its code (a `//` inside a string literal, nested ones
    included, stays). A raw string (`#"..."#`) is a blind spot."""
    index = 0
    while index < len(line):
        if line[index] == '"':
            index = read_string(line, index, [])
            continue
        if line.startswith('//', index):
            return line[:index]
        index += 1
    return line


def scan_file(path: Path, rel: str) -> list[dict]:
    rows = []
    try:
        lines = path.read_text(encoding='utf-8').splitlines()
    except (OSError, UnicodeDecodeError):
        return rows
    for number, line in enumerate(lines, 1):
        if COMMENT.match(line) or 'item' not in line.lower():
            continue
        code = strip_trailing_comment(line)
        for text, offset in literals_in(code):
            if not ITEM_WORD.search(text):
                continue
            rows.append({'kind': kind_of(line, text, offset), 'text': text, 'file': rel, 'line': number})
    return rows


def scan(root: Path = ROOT) -> list[dict]:
    rows = []
    for source in SOURCE_DIRS:
        base = root / source
        if not base.exists():
            continue
        for path in sorted(base.rglob('*.swift')):
            rel = path.relative_to(root).as_posix()
            if any(part in SKIP_PARTS or part.endswith('Tests') for part in rel.split('/')):
                continue
            rows.extend(scan_file(path, rel))
    return rows


def counts(rows: list[dict]) -> dict[tuple[str, str], int]:
    table: dict[tuple[str, str], int] = {}
    for row in rows:
        if row['kind'] == 'identifier':
            continue
        key = (row['kind'], row['text'])
        table[key] = table.get(key, 0) + 1
    return table


def load_baseline(path: Path = BASELINE) -> dict[tuple[str, str], dict]:
    if not path.exists():
        return {}
    data = json.loads(path.read_text(encoding='utf-8'))
    return {(e['kind'], e['text']): e for e in data.get('entries', [])}


def save_baseline(entries: dict[tuple[str, str], dict], path: Path = BASELINE) -> None:
    ordered = [entries[key] for key in sorted(entries)]
    payload = {
        'version': 1,
        'note': ('Listener-facing string literals that say "item" when #3599 arrived. Keyed by kind and text, with a '
                 'count. A replacement slice deletes rows (scripts/listener_words.py --update); a new row needs '
                 '--accept "reason". Do not add rows to make a check pass: say episode, article or PDF.'),
        'entries': ordered,
    }
    path.write_text(json.dumps(payload, indent=1, ensure_ascii=False) + '\n', encoding='utf-8')


def compare(rows: list[dict], baseline: dict[tuple[str, str], dict]) -> tuple[list[dict], list[tuple[str, str]]]:
    """(new rows beyond the baseline, baseline keys that are gone or shrank)."""
    now = counts(rows)
    new_rows: list[dict] = []
    seen: dict[tuple[str, str], int] = {}
    for row in rows:
        if row['kind'] == 'identifier':
            continue
        key = (row['kind'], row['text'])
        seen[key] = seen.get(key, 0) + 1
        allowed = baseline.get(key, {}).get('count', 0)
        if seen[key] > allowed:
            new_rows.append(row)
    stale = [key for key, entry in baseline.items() if now.get(key, 0) < entry.get('count', 0)]
    return new_rows, stale


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    parser.add_argument('--list', action='store_true')
    parser.add_argument('--inventory', nargs='?', const='artifacts/listener-words-item.json')
    parser.add_argument('--update', action='store_true')
    parser.add_argument('--accept', metavar='REASON')
    args = parser.parse_args(argv)

    rows = scan()
    baseline = load_baseline()

    if args.list:
        for row in rows:
            print(f"{row['kind']:10} {row['file']}:{row['line']}  {row['text']!r}")
    if args.inventory:
        target = ROOT / args.inventory
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(json.dumps(rows, indent=1, ensure_ascii=False) + '\n', encoding='utf-8')
        by_kind: dict[str, int] = {}
        for row in rows:
            by_kind[row['kind']] = by_kind.get(row['kind'], 0) + 1
        print(f"inventory: {len(rows)} literals with the word item ({', '.join(f'{k} {v}' for k, v in sorted(by_kind.items()))}); written to {args.inventory}")
        return 0

    new_rows, stale = compare(rows, baseline)
    if args.update or args.accept:
        now = counts(rows)
        entries = {}
        for key, entry in baseline.items():
            if key in now:
                entries[key] = {**entry, 'count': min(entry.get('count', 0), now[key])}
        if args.accept:
            for row in new_rows:
                key = (row['kind'], row['text'])
                entries[key] = {'kind': row['kind'], 'text': row['text'], 'count': now[key], 'reason': args.accept}
        elif args.update and not baseline:
            for key, count in now.items():
                entries[key] = {'kind': key[0], 'text': key[1], 'count': count,
                                'reason': 'Existing when the guard arrived (#3599); replace with the source\'s own noun.'}
        save_baseline(entries)
        print(f"baseline written: {len(entries)} rows")
        return 0

    if new_rows:
        print('A listener-facing string says "item" (#3599). A listener knows episodes, articles and PDFs: use the')
        print("source's own noun (SourceNoun in SessionKit), or \"this\" when you can't tell. Not listener-facing? Make it an")
        print('accessibilityIdentifier or a log line. As a last resort: scripts/listener_words.py --accept "reason".')
        for row in new_rows:
            print(f"  {row['kind']}: {row['file']}:{row['line']}  {row['text']!r}")
        return 1
    if stale:
        print(f"{len(stale)} baseline row(s) were replaced or removed; run scripts/listener_words.py --update to ratchet down.")
        return 1
    print(f"listener words: {sum(counts(rows).values())} baseline literals, none new")
    return 0


if __name__ == '__main__':
    sys.exit(main())
