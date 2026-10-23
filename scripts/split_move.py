#!/usr/bin/env python3
"""Move members of the app model into an extension file, and prove a diff is moves only (#1483).

The model split (#319) is mostly cutting known members out of Gate1AppModel.swift into
`extension Gate1AppModel { … }` files. Done by hand, an agent reads thousands of lines, fixes access
errors one build at a time and asks a reviewer whether anything changed. This does the cut and the
access fixes, and `check` proves the result is moves only, so neither the agent nor a reviewer has to.

  scripts/split_move.py list [--grep TEXT] [--from NAME --through NAME]
      The model's members: start line, size, kind, name, and flags (private, stored, #if).
  scripts/split_move.py move --to ShareDrafts NAME [NAME ...]
  scripts/split_move.py move --to ShareDrafts --from NAME --through NAME
      Cut those members (doc comments and attributes included) into Gate1AppModel+ShareDrafts.swift,
      creating it with the model's imports, or adding to its last `extension Gate1AppModel` block.
      NAME selects every overload; NAME@LINE selects the one starting at that line.
      Refuses instance stored properties, designated init, deinit, override and required members,
      which an extension can't hold. Relaxes access only where the split needs it, and lists each change:
        - a moved private member still used by the model file becomes internal;
        - a member left behind that moved code uses: a stored var becomes private(set) when moved code
          only reads it, anything else becomes internal.
      --dry-run prints the plan without writing.
  scripts/split_move.py check [--base REF] [--head REF]
      Proves the model file and its Gate1AppModel+*.swift files changed by moves only, from the
      merge base with REF (default origin/<trunk>, scripts/trunk.py) to HEAD's working tree (or --head REF). Every removed
      line must reappear, in order, in runs that start and end on member boundaries; the only other
      changes allowed are access modifiers, blank lines, imports, `#if`/`#endif`, the extension wrapper
      and comments, which are listed. Exit status 0 means moves only.
  scripts/split_move.py summary [--base REF] [--head REF]
      The same comparison, printed as PR text: lines moved, members per destination file, and the
      names whose access changed. For the working tree it adds a `/lane` draft from test-scope.py.
      Exit status 1, with check's report, when the diff is not moves only.

The compiler stays the backstop: build both targets after a move (AGENTS.md, Verification layer 2).
Stdlib only, Python 3.9-compatible.
"""
from __future__ import annotations

import argparse
import json
from collections import Counter
from dataclasses import dataclass, field
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
TYPE_NAME = 'Gate1AppModel'
SOURCE = 'App/SpokenMarginsApp/Sources/SpokenMarginsApp/Gate1AppModel.swift'

ACCESS_TOKENS = ('fileprivate(set) ', 'private(set) ', 'fileprivate ', 'private ')
MODIFIERS = {
    'private', 'fileprivate', 'internal', 'public', 'open', 'static', 'class', 'final', 'override',
    'mutating', 'nonmutating', 'lazy', 'weak', 'unowned', 'nonisolated', 'convenience', 'required',
    'dynamic', 'indirect', 'private(set)', 'fileprivate(set)', 'internal(set)', 'public(set)',
    'nonisolated(unsafe)', 'unowned(unsafe)', 'unowned(safe)',
}
DECL_KEYWORDS = ('func', 'var', 'let', 'init', 'deinit', 'subscript', 'enum', 'struct', 'class',
                 'actor', 'typealias', 'protocol')
CONTINUATION_STARTS = ('.', '?', ':', '&&', '||', '+', '-', '*', '=', '->', 'where ', 'throws',
                       'rethrows', 'async', '??', ')', ']')


class SplitError(Exception):
    pass


# --- Scanning -------------------------------------------------------------------------------------

@dataclass
class Scan:
    lines: list
    depth: list        # bracket depth ({[ ) at the start of each line, code only
    end_depth: list    # depth at the end of each line
    quiet: list        # True when the line starts inside a string or block comment
    code: list         # each line with comments and string contents blanked out


def scan(text: str) -> Scan:
    """Track ({[ depth through Swift comments, strings, raw strings and interpolation."""
    lines = text.split('\n')
    depth = 0
    # Mode stack: ('code', parens) for top-level code or interpolation, ('str', multi, hashes),
    # ('block', nesting).
    stack: list = [('code', None)]
    depths, ends, quiets, codes = [], [], [], []
    for line in lines:
        depths.append(depth)
        quiets.append(stack[-1][0] != 'code' or len(stack) > 1)
        out = []
        i, n = 0, len(line)
        while i < n:
            mode = stack[-1]
            ch = line[i]
            if mode[0] == 'block':
                if line.startswith('/*', i):
                    stack[-1] = ('block', mode[1] + 1)
                    out.append('  ')
                    i += 2
                elif line.startswith('*/', i):
                    if mode[1] == 1:
                        stack.pop()
                    else:
                        stack[-1] = ('block', mode[1] - 1)
                    out.append('  ')
                    i += 2
                else:
                    out.append(' ')
                    i += 1
                continue
            if mode[0] == 'str':
                _, multi, hashes = mode
                if ch == '\\' and line.startswith('#' * hashes, i + 1):
                    j = i + 1 + hashes
                    if j < n and line[j] == '(':
                        stack.append(('code', 0))
                        out.append(' ' * (j - i + 1))
                        i = j + 1
                    else:
                        out.append(' ' * min(2 + hashes, n - i))
                        i = j + 1
                    continue
                close = ('"""' if multi else '"') + '#' * hashes
                if line.startswith(close, i):
                    stack.pop()
                    out.append(close)
                    i += len(close)
                    continue
                out.append(' ')
                i += 1
                continue
            # Code, either top level or inside an interpolation.
            interp = len(stack) > 1
            if line.startswith('//', i):
                out.append(' ' * (n - i))
                break
            if line.startswith('/*', i):
                stack.append(('block', 1))
                out.append('  ')
                i += 2
                continue
            m = re.match(r'(#*)("""|")', line[i:])
            if m and (m.group(1) == '' or ch == '#'):
                hashes = len(m.group(1))
                multi = m.group(2) == '"""'
                stack.append(('str', multi, hashes))
                out.append(m.group(0))
                i += len(m.group(0))
                continue
            if ch in '([{':
                if interp:
                    stack[-1] = ('code', mode[1] + 1)
                else:
                    depth += 1
            elif ch in ')]}':
                if interp:
                    if ch == ')' and mode[1] == 0:
                        stack.pop()
                        out.append(' ')
                        i += 1
                        continue
                    stack[-1] = ('code', mode[1] - 1)
                else:
                    depth -= 1
            out.append(ch)
            i += 1
        # A single-line string can't cross a line end; recover if the scan lost its place.
        while stack[-1][0] == 'str' and not stack[-1][1]:
            stack.pop()
            while stack[-1][0] == 'code' and len(stack) > 1 and stack[-1][1] is not None:
                stack.pop()
        ends.append(depth)
        codes.append(''.join(out))
    return Scan(lines, depths, ends, quiets, codes)


# --- Members --------------------------------------------------------------------------------------

@dataclass
class Member:
    start: int                 # first line (0-based), leading comments and attributes included
    decl: int                  # the declaration's first line
    end: int                   # last line, inclusive
    kind: str
    name: str
    header: str                # the declaration before its body, code only
    modifiers: set
    conditions: list = field(default_factory=list)   # enclosing #if lines at member level
    has_else: bool = False

    @property
    def size(self) -> int:
        return self.end - self.start + 1

    @property
    def is_private(self) -> bool:
        return bool(self.modifiers & {'private', 'fileprivate'})

    @property
    def is_static(self) -> bool:
        return bool(self.modifiers & {'static', 'class'})

    @property
    def stored(self) -> bool:
        if self.kind not in ('var', 'let') or self.is_static:
            return False
        if self.kind == 'let' or 'lazy' in self.modifiers or '@' in self.header.split(self.kind)[0]:
            return True
        body = self.header.partition('{')
        if not body[1]:
            return True
        before, rest = body[0], body[2].lstrip()
        if '=' in before:
            return True
        return rest.startswith(('didSet', 'willSet'))


ATTR_RE = re.compile(r'@\w+(\([^()]*(\([^()]*\))*[^()]*\))?\s*')


def parse_header(header: str) -> tuple:
    """Return (kind, name, modifiers) for a declaration's code text."""
    text = header.strip()
    while text.startswith('@'):
        m = ATTR_RE.match(text)
        if not m:
            break
        text = text[m.end():]
    modifiers = set()
    while True:
        m = re.match(r'(\w+(\((set|unsafe|safe)\))?)\s+', text)
        if not m or m.group(1) not in MODIFIERS:
            break
        modifiers.add(m.group(1))
        text = text[m.end():]
    m = re.match(r'(\w+)\b\s*(`?[\w]+`?|[^\s(<]+)?', text)
    if not m or m.group(1) not in DECL_KEYWORDS:
        return ('other', text.split('(')[0].split()[0] if text.split() else '', modifiers)
    kind = m.group(1)
    if kind in ('init', 'deinit', 'subscript'):
        return (kind, kind, modifiers)
    name = (m.group(2) or '').strip('`')
    return (kind, name, modifiers)


def is_attribute_line(code: str) -> bool:
    text = code.strip()
    if not text.startswith('@'):
        return False
    while text:
        m = ATTR_RE.match(text)
        if not m or m.end() == 0:
            return False
        text = text[m.end():]
    return True


def body_range(s: Scan, type_name: str) -> tuple:
    """The class or struct body: (first line inside, closing line)."""
    pattern = re.compile(r'^(?:@\w+\s+)*(?:(?:public|internal|final|open)\s+)*(?:class|struct|actor|enum)\s+'
                         + re.escape(type_name) + r'\b')
    for i, code in enumerate(s.code):
        if s.depth[i] == 0 and pattern.match(code.strip()):
            j = i
            while s.end_depth[j] == 0:
                j += 1
            k = j + 1
            while k < len(s.lines) and not (s.depth[k] == 1 and s.code[k].strip().startswith('}')
                                            and s.end_depth[k] == 0):
                k += 1
            return j + 1, k
    raise SplitError(f'no declaration of {type_name} found')


def members_in(s: Scan, first: int, last: int, level: int) -> list:
    """Split lines [first, last) at bracket depth `level` into members."""
    result: list = []
    pending: list = []          # leading comment and attribute lines
    conditions: list = []
    else_flags: list = []
    i = first
    while i < last:
        code = s.code[i].strip()
        raw = s.lines[i].strip()
        if s.depth[i] != level or s.quiet[i]:
            i += 1
            continue
        if not raw:
            pending = []
            i += 1
            continue
        if raw.startswith('#if'):
            conditions.append(s.lines[i])
            else_flags.append(False)
            pending = []
            i += 1
            continue
        if raw.startswith(('#else', '#elseif')):
            if else_flags:
                else_flags[-1] = True
            pending = []
            i += 1
            continue
        if raw.startswith('#endif'):
            if conditions:
                conditions.pop()
                else_flags.pop()
            pending = []
            i += 1
            continue
        if not code:      # a comment line (code text blanked)
            pending = [] if raw.startswith('// MARK') else pending + [i]
            # A block comment spanning lines belongs together.
            while i + 1 < last and s.quiet[i + 1] and s.depth[i + 1] == level and not s.code[i + 1].strip():
                i += 1
                pending.append(i)
            i += 1
            continue
        if is_attribute_line(code):
            pending.append(i)
            i += 1
            continue
        decl = i
        header_parts = []
        j = i
        while True:
            header_parts.append(s.code[j])
            if s.end_depth[j] == level and not _continues(s, j, last, level):
                break
            j += 1
            if j >= last:
                break
        header = ' '.join(header_parts)
        brace = _top_brace(header)
        if brace is not None:
            header = header[:brace + 1] + ' ' + header[brace + 1:brace + 40]
        kind, name, modifiers = parse_header(header)
        start = pending[0] if pending else decl
        result.append(Member(start, decl, j, kind, name, header, modifiers,
                             list(conditions), any(else_flags)))
        pending = []
        i = j + 1
    return result


def _top_brace(header: str):
    depth = 0
    for k, ch in enumerate(header):
        if ch in '([':
            depth += 1
        elif ch in ')]':
            depth -= 1
        elif ch == '{' and depth == 0:
            return k
    return None


def _continues(s: Scan, j: int, last: int, level: int) -> bool:
    code = s.code[j].rstrip()
    if code.endswith((',', '=', '&&', '||', '->', '+', '-', '*', '??', ':', '(', '[')):
        return True
    k = j + 1
    while k < last and not s.lines[k].strip():
        k += 1
    if k >= last or k > j + 1:
        return False
    nxt = s.code[k].strip()
    return bool(nxt) and nxt.startswith(CONTINUATION_STARTS) and not nxt.startswith('//')


def model_members(text: str, type_name: str = TYPE_NAME) -> tuple:
    s = scan(text)
    first, close = body_range(s, type_name)
    return s, members_in(s, first, close, 1), first, close


# --- Selecting ------------------------------------------------------------------------------------

def select(members: list, names: list, start: str | None, through: str | None) -> list:
    chosen: list = []
    if start or through:
        if not (start and through):
            raise SplitError('--from and --through go together')
        a = _find_one(members, start)
        b = _find_one(members, through)
        if b.start < a.start:
            raise SplitError(f'{through} comes before {start}')
        chosen += [m for m in members if a.start <= m.start <= b.start]
    for spec in names:
        name, _, line = spec.partition('@')
        found = [m for m in members if m.name == name and (not line or m.decl + 1 == int(line))]
        if not found:
            raise SplitError(f'no member {spec}; try `list --grep {name}`')
        chosen += found
    unique = sorted({m.start: m for m in chosen}.values(), key=lambda m: m.start)
    return unique


def _find_one(members: list, spec: str) -> Member:
    name, _, line = spec.partition('@')
    found = [m for m in members if m.name == name and (not line or m.decl + 1 == int(line))]
    if not found:
        raise SplitError(f'no member {spec}')
    if len(found) > 1:
        lines = ', '.join(f'{name}@{m.decl + 1}' for m in found)
        raise SplitError(f'{name} is overloaded; pick one of {lines}')
    return found[0]


def refusal(m: Member) -> str | None:
    if m.kind == 'other':
        return 'not a declaration the script understands'
    if m.kind == 'init' and 'convenience' not in m.modifiers:
        return 'a designated init stays in the class body'
    if m.kind == 'deinit':
        return 'deinit stays in the class body'
    if m.modifiers & {'override', 'required'}:
        return 'override and required members stay in the class body'
    if m.stored:
        return 'an instance stored property cannot live in an extension'
    if m.has_else:
        return 'it sits in an #if with an #else branch; move it by hand'
    return None


# --- Access ---------------------------------------------------------------------------------------

def identifiers(code: str) -> set:
    return set(re.findall(r'[A-Za-z_]\w*', code))


MUTATING = r'(=(?!=)|[-+*/%]=|\[[^\]]*\]\s*=(?!=)|\.(append|remove|removeAll|removeValue|removeFirst|removeLast|insert|merge|formUnion|subtract|sort|reverse|toggle|updateValue|popLast)\b)'


def mutating_methods(*texts: str) -> frozenset:
    """Names of `mutating func`s declared in the given Swift texts and in the app and package sources.

    A call such as `passes.begin(...)` on a struct-typed stored var needs its setter; the stdlib
    names in MUTATING don't cover the repo's own structs (#1012: `sharedMarginPlacementPasses`;
    #990: `microphonePrimer`)."""
    found = set()
    sources = list(texts)
    for folder in ('App', 'Packages'):
        for path in (ROOT / folder).rglob('*.swift'):
            if '.build' not in path.parts:
                sources.append(path.read_text(errors='replace'))
    for text in sources:
        found.update(re.findall(r'\bmutating\s+func\s+(\w+)', text))
    return frozenset(found)


def mutated(code: str, name: str, methods: frozenset = frozenset()) -> bool:
    """Whether code assigns to or mutates `name`, as opposed to reading it or binding a local of that name.

    `methods` are extra mutating method names (see mutating_methods)."""
    pattern = MUTATING
    if methods:
        pattern = MUTATING[:-1] + '|\\.(' + '|'.join(sorted(map(re.escape, methods))) + r')\s*\()'
    for match in re.finditer(r'(?<![\w.])(self\.)?' + re.escape(name) + r'\??\s*' + pattern, code):
        before = code[max(0, match.start() - 40):match.start()]
        if match.group(1) or not re.search(r'\b(let|var|case)\s+$|,\s*$', before):
            return True
    # A tuple assignment, `(a, b) = (x, y)` (#1016: skimForwardDestinationMs).
    tuple_target = r'\(\s*(?:[^()=]*,\s*)?(self\.)?' + re.escape(name) + r'\s*(?:,[^()=]*)?\)\s*=(?!=)'
    if re.search(tuple_target, code):
        return True
    return re.search(r'&(self\.)?' + re.escape(name) + r'\b', code) is not None


def strip_access(line: str, tokens: tuple = ACCESS_TOKENS) -> str:
    for token in tokens:
        line = line.replace(token, '', 1) if token in line else line
    return line


def relax_header(lines: list, m: Member, new_access: str | None) -> tuple:
    """Rewrite the access modifiers on m's declaration line. Returns (old, new) or None."""
    old = lines[m.decl]
    indent = old[:len(old) - len(old.lstrip())]
    body = old.lstrip()
    # Only touch the modifier list before the keyword.
    head, sep, tail = _split_at_keyword(body, m.kind)
    if not sep:
        return None
    new_head = head
    for token in ACCESS_TOKENS:
        new_head = new_head.replace(token, '')
    if new_access:
        new_head = _insert_access(new_head, new_access)
    new = indent + new_head + sep + tail
    if new == old:
        return None
    lines[m.decl] = new
    return (old.strip(), new.strip())


def _split_at_keyword(body: str, kind: str) -> tuple:
    m = re.search(r'(?<![\w@])' + re.escape(kind) + r'\b', body)
    if not m:
        return body, '', ''
    return body[:m.start()], body[m.start():m.end()], body[m.end():]


def _insert_access(head: str, access: str) -> str:
    # After attributes, before other modifiers.
    m = re.match(r'((?:@\w+(?:\([^)]*\))?\s+)*)', head)
    prefix = m.group(1) if m else ''
    return prefix + access + ' ' + head[len(prefix):]


# --- Move -----------------------------------------------------------------------------------------

def plan_move(text: str, chosen_specs: list, start: str | None, through: str | None,
              extra_texts: dict | None = None) -> dict:
    s, members, first, close = model_members(text)
    chosen = select(members, chosen_specs, start, through)
    if not chosen:
        raise SplitError('nothing selected')
    problems = [(m, refusal(m)) for m in chosen if refusal(m)]
    if problems:
        raise SplitError('cannot move:\n' + '\n'.join(f'  {m.name}@{m.decl + 1}: {why}' for m, why in problems))
    moved_lines = set()
    for m in chosen:
        moved_lines.update(range(m.start, m.end + 1))
    moved_code = '\n'.join(s.code[i] for i in sorted(moved_lines))
    remaining_code = '\n'.join(c for i, c in enumerate(s.code) if i not in moved_lines)
    moved_ids = identifiers(moved_code)
    remaining_ids = identifiers(remaining_code)
    lines = list(s.lines)
    changes = []
    methods = mutating_methods(text, *(extra_texts or {}).values())
    for m in chosen:
        if m.is_private and m.name in remaining_ids:
            change = relax_header(lines, m, None)
            if change:
                changes.append(('moved, used by the model', m.name, change))
        elif 'private(set)' in m.modifiers or 'fileprivate(set)' in m.modifiers:
            if mutated(remaining_code, m.name, methods):
                change = relax_header(lines, m, None)
                if change:
                    changes.append(('moved, set by the model', m.name, change))
    chosen_starts = {m.start for m in chosen}
    staying = [m for m in members if m.start not in chosen_starts]
    top_level = members_in(s, 0, first - 1, 0) + members_in(s, close + 1, len(s.lines), 0)
    for m in staying + top_level:
        if m.name not in moved_ids:
            continue
        writes = mutated(moved_code, m.name, methods)
        if m.is_private:
            if m.stored and m.kind == 'var' and not writes:
                change = relax_header(lines, m, 'private(set)')
            else:
                change = relax_header(lines, m, None)
        elif ('private(set)' in m.modifiers or 'fileprivate(set)' in m.modifiers) and writes:
            change = relax_header(lines, m, None)
        else:
            change = None
        if change:
            where = 'left behind' if m in staying else 'file level'
            changes.append((f'{where}, used by moved code', m.name, change))
    return {'scan': s, 'lines': lines, 'chosen': chosen, 'changes': changes, 'first': first}


def moved_block(lines: list, chosen: list) -> list:
    """The moved members' text, grouped under their #if conditions, one blank line apart."""
    out: list = []
    current: list = []
    for m in chosen:
        if m.conditions != current:
            if current:
                out += ['    #endif'] * len(current)
            if out and out[-1] != '':
                out.append('')
            out += [c for c in m.conditions]
            current = m.conditions
        elif out and out[-1] != '' and not out[-1].lstrip().startswith('#if'):
            out.append('')
        out += lines[m.start:m.end + 1]
    if current:
        out += [_endif_for(c) for c in current]
    return out


def _endif_for(condition_line: str) -> str:
    return condition_line[:len(condition_line) - len(condition_line.lstrip())] + '#endif'


def remove_members(lines: list, chosen: list) -> list:
    drop = set()
    for m in chosen:
        drop.update(range(m.start, m.end + 1))
        # Take one blank line with it so the gap doesn't double.
        if m.end + 1 < len(lines) and not lines[m.end + 1].strip():
            drop.add(m.end + 1)
        elif m.start > 0 and not lines[m.start - 1].strip():
            drop.add(m.start - 1)
    kept = [line for i, line in enumerate(lines) if i not in drop]
    return _drop_empty_conditions(kept)


def _drop_empty_conditions(lines: list) -> list:
    changed = True
    while changed:
        changed = False
        for i, line in enumerate(lines):
            if line.strip().startswith('#if'):
                j = i + 1
                while j < len(lines) and not lines[j].strip():
                    j += 1
                if j < len(lines) and lines[j].strip() == '#endif' and \
                        _indent(lines[j]) == _indent(line):
                    del lines[i:j + 1]
                    if i < len(lines) and i > 0 and not lines[i].strip() and not lines[i - 1].strip():
                        del lines[i]
                    changed = True
                    break
    return lines


def _indent(line: str) -> str:
    return line[:len(line) - len(line.lstrip())]


def import_block(text: str) -> list:
    """The leading imports (with their #if canImport wrappers) of a Swift file."""
    out = []
    for line in text.split('\n'):
        raw = line.strip()
        if raw.startswith(('import ', '@preconcurrency import ', '#if canImport', '#endif')) or \
                (raw == '' and out):
            out.append(line)
            continue
        break
    while out and not out[-1].strip():
        out.pop()
    return out


def merge_imports(dest_text: str, source_imports: list) -> str:
    dest_lines = dest_text.split('\n')
    have = import_block(dest_text)
    have_set = {line.strip() for line in have}
    missing: list = []
    i = 0
    while i < len(source_imports):
        line = source_imports[i].strip()
        if line.startswith('#if canImport'):
            j = i
            while not source_imports[j].strip().startswith('#endif'):
                j += 1
            group = source_imports[i:j + 1]
            inner = [g.strip() for g in group[1:-1]]
            if not all(x in have_set for x in inner):
                missing += group
            i = j + 1
            continue
        if line and line not in have_set:
            missing.append(source_imports[i])
        i += 1
    if not missing:
        return dest_text
    at = len(have)
    return '\n'.join(dest_lines[:at] + missing + dest_lines[at:])


def insert_into_dest(dest_text: str | None, block: list, source_text: str, doc: str | None) -> str:
    imports = import_block(source_text)
    if dest_text is None:
        head = imports + ['']
        if doc:
            head += [f'/// {doc}']
        return '\n'.join(head + [f'extension {TYPE_NAME} {{'] + block + ['}', ''])
    dest_text = merge_imports(dest_text, imports)
    s = scan(dest_text)
    opener = re.compile(r'^extension\s+' + TYPE_NAME + r'\b')
    close = None
    for i, code in enumerate(s.code):
        if s.depth[i] == 0 and opener.match(code.strip()):
            j = i
            while s.end_depth[j] == 0:
                j += 1
            k = j + 1
            while k < len(s.lines) and not (s.depth[k] == 1 and s.end_depth[k] == 0
                                            and s.code[k].strip() == '}'):
                k += 1
            close = k
    lines = dest_text.split('\n')
    if close is None:
        tail = [] if not lines[-1].strip() else ['']
        return '\n'.join(lines + tail + [f'extension {TYPE_NAME} {{'] + block + ['}', ''])
    return '\n'.join(lines[:close] + [''] + block + lines[close:])


def dest_path(source: Path, to: str) -> Path:
    if to.endswith('.swift'):
        return Path(to) if Path(to).is_absolute() else ROOT / to
    return source.parent / f'{TYPE_NAME}+{to}.swift'


def move_texts(source_text: str, dest_text, names: list, start=None, through=None, doc=None) -> tuple:
    """Return (new source, new destination, plan) for moving the named members."""
    plan = plan_move(source_text, names, start, through)
    block = moved_block(plan['lines'], plan['chosen'])
    new_source = '\n'.join(remove_members(plan['lines'], plan['chosen']))
    return new_source, insert_into_dest(dest_text, block, source_text, doc), plan


def cmd_move(args) -> int:
    source = ROOT / args.source
    text = source.read_text()
    dest = dest_path(source, args.to)
    dest_text = dest.read_text() if dest.exists() else None
    new_source, new_dest, plan = move_texts(text, dest_text, args.names, args.start, args.through, args.doc)
    chosen = plan['chosen']
    moved = sum(m.size for m in chosen)
    shown = dest.relative_to(ROOT) if dest.is_relative_to(ROOT) else dest
    print(f'{"Would move" if args.dry_run else "Moved"} {len(chosen)} members ({moved} lines) to {shown}'
          f'{" (new file)" if dest_text is None else ""}:')
    for m in chosen:
        print(f'  {m.decl + 1:>6}  {m.size:>4}  {m.kind:<9} {m.name}')
    if plan['changes']:
        print('Access changes:')
        for why, name, (old, new) in plan['changes']:
            print(f'  {name} ({why}):\n    - {old}\n    + {new}')
    else:
        print('No access changes.')
    if args.dry_run:
        return 0
    source.write_text(new_source)
    dest.write_text(new_dest)
    print(f'{args.source}: {text.count(chr(10))} -> {new_source.count(chr(10))} lines. '
          'Next: scripts/split_move.py check, then build both targets.')
    return 0


def cmd_list(args) -> int:
    text = (ROOT / args.source).read_text()
    _, members, _, _ = model_members(text)
    if args.start or args.through:
        members = select(members, [], args.start, args.through)
    total = 0
    for m in members:
        if args.grep and args.grep.lower() not in m.name.lower():
            continue
        flags = []
        if m.is_private:
            flags.append('private')
        if m.stored:
            flags.append('stored')
        if m.conditions:
            flags.append('#if')
        why = refusal(m)
        if why and not m.stored:
            flags.append('stays')
        total += m.size
        print(f'{m.decl + 1:>6}  {m.size:>4}  {m.kind:<9} {m.name}  {" ".join(flags)}'.rstrip())
    print(f'{total} lines')
    return 0


# --- Check ----------------------------------------------------------------------------------------

def _git(*args: str, check: bool = True) -> str:
    done = subprocess.run(['git', '-C', str(ROOT), *args], capture_output=True, text=True)
    if check and done.returncode != 0:
        raise SplitError(done.stderr.strip() or f'git {" ".join(args)} failed')
    return done.stdout


def normalize(line: str) -> str:
    out = line.rstrip()
    for token in ACCESS_TOKENS:
        out = out.replace(token, '')
    return out


@dataclass
class Side:
    path: str
    text: str


def check_texts(source_path: str, base: dict, head: dict, details: dict | None = None) -> tuple:
    """Compare base and head texts of the model file and its extension files.

    Returns (ok, report lines). `details`, when given, receives the moved line counts per file and
    the access changes, for `summary`."""
    import difflib
    report: list = []
    removed_runs: list = []      # [(path, [(line_no, text), ...])]
    added: dict = {}              # path -> list of (line_no, text) added
    access_changes: list = []
    head_scans = {p: scan(t) for p, t in head.items()}
    base_scans = {p: scan(t) for p, t in base.items()}
    for path in sorted(set(base) | set(head)):
        old = base[path].split('\n') if path in base else []
        new = head[path].split('\n') if path in head else []
        # Diff with access modifiers ignored, so a relaxed declaration is an unchanged line, not a
        # delete and insert that splits the moves around it.
        old_n, new_n = [normalize(x) for x in old], [normalize(x) for x in new]
        matcher = difflib.SequenceMatcher(None, old_n, new_n, autojunk=False)
        adds = []
        for tag, i1, i2, j1, j2 in matcher.get_opcodes():
            if tag == 'equal':
                access_changes += [(path, i1 + k + 1, old[i1 + k].strip(), new[j1 + k].strip())
                                   for k in range(i2 - i1) if old[i1 + k] != new[j1 + k]]
                continue
            if tag == 'delete' and path in base_scans:
                i1, i2 = _slide(old_n, i1, i2, base_scans[path])
            if tag == 'insert' and path in head_scans:
                j1, j2 = _slide(new_n, j1, j2, head_scans[path])
            if tag in ('delete', 'replace'):
                removed_runs.append((path, [(i, old[i]) for i in range(i1, i2)]))
            if tag in ('insert', 'replace'):
                adds += [(j, new[j]) for j in range(j1, j2)]
        added[path] = adds
    pools = {p: [(j, normalize(t)) for j, t in a if t.strip()] for p, a in added.items()}
    used = {p: [False] * len(v) for p, v in pools.items()}
    unmatched_removed: list = []
    bad_boundaries: list = []
    moved = Counter()
    for path, run in removed_runs:
        items = [(i, normalize(t)) for i, t in run if t.strip()]
        k = 0
        while k < len(items):
            best = None
            for p, pool in pools.items():
                for q, (_, text) in enumerate(pool):
                    if used[p][q] or text != items[k][1]:
                        continue
                    length = 0
                    while k + length < len(items) and q + length < len(pool) and \
                            not used[p][q + length] and pool[q + length][1] == items[k + length][1]:
                        length += 1
                    if best is None or length > best[2]:
                        best = (p, q, length)
            if best is None:
                unmatched_removed.append((path, items[k]))
                k += 1
                continue
            p, q, length = best
            src_line = items[k][0]
            dst_line = pools[p][q][0]
            src_ok = _at_member_level(base_scans[path], src_line, path, source_path)
            dst_ok = _at_member_level(head_scans[p], dst_line, p, source_path)
            if length > 1 and not (src_ok and dst_ok):
                bad_boundaries.append((path, src_line + 1, p, dst_line + 1, items[k][1].strip()))
            if length == 1 and not (src_ok and dst_ok):
                raw_old = dict(run).get(src_line, '')
                raw_new = added[p][[j for j, _ in added[p]].index(dst_line)][1]
                if raw_old.strip() != raw_new.strip():
                    access_changes.append((path, src_line + 1, raw_old.strip(), raw_new.strip()))
                elif not _benign(items[k][1]):
                    bad_boundaries.append((path, src_line + 1, p, dst_line + 1, items[k][1].strip()))
            for x in range(length):
                used[p][q + x] = True
                raw_old = dict(run).get(items[k + x][0], '')
                j = pools[p][q + x][0]
                raw_new = next(t for jj, t in added[p] if jj == j)
                if raw_old.strip() != raw_new.strip() and (length > 1 or _at_member_level(base_scans[path], items[k + x][0], path, source_path)):
                    access_changes.append((path, items[k + x][0] + 1, raw_old.strip(), raw_new.strip()))
            if p != path:
                moved[p] += length
            k += length
    extra_added = []
    comments = []
    for p, pool in pools.items():
        for q, (j, text) in enumerate(pool):
            if used[p][q]:
                continue
            raw = text.strip()
            if raw.startswith('//') or raw.startswith('/*') or raw.startswith('*'):
                comments.append((p, j + 1, raw))
            elif _benign(text):
                continue
            else:
                extra_added.append((p, j + 1, raw))
    real_unmatched = [(p, (i, t)) for p, (i, t) in unmatched_removed
                      if not _benign(t) and not t.strip().startswith('//')]
    removed_comments = [(p, i + 1, t.strip()) for p, (i, t) in unmatched_removed if t.strip().startswith('//')]
    ok = not real_unmatched and not extra_added and not bad_boundaries
    total = sum(moved.values())
    if details is not None:
        details.update(moved=dict(moved), access_changes=list(access_changes))
    report.append(f'{"Moves only" if ok else "NOT moves only"}: {total} lines moved out of '
                  f'{Path(source_path).name}' + (':' if moved else '.'))
    for p, n in sorted(moved.items()):
        report.append(f'  {n:>5}  {Path(p).name}')
    if access_changes:
        report.append(f'Access changes ({len(access_changes)}):')
        report += [f'  - {old}\n    + {new}' for _, _, old, new in access_changes]
    if comments:
        report.append(f'Comments added ({len(comments)}):')
        report += [f'  {Path(p).name}:{j}  {t}' for p, j, t in comments]
    if removed_comments:
        report.append(f'Comments removed ({len(removed_comments)}):')
        report += [f'  {Path(p).name}:{j}  {t}' for p, j, t in removed_comments]
    for p, (i, t) in real_unmatched:
        report.append(f'Removed, not found elsewhere: {Path(p).name}:{i + 1}  {t.strip()}')
    for p, j, t in extra_added:
        report.append(f'Added, not a moved line: {Path(p).name}:{j}  {t}')
    for p, i, d, j, t in bad_boundaries:
        report.append(f'Run starts inside a member: {Path(p).name}:{i} -> {Path(d).name}:{j}  {t}')
    return ok, report


def _slide(lines: list, a: int, b: int, s: Scan) -> tuple:
    """Shift a pure delete or insert of lines[a:b] to the equivalent place that starts on a member boundary.

    When the block ends with the same lines as the text just before it (two members both ending in
    `    }`), a diff may take the neighbour's closing braces and leave the block's own behind. The text is
    the same either way; the boundary-aligned choice is the one a reader means."""
    def boundary(i: int) -> bool:
        return i < len(s.depth) and s.depth[i] == 1 and not s.quiet[i]

    def good(x: int, y: int) -> bool:
        return boundary(x) and (y >= len(lines) or boundary(y))

    if good(a, b):
        return a, b
    x, y = a, b
    while x > 0 and lines[x - 1] == lines[y - 1]:
        x, y = x - 1, y - 1
        if good(x, y):
            return x, y
    x, y = a, b
    while y < len(lines) and lines[x] == lines[y]:
        x, y = x + 1, y + 1
        if good(x, y):
            return x, y
    return a, b


def _benign(text: str) -> bool:
    raw = text.strip()
    return (not raw or raw in ('}', '{') or raw.startswith(('import ', '@preconcurrency import ', '#if', '#endif', '#else'))
            or re.match(r'^extension\s+' + TYPE_NAME + r'\b.*\{$', raw) is not None)


def _at_member_level(s: Scan, line: int, path: str, source_path: str) -> bool:
    if line >= len(s.depth) or s.quiet[line]:
        return False
    return s.depth[line] == 1


def model_paths(source_path: str, ref: str | None) -> list:
    folder = str(Path(source_path).parent)
    prefix = f'{folder}/{TYPE_NAME}+'
    if ref:
        names = _git('ls-tree', '-r', '--name-only', ref, '--', folder).split('\n')
    else:
        names = _git('ls-files', '--cached', '--others', '--exclude-standard', '--', folder).split('\n')
    return [source_path] + sorted(n for n in names if n.startswith(prefix) and n.endswith('.swift'))


def read_at(ref: str | None, path: str) -> str | None:
    if ref is None:
        file = ROOT / path
        return file.read_text() if file.exists() else None
    done = subprocess.run(['git', '-C', str(ROOT), 'show', f'{ref}:{path}'], capture_output=True, text=True)
    return done.stdout if done.returncode == 0 else None


def cmd_check(args) -> int:
    head_ref = args.head
    base = _git('merge-base', args.base, head_ref or 'HEAD').strip()
    paths = sorted(set(model_paths(args.source, base)) | set(model_paths(args.source, head_ref)))
    base_texts = {p: t for p in paths if (t := read_at(base, p)) is not None}
    head_texts = {p: t for p in paths if (t := read_at(head_ref, p)) is not None}
    changed = {p for p in paths if base_texts.get(p) != head_texts.get(p)}
    base_texts = {p: t for p, t in base_texts.items() if p in changed}
    head_texts = {p: t for p, t in head_texts.items() if p in changed}
    if not changed:
        print('The model file and its extension files are unchanged.')
        return 0
    ok, report = check_texts(args.source, base_texts, head_texts)
    print('\n'.join(report))
    diff_args = ['diff', '--name-only', base] + ([head_ref] if head_ref else [])
    others = [p for p in _git(*diff_args).split('\n') if p and p not in paths]
    if not head_ref:
        others += [p for p in _git('ls-files', '--others', '--exclude-standard').split('\n')
                   if p and p not in paths and p not in others]
    if others:
        print(f'Other files changed, not checked ({len(others)}):')
        print('\n'.join(f'  {p}' for p in others))
    return 0 if ok else 1


DECL_NAME = re.compile(r'\b(?:func|var|let|case)\s+([A-Za-z_]\w*)|\b(init|subscript)\b')


def declared_name(line: str) -> str | None:
    m = DECL_NAME.search(strip_access(line.strip()))
    return (m.group(1) or m.group(2)) if m else None


def summary_texts(source_path: str, base: dict, head: dict) -> tuple:
    """Return (ok, PR-ready markdown) for a split: what moved where, by member, and the access changes."""
    details: dict = {}
    ok, report = check_texts(source_path, base, head, details)
    if not ok:
        return ok, report
    name = Path(source_path).name
    base_model, head_model = base.get(source_path, ''), head.get(source_path, '')
    _, base_members, _, _ = model_members(base_model)
    _, head_members, _, _ = model_members(head_model) if head_model else (None, [], 0, 0)
    left = {m.name for m in head_members}
    moved_names = list(dict.fromkeys(m.name for m in base_members if m.name not in left))
    total = sum(details['moved'].values())
    out = [f'**What moved.** {total:,} non-blank lines out of `{name}` '
           f'({base_model.count(chr(10)):,} to {head_model.count(chr(10)):,} lines):']
    for path, count in sorted(details['moved'].items()):
        added = Counter(head.get(path, '').split('\n')) - Counter((base.get(path) or '').split('\n'))
        declared = {declared_name(line) for line in added if re.match(r'    \S', line)}
        here = [n for n in moved_names if n in declared]
        new = ' (new file)' if path not in base else ''
        short = Path(path).name.replace(f'{TYPE_NAME}+', '+').removesuffix('.swift')
        out.append(f'- {count:,} lines into `{short}`{new}: ' + ', '.join(f'`{n}`' for n in here) + '.')
    changes = details['access_changes']
    if changes:
        names = list(dict.fromkeys(n for _, _, _, new in changes if (n := declared_name(new))))
        out.append('')
        out.append(f'**Access changes ({len(changes)}), declaration lines only:** '
                   + ', '.join(f'`{n}`' for n in names) + '.')
    return ok, out


def cmd_summary(args) -> int:
    head_ref = args.head
    base = _git('merge-base', args.base, head_ref or 'HEAD').strip()
    paths = sorted(set(model_paths(args.source, base)) | set(model_paths(args.source, head_ref)))
    base_texts = {p: t for p in paths if (t := read_at(base, p)) is not None}
    head_texts = {p: t for p in paths if (t := read_at(head_ref, p)) is not None}
    changed = {p for p in paths if base_texts.get(p) != head_texts.get(p)}
    if not changed:
        print('The model file and its extension files are unchanged.')
        return 0
    # The model file is always compared, so its line counts are known even when only extensions moved.
    keep = changed | {args.source}
    ok, out = summary_texts(args.source, {p: t for p, t in base_texts.items() if p in keep},
                            {p: t for p, t in head_texts.items() if p in keep})
    print('\n'.join(out))
    if not ok:
        print('\nNot moves only: fix the diff before writing the PR (`check` lists why).')
        return 1
    print(f'\n**Verification.** `scripts/split_move.py check --base {args.base}` reports moves only.')
    if head_ref:
        return 0  # test-scope reads the working tree, so a draft for another commit would be wrong.
    scope = subprocess.run([sys.executable, str(ROOT / 'scripts' / 'test-scope.py'), '--base', base, '--json'],
                           capture_output=True, text=True, cwd=ROOT)
    try:
        lane = json.loads(scope.stdout)['lane_request']
    except (ValueError, KeyError):
        lane = None
    if lane:
        first, _, rest = lane.partition('\n')
        head_sha = _git('rev-parse', '--short', 'HEAD').strip()
        print(f'\nLane request draft from test-scope (commit is HEAD; commit and push first):\n\n{first}\n'
              f'commit: {head_sha}\nchanged: members moved unchanged out of {Path(args.source).name}\n{rest}'.rstrip())
    return 0


def main(argv: list | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    parser.add_argument('--source', default=SOURCE, help='the model file, relative to the repo root')
    sub = parser.add_subparsers(dest='command', required=True)
    listing = sub.add_parser('list', help="list the model's members")
    listing.add_argument('--grep')
    listing.add_argument('--from', dest='start')
    listing.add_argument('--through')
    move = sub.add_parser('move', help='move members into an extension file')
    move.add_argument('--to', required=True, help='suffix (ShareDrafts) or path of the extension file')
    move.add_argument('--from', dest='start')
    move.add_argument('--through')
    move.add_argument('--doc', help='a one-line doc comment for a new file')
    move.add_argument('--dry-run', action='store_true')
    move.add_argument('names', nargs='*')
    check = sub.add_parser('check', help='prove the diff is moves only')
    check.add_argument('--base')
    check.add_argument('--head', help='a commit to check instead of the working tree')
    summary = sub.add_parser('summary', help='PR text for a moves-only diff, and a lane request draft')
    summary.add_argument('--base')
    summary.add_argument('--head', help='a commit to summarize instead of the working tree')
    args = parser.parse_args(argv)
    if getattr(args, 'base', '') is None:  # #1492: the trunk (scripts/trunk.py)
        from trunk import trunk_ref
        args.base = trunk_ref()
    try:
        return {'list': cmd_list, 'move': cmd_move, 'check': cmd_check, 'summary': cmd_summary}[args.command](args)
    except SplitError as error:
        print(f'split_move: {error}', file=sys.stderr)
        return 2


if __name__ == '__main__':
    sys.exit(main())
