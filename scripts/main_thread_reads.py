#!/usr/bin/env python3
"""A static scanner for main-thread store, file and audio work, kept as a ratchet (#2257, part of the audit #2256).

The app's `@MainActor` model calls `SQLiteSessionStore`, which is synchronous, directly. Each such call, each
whole-table read, each `Data(contentsOf:)` and each synchronous AVFoundation property read on the main thread is a
frozen screen waiting for a big enough Library (#868, #873, #2073, #2102, #2184, #2255). There was no list of them.
This scanner is that list (the audit's raw inventory) and the guard that keeps a new one out.

  scripts/main_thread_reads.py                      check: fail on a row that is not in the baseline
  scripts/main_thread_reads.py --summary            counts per class and area
  scripts/main_thread_reads.py --json FILE          every row, with file and line, to FILE
  scripts/main_thread_reads.py --ref REV            scan another commit (git archive), e.g. the code a fix replaced
  scripts/main_thread_reads.py --update             tighten the baseline: drop fixed rows, lower counts. Never adds.
  scripts/main_thread_reads.py --accept "reason"    add today's new rows to the baseline, each with a one-line reason

What it leaves out (#2514), so a row is worth a person's attention: files project.yml does not compile into the app's
own process (the Watch app, the excluded Watch bridge, the Share, Browser text and widget extensions, which have
their own main thread), code behind `guard`/`if` on a flag project.yml sets false (`BUILD_FLAGS`), and functions
whose every mention (strings included; `@objc` and `override` functions never) sits in `#if DEBUG` or in such code. `--summary` lists the files and counts the rest.

How it decides what runs on the main thread (a heuristic over source text, no compiler; misses are listed below):
- A scope is main when its type or function is `@MainActor`, the type conforms to View/App/Scene/UIKit classes, or it is
  an extension of such a type in any file (`Gate1AppModel+*.swift`), or its closure is `Task { @MainActor in`,
  `MainActor.run` or `DispatchQueue.main`. It is off the main thread in `Task.detached` (or `Self.offMain { }`, or `onRowQueue { }`), `nonisolated async`
  functions, actors, `DispatchQueue.global()`, a queue the file made with `DispatchQueue(label:…)` (`writer.async { }`)
  and `addTask`. A `Task { }` and every other closure keep their
  surroundings' isolation.
- A sync helper (`nonisolated`, or in a plain type) runs on its caller's thread. When the main thread calls one, the
  call is a row ("via Type.helper") carrying the helper's own reads, found through up to six levels of calls.
- A row is keyed by enclosing type.function, API and class, not by line or file, so editing nearby code never breaks the
  ratchet. A `for`/`while`/`.map` body marks its rows `in_loop`. A `Task { }` on the main thread that contains a
  read and no `labels.scoped(` gets one extra `unlabelled-main-task` row: the hang probe reports it as
  `operation: none` (#2255).

Known blind spots (each is a heuristic, not a proof; the baseline holds the known false positives):
- No type inference. A store is recognised by its receiver's name (`store`, `sessionStore`, `requireStore()`, …)
  plus an API name read from SQLiteSessionStore's own public functions. `$0.loadItem()`, a store passed under another
  name, or a protocol wrapper is missed.
- A closure handed to an unknown API keeps the enclosing isolation, so a completion handler that really runs on a
  background queue is over-flagged. A callee on a variable (`engine.pause()`) is looked up by the variable's
  declared type (`var engine: SessionEngine?` or a parameter, in the file or the enclosing type's files), else a type
  named like it (`sessionEngine` -> SessionEngine, `engine` -> …Engine), else a type containing its name. When the
  first tier that matches still names two types, the call is skipped as `ambiguous-callee` (counted in --summary).
- A `@Sendable` closure is not taken to run off the main thread: it is not actor-isolated, but a synchronous one runs
  on whoever calls it.
- Not seen: code a release build never reaches because a test hook answers no (`UITestingHooks.isActive`, a handler
  only tests set), a call resolved to the wrong type, and a read that is cheap by construction. Those stay rows.
- Cost is never judged: `loadItem(id:)` of a short note and of a 1 MB book are the same row. Ranking is step 4
  (#2260) and the read meter is step 2 (#2258).
- Nothing here can see that a caller uses a title where the callee decodes the whole text (see #2102). The class
  `store-whole-table-read` is the nearest proxy: a read with no argument that returns every row.
- This is the bridge. The end state is the compiler refusing the call, once the store is reachable only
  asynchronously (#2256 step 5); then this scanner and its baseline go away.

Stdlib only, Python 3.9-compatible.
"""
from __future__ import annotations

import argparse
import bisect
import json
import re
import subprocess
import sys
import tempfile
from collections import Counter, defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BASELINE = 'scripts/main_thread_reads_baseline.json'
SCAN_DIRS = ('App', 'Packages/SessionKit/Sources')
ARCHIVE_PATHS = SCAN_DIRS + ('project.yml',)
MAX_HELPER_DEPTH = 6
STORE_FILES = 'Packages/SessionKit/Sources/SessionKitPersistence'

# What an unqualified store method name means. Everything else a store offers is read from its source.
HEAVY_DECODE = {'loadItem', 'listItems', 'listDeletedItems', 'loadTranscriptTimeline', 'loadStructuredDocument',
                'loadListeningMap', 'loadResolvedListeningMapProjection', 'loadPortableListeningMapProposals',
                'loadEditionFingerprintSpine', 'loadTranscriptPhraseSketch', 'loadPreparedAudioManifest',
                'loadPreparedAudioManifests'}
FALLBACK_STORE_APIS = {'loadItem', 'listItems', 'loadSessions', 'loadSession', 'loadInterjections', 'saveItem',
                       'saveSession', 'saveInterjection', 'loadOwnedOfflineAssets', 'loadTranscriptTimeline'}
WRITE_PREFIXES = ('save', 'delete', 'update', 'remove', 'mark', 'import', 'invalidate', 'publish', 'restore',
                  'move', 'settle', 'seed', 'reset', 'migrate', 'apply')
CLASS_PRIORITY = ['store-whole-table-read', 'store-heavy-decode', 'store-read', 'store-write', 'file-io', 'av-sync']
MAIN_PROTOCOLS = {'View', 'ViewModifier', 'App', 'Scene', 'UIViewRepresentable', 'UIViewControllerRepresentable',
                  'NSViewRepresentable', 'UIApplicationDelegate', 'UIWindowSceneDelegate', 'UISceneDelegate'}
UIKIT_MAIN = re.compile(r'^UI\w*(Controller|View|Cell|Window|Responder)$')

# Area by file name, first match wins. The four product areas of docs/areas.md; the rest is groundwork.
AREAS = (('answer-it', re.compile(r'margin|interjection|record|review|brief|rejoinder|reply|dictat|capture|listenback', re.I)),
         ('pass-it-on', re.compile(r'shar|packet|coop|co-op|layer|export|friend|club|commentary|community|invite', re.I)),
         ('get-it-in', re.compile(r'feed|following|import|subscri|download|quickaccess|source|substack|epub|pdf|link|web|catalog|search|onboard|extension', re.I)),
         ('hear-it-well', re.compile(r'playback|audio|voice|skim|map|episode|player|speech|transcript|chapter|nowplaying|reader|tts|supertonic|kitten|scene|offline|engine|item|queue|lockscreen|watch|speak', re.I)))

# --- What the app target builds ----------------------------------------------------------------------------------

PROJECT = 'project.yml'
# A plist flag that project.yml sets to false, and the model property that reads it. Code behind `guard <property>`
# never runs in a build with the flag off (#2514). If project.yml sets the flag true, or drops it, the rows come back.
BUILD_FLAGS = {'SMRemoteProviderExperienceEnabled': 'remoteProviderExperienceEnabled'}


def parse_project(text: str):
    """The targets of project.yml as {name: {'type': …, 'sources': [(path, [excludes])]}}. A few lines of indentation
    reading for the one shape XcodeGen specs here use, so the scanner stays stdlib-only."""
    targets, in_targets, current, section, entry, in_excludes = {}, False, None, None, None, False
    for raw in text.split('\n'):
        line = re.sub(r'(^|\s)#.*$', '', raw).rstrip()
        if not line.strip():
            continue
        indent = len(line) - len(line.lstrip())
        body = line.strip()
        if indent == 0:
            in_targets, current, section = body == 'targets:', None, None
        elif not in_targets:
            continue
        elif indent == 2 and body.endswith(':'):
            current, section = {'type': '', 'sources': [], 'unparsed': False, 'text': []}, None
            targets[body[:-1]] = current
        elif current is None:
            continue
        elif indent == 4:
            section = 'sources' if body == 'sources:' else None
            if body.startswith('type:'):
                current['type'] = body.split(':', 1)[1].strip().strip('\'"')
        elif section == 'sources' and indent == 6 and body.startswith('- '):
            item = body[2:].strip()
            if item.startswith('path:'):
                item = item.split(':', 1)[1].strip()
            elif re.match(r'[\w-]+\s*:', item) or item.startswith(('[', '{')):
                current['unparsed'] = True    # a source entry in a shape this reader does not know
            entry, in_excludes = (item.strip('\'"'), []), False
            current['sources'].append(entry)
        elif section == 'sources' and entry and indent == 8:
            in_excludes = body == 'excludes:'
            if re.match(r'(?:excludes|includes)\s*:\s*[^\s]', body):
                current['unparsed'] = True    # `excludes: [a, b]` inline
        elif section == 'sources' and entry and in_excludes and indent == 10 and body.startswith('- '):
            entry[1].append(body[2:].strip().strip('\'"'))
        if current is not None:
            current['text'].append(body)
    return targets


def app_process_filter(text: str):
    """A predicate over repo paths: is this file compiled into the app's own process? Files of an extension target
    (Share, Browser text, widget) run in the extension's process, so the app's main thread never waits on them; files
    no target lists (the Watch app) or a target excludes are not built at all. Only paths under App/ are judged;
    None when project.yml names no application target."""
    apps = [t for t in parse_project(text).values() if t['type'] == 'application']
    if not apps or any(t['unparsed'] for t in apps):  # an entry this reader does not know: scan everything
        return None
    roots = [(path.rstrip('/'), excludes) for t in apps for path, excludes in t['sources']]
    if not roots:
        return None

    def built(rel: str) -> bool:
        if not rel.startswith('App/'):
            return True
        for path, excludes in roots:
            if rel == path or rel.startswith(path + '/'):
                tail = rel[len(path) + 1:]
                if not any(tail == e or tail.startswith(e.rstrip('/') + '/') for e in excludes):
                    return True
        return False
    return built


def project_build(root: Path):
    """(built predicate or None, properties whose project.yml flag is false). Both empty when there is no project.yml."""
    path = root / PROJECT
    if not path.is_file():
        return None, frozenset()
    text = path.read_text(errors='replace')
    app_text = '\n'.join('\n'.join(t['text']) for t in parse_project(text).values() if t['type'] == 'application')
    off = frozenset(prop for key, prop in BUILD_FLAGS.items() if re.search(r'^\s*' + key + r':\s*false\s*$', app_text, re.M))
    return app_process_filter(text), off


# --- Source text -------------------------------------------------------------------------------------------------


def blank(src: str) -> str:
    """The source with comments and string literals (interpolations included) blanked, keeping every newline, so a
    position in the result is the same line and column in the file."""
    out = list(src)
    n, i = len(src), 0

    def wipe(a: int, b: int) -> None:
        for k in range(a, min(b, n)):
            if out[k] != '\n':
                out[k] = ' '

    while i < n:
        c = src[i]
        if c == '/' and src.startswith('//', i):
            j = src.find('\n', i)
            j = n if j < 0 else j
            wipe(i, j)
            i = j
        elif c == '/' and src.startswith('/*', i):
            depth, j = 1, i + 2
            while j < n and depth:
                if src.startswith('/*', j):
                    depth, j = depth + 1, j + 2
                elif src.startswith('*/', j):
                    depth, j = depth - 1, j + 2
                else:
                    j += 1
            wipe(i, j)
            i = j
        elif c in '"#':
            m = re.compile(r'(#*)(""")|(#*)"').match(src, i)
            if not m or (c == '#' and not (m.group(1) or m.group(3))):
                i += 1
                continue
            hashes = m.group(1) if m.group(2) else m.group(3)
            keep = []
            multi = bool(m.group(2))
            close = ('"""' if multi else '"') + hashes
            j = m.end()
            while j < n and not src.startswith(close, j):
                if src[j] == '\\' and src.startswith('\\' + hashes + '(', j):
                    depth, j = 1, j + len(hashes) + 2
                    inner_start = j
                    while j < n and depth:
                        depth += {'(': 1, ')': -1}.get(src[j], 0)
                        j += 1
                    keep.append((inner_start, j - 1))  # an interpolation is code: scanned, not blanked
                elif src[j] == '\\' and not hashes:
                    j += 2
                elif src[j] == '\n' and not multi:
                    break  # an unterminated literal: stop at the line end, never swallow the file
                else:
                    j += 1
            j = min(n, j + len(close)) if src.startswith(close, j) else j
            wipe(i, j)
            for a, b in keep:
                out[a:b] = blank(src[a:b])
            i = j
        else:
            i += 1
    return ''.join(out)


def debug_lines(raw: str) -> set:
    """Line numbers inside `#if DEBUG … #endif` (an `#else` ends the debug part)."""
    lines, stack, found = raw.split('\n'), [], set()
    for number, line in enumerate(lines, 1):
        text = line.strip()
        if text.startswith('#if'):
            stack.append(text.replace(' ', '') in ('#ifDEBUG', '#if(DEBUG)') or text.replace(' ', '') == '#ifDEBUG')
        elif text.startswith('#else') or text.startswith('#elseif'):
            if stack:
                stack[-1] = False
        elif text.startswith('#endif'):
            if stack:
                stack.pop()
        elif any(stack):
            found.add(number)
    return found


# --- Scopes ------------------------------------------------------------------------------------------------------

MODIFIERS = (r'(?:(?:@\w+(?:\([^)]*\))?|public|private|internal|fileprivate|open|final|static|class|override|mutating|'
             r'nonmutating|convenience|required|nonisolated(?:\(unsafe\))?|lazy|indirect|dynamic|package|weak|unowned|'
             r'isolated|distributed)\s+)*')
TYPE_DECL = re.compile(r'^' + MODIFIERS + r'(class|struct|enum|actor|protocol)\s+(\w+)(.*)$')
EXT_DECL = re.compile(r'^' + MODIFIERS + r'extension\s+([\w.]+)(.*)$')
FUNC_DECL = re.compile(r'^' + MODIFIERS + r'(?:func\s+([^\s(<]+)|(init)\b|(deinit)\b|(subscript)\b)(.*)$')
VAR_DECL = re.compile(r'^' + MODIFIERS + r'(?:var|let)\s+(\w+)')
ATTR_ONLY = re.compile(r'^\s*(?:(?:@\w+(?:\([^)]*\))?|public|private|internal|fileprivate|open|final|static|class|override|'
                       r'mutating|nonmutating|convenience|required|nonisolated|lazy|indirect|dynamic|package)\s*)+$')
LOOP_CALLS = re.compile(r'\.(map|flatMap|compactMap|filter|forEach|reduce|sorted|sort|allSatisfy|first|firstIndex|'
                        r'lastIndex|contains|removeAll|min|max|mapValues|compactMapValues)\s*(\([^)]*\))?\s*$')
CONTROL = re.compile(r'^(?:\w+:\s*)?(if|guard|for|while|switch|else|do|catch|defer|repeat)\b')
QUEUE_CALL = re.compile(r'\b(\w+)\s*\.\s*(?:async|asyncAfter|sync)\s*(?:\([^{}]*\))?\s*$')
TASK_HEADER = re.compile(r'(?<![\w.])Task(?:<[^>]*>)?\s*(?:\([^)]*\))?\s*$')


class Scope:
    __slots__ = ('kind', 'name', 'iso', 'start', 'end', 'async_', 'nonisolated', 'loop', 'labelled', 'ext', 'conforms', 'header', 'parent', 'queue')

    def __init__(self, kind, name='', iso=None, start=0):
        self.kind, self.name, self.iso, self.start, self.end = kind, name, iso, start, None
        self.async_ = self.nonisolated = self.loop = self.labelled = False
        self.ext = False
        self.conforms = ()
        self.header = ''
        self.parent = None
        self.queue = None


def last_statement(segment: str) -> str:
    """The declaration or call a `{` belongs to: the last logical line of the text since the previous brace, joined
    with the lines it continues (open parentheses, a leading `.`, attribute-only lines above it)."""
    lines = [ln for ln in segment.split('\n') if ln.strip() and not ln.strip().startswith('#')]
    if not lines:
        return ''
    index = len(lines) - 1
    text = lines[index]
    while index > 0:
        unbalanced = text.count(')') > text.count('(') or text.count(']') > text.count('[')
        previous = lines[index - 1]
        continues = (text.lstrip().startswith(('.', '&&', '||', '?', ':', '->', 'where ')) or unbalanced
                     or previous.rstrip().endswith((',', '(', '->', '&&', '||', '=', '.'))
                     or bool(ATTR_ONLY.match(previous)))
        if not continues:
            break
        index -= 1
        text = lines[index] + '\n' + text
    return ' '.join(text.split())


def classify(header: str, after: str) -> Scope:
    h = header
    scope = Scope('block')
    attrs = set(re.findall(r'@(\w+)', h))
    word = re.match(r'^' + MODIFIERS, h).group(0)
    nonisolated = bool(re.search(r'\bnonisolated\b', word))
    m = TYPE_DECL.match(h)
    if m:
        scope.kind, scope.name = 'type', m.group(2)
        rest = m.group(3)
        conforms = re.findall(r'\b([A-Z]\w*)', rest.split(' where ')[0]) if ':' in rest else []
        scope.conforms = tuple(conforms)
        if m.group(1) == 'actor':
            scope.iso = 'off'
        elif 'MainActor' in attrs or MAIN_PROTOCOLS & set(conforms) or any(UIKIT_MAIN.match(c) for c in conforms):
            scope.iso = 'main'
        return scope
    m = EXT_DECL.match(h)
    if m:
        scope.kind, scope.name, scope.ext = 'type', m.group(1).split('.')[-1], True
        conforms = re.findall(r'\b([A-Z]\w*)', m.group(2).split(' where ')[0]) if ':' in m.group(2) else []
        if 'MainActor' in attrs or MAIN_PROTOCOLS & set(conforms):
            scope.iso = 'main'
        return scope
    m = FUNC_DECL.match(h)
    if m:
        scope.kind = 'func'
        scope.name = m.group(1) or m.group(2) or m.group(3) or m.group(4)
        scope.async_ = bool(re.search(r'\basync\b', m.group(5) or ''))
        scope.nonisolated = nonisolated
        if 'MainActor' in attrs:
            scope.iso = 'main'
        return scope
    m = VAR_DECL.match(h)
    # `let n = try await Task.detached { … }.value` is a closure in an initialiser, not a computed property
    if m and not re.match(r'^' + MODIFIERS + r'(?:var|let)\s+\w+\s*(?::[^={]*)?=(?!=)', h):
        scope.kind, scope.name = 'var', m.group(1)
        if 'MainActor' in attrs:
            scope.iso = 'main'
        return scope
    if CONTROL.match(h):
        scope.loop = bool(re.match(r'^(?:\w+:\s*)?(for|while|repeat)\b', h))
        return scope
    # closures and everything else
    # `offMain` is the app's wrapper around Task.detached, `onRowQueue` the podcast coordinator's wrapper around its row queue, `preparationWrite` the audio-preparation pass's wrapper around `StoreReader(store).readInOrder` (#2509); `StoreReader(store).read { }` is SessionKit's (#2507)
    if re.search(r'\bTask\s*\.\s*detached\b|\b(?:offMain|onRowQueue|preparationWrite)\b|\bStoreReader\b|\b\w*[rR]eader\s*\.\s*(?:read|readLatest)\b', h):
        scope.kind, scope.iso = 'task', 'off'
    elif TASK_HEADER.search(h):
        scope.kind = 'task'
    elif re.search(r'\b(addTask|addTaskUnlessCancelled)\b|\basync\s+let\b', h):
        scope.iso = 'off'
    elif re.search(r'\bMainActor\s*\.\s*(run|assumeIsolated)\b|\bDispatchQueue\s*\.\s*main\b|\bOperationQueue\s*\.\s*main\b', h):
        scope.iso = 'main'
    elif re.search(r'\bDispatchQueue\b|\b\w*[qQ]ueue\w*\s*\.\s*(async|sync|asyncAfter)\b', h):
        scope.iso = 'off'
    else:
        queue = QUEUE_CALL.search(h)  # `writer.async { … }`: off the main thread if `writer` is a queue the file made
        if queue:
            scope.queue = queue.group(1)
    if re.match(r'\s*(?:\[[^\]]*\]\s*)?@MainActor\b', after):
        scope.iso = 'main'
    if re.search(r'\b(?:\w*Labels|labels)\s*\.\s*(?:shared\s*\.\s*)?scoped\s*\(|\bhangLabel\b', h):
        scope.labelled = True
    if LOOP_CALLS.search(h):
        scope.loop = True
    return scope


def parse_scopes(text: str):
    """Every `{ … }` of a blanked source as a Scope with its span, in opening order."""
    scopes, stack, segment = [], [], 0
    for i, c in enumerate(text):
        if c == '{':
            header = last_statement(text[segment:i])
            scope = classify(header, text[i + 1:i + 80])
            scope.start, scope.header = i, header
            scope.parent = stack[-1] if stack else None
            scopes.append(scope)
            stack.append(scope)
            segment = i + 1
        elif c == '}':
            if stack:
                stack.pop().end = i
            segment = i + 1
        elif c == ';':
            segment = i + 1
    for scope in stack:
        scope.end = len(text)
    return scopes


# --- Findings ----------------------------------------------------------------------------------------------------


def store_apis(root: Path) -> dict:
    """Public function name -> (class of a call with no arguments, class of a call with arguments), from the
    store's own source, so a new store API is recognised at once. `loadSessions()` reads every session;
    `loadSessions(itemId:)` reads one item's, so the overloads are told apart by the call, not the name."""
    sigs = defaultdict(list)
    folder = root / STORE_FILES
    sig = re.compile(r'public func (\w+)\(([^)]*)\)')
    for path in sorted(folder.glob('*.swift')) if folder.is_dir() else []:
        text = blank(path.read_text(errors='replace'))
        if 'SQLiteSessionStore' not in text:
            continue
        for name, params in sig.findall(text):
            parts = [p for p in params.split(',') if p.strip()]
            sigs[name].append((not parts, bool(parts) and all('=' in p for p in parts)))
    for name in FALLBACK_STORE_APIS:
        sigs.setdefault(name, [(False, False)])
    found = {}
    for name, forms in sigs.items():
        if name.startswith(WRITE_PREFIXES):
            found[name] = ('store-write', 'store-write')
        elif name.startswith(('load', 'list', 'all', 'quarantined', 'source', 'transcript', 'item', 'failed', 'has')):
            required = [f for f in forms if not f[0] and not f[1]]
            with_args = 'store-heavy-decode' if name in HEAVY_DECODE else 'store-read'
            if not required:
                with_args = 'store-whole-table-read'
            bare = 'store-whole-table-read' if any(f[0] or f[1] for f in forms) else with_args
            found[name] = (bare, with_args)
    return found


def patterns(apis: dict):
    names = '|'.join(sorted(apis, key=len, reverse=True))
    store = re.compile(r'(?<![\w.])(?:self\s*\.\s*)?(?:\w*[sS]tore\w*|repository)(?:\s*\(\s*\))?\s*[?!]?\s*\.\s*(' + names + r')\s*\(')
    other = [
        ('file-io', 'Data(contentsOf:)', re.compile(r'\b(?:NS)?Data\s*\(\s*contentsOf(?:File)?\s*:')),
        ('file-io', 'String(contentsOf:)', re.compile(r'\bString\s*\(\s*contentsOf(?:File)?\s*:')),
        ('file-io', 'contentsOfDirectory', re.compile(r'\.\s*(?:contentsOfDirectory|subpathsOfDirectory|subpaths)\s*\(')),
        ('file-io', 'enumerator(at:)', re.compile(r'\.\s*enumerator\s*\(\s*(?:at|atPath)\s*:')),
        ('file-io', 'attributesOfItem', re.compile(r'\.\s*attributesOfItem\s*\(')),
        ('file-io', 'copy/move/removeItem', re.compile(r'\.\s*(copyItem|moveItem|removeItem|replaceItemAt)\s*\(')),
        ('file-io', 'write(to:)', re.compile(r'\.\s*write\s*\(\s*to\s*:')),
        ('file-io', 'FileHandle', re.compile(r'\bFileHandle\s*\(\s*for(?:Reading|Writing|Updating)')),
        ('file-io', 'SHA256', re.compile(r'\b(?:SHA256|SHA512|Insecure\s*\.\s*(?:MD5|SHA1))\s*\.\s*hash\s*\(|\bCC_SHA\d+\s*\(')),
        ('store-read', 'SQLiteSessionStore.init', re.compile(r'\bSQLiteSessionStore\s*\(\s*path\s*:')),
        ('av-sync', 'AVAudioFile', re.compile(r'\bAVAudioFile\s*\(\s*forReading')),
        ('av-sync', 'AVAudioPlayer', re.compile(r'\bAVAudioPlayer\s*\(\s*contentsOf')),
        ('av-sync', 'AVAssetReader', re.compile(r'\bAV(?:AssetReader|AssetExportSession|AssetWriter)\s*\(')),
        ('av-sync', 'asset.duration/tracks', re.compile(r'\b\w*[aA]sset\w*\s*[?!]?\s*\.\s*(?:duration|tracks|metadata|commonMetadata|chapterMetadataGroups)\b(?!\s*\()|\.\s*tracks\s*\(\s*withMediaType')),
        ('av-sync', 'audioMix/tap', re.compile(r'\bMTAudioProcessingTapCreate\b|\.\s*audioMix\s*=')),
        ('av-sync', 'AVAudioSession.setActive', re.compile(r'\.\s*setActive\s*\(')),
    ]
    return store, other


def area_of(path: str) -> str:
    name = Path(path).name
    for area, rx in AREAS:
        if rx.search(name):
            return area
    return 'groundwork'


def line_of(starts, pos):
    lo, hi = 0, len(starts)
    while lo < hi:
        mid = (lo + hi) // 2
        if starts[mid] <= pos:
            lo = mid + 1
        else:
            hi = mid
    return lo


class FileScan:
    def __init__(self, rel, raw):
        self.rel, self.raw = rel, raw
        self.text = blank(raw)
        self.scopes = parse_scopes(self.text)
        self.starts = [0] + [m.end() for m in re.finditer(r'\n', self.text)]
        self.debug = debug_lines(raw)
        self._by_kind = {}
        self._words = None
        self._starts = None

    @property
    def words(self):
        """Every word of the source, strings and comments included, as a set (a cheap test for whether a name is mentioned)."""
        if self._words is None:
            self._words = set(re.findall(r'\w+', self.raw))
        return self._words

    def enclosing(self, kind, pos):
        """The innermost scope of `kind` containing `pos`, or None: stack_at without walking every scope."""
        if kind not in self._by_kind:
            scopes = [sc for sc in self.scopes if sc.kind == kind]
            self._by_kind[kind] = ([sc.start for sc in scopes], scopes)
        starts, scopes = self._by_kind[kind]
        i = bisect.bisect_left(starts, pos) - 1
        while i >= 0:
            sc = scopes[i]
            if sc.start < pos < (sc.end if sc.end is not None else 1 << 60):
                return sc
            i -= 1
        return None

    def stack_at(self, pos):
        """Every scope containing `pos`, outermost first."""
        if self._starts is None:
            self._starts = [sc.start for sc in self.scopes]
        i = bisect.bisect_left(self._starts, pos) - 1
        while i >= 0 and not (self.scopes[i].start < pos < (self.scopes[i].end if self.scopes[i].end is not None else 1 << 60)):
            i -= 1
        chain = []
        sc = self.scopes[i] if i >= 0 else None
        while sc is not None:
            chain.append(sc)
            sc = sc.parent
        return chain[::-1]


def decl_name(stack):
    parts = []
    for s in stack:
        if s.kind == 'type':
            parts = [s.name]
        elif s.kind in ('func', 'var'):
            parts.append(s.name)
    return '.'.join(parts[:1] + parts[-1:]) if len(parts) > 1 else (parts[0] if parts else '<top>')


def func_key(rel, stack):
    """(type, function) of the innermost named function or property, for the helper table."""
    kind_type = next((s.name for s in reversed(stack) if s.kind == 'type'), None)
    fn = next((s.name for s in reversed(stack) if s.kind in ('func', 'var')), None)
    return (rel, kind_type, fn) if fn else None


def context(stack, main_types):
    """'main', 'off' (a background context) or 'caller' (a sync helper: it runs wherever it is called from)."""
    async_seen, seen_fn = False, False
    for s in reversed(stack):
        if s.iso in ('main', 'off'):
            return s.iso
        if s.kind == 'func':
            if not seen_fn:
                async_seen, seen_fn = s.async_, True
            if s.nonisolated:
                return 'off' if async_seen else 'caller'
        elif s.kind == 'task' and not seen_fn:
            async_seen, seen_fn = True, True
        elif s.kind == 'type':
            if s.name in main_types:
                return 'main'
            return 'off' if async_seen else 'caller'
    return 'off' if async_seen else 'caller'


def in_loop(stack):
    for s in reversed(stack):
        if s.kind in ('func', 'type'):
            return False
        if s.loop:
            return True
    return False


def is_labelled(stack):
    return any(s.labelled for s in stack)


def enclosing_task(stack, main_types):
    """The outermost Task { } scope at or below the first function that itself runs on the main thread (the work
    the hang probe can't name). A `Task.detached` or a Task in a background type is not one: a main-thread read in
    a `MainActor.run` hop inside it belongs to no main-thread Task, and neither do its outer Tasks (#2514)."""
    task = None
    for i in range(len(stack) - 1, -1, -1):
        s = stack[i]
        if s.kind in ('func', 'type', 'var'):
            break
        if s.kind == 'task':
            if context(stack[:i + 1], main_types) != 'main':
                break
            task = s
    return task


def read_sources(root: Path, left_out=None):
    """(path, source) of every Swift file the scan covers. `left_out`, if given, collects the files that project.yml
    says are not part of the app's process (see app_process_filter)."""
    built, _ = project_build(root)
    files = []
    for top in SCAN_DIRS:
        base = root / top
        if not base.is_dir():
            continue
        for path in sorted(base.rglob('*.swift')):
            rel = path.relative_to(root).as_posix()
            if re.search(r'Tests?(/|$)|UITests|/\.build/|/Pods/|Preview Content', rel):
                continue
            if built and not built(rel):
                if left_out is not None:
                    left_out.append(rel)
                continue
            files.append((rel, path.read_text(errors='replace')))
    return files


class Unreachable:
    """Positions and functions that never run in a shipping build: after a `guard <flag>` (or in `if <flag> {`) of a
    BUILD_FLAGS property whose project.yml value is false, inside `#if DEBUG`, or a function whose every call sits in
    such code. A function counts only when it has one definition in the scan and every mention of its name (a call,
    a button's `action:`, `#selector`) sits in such code, so a lookalike with a live caller stays a row."""

    def __init__(self, regions, dead_functions):
        self.regions, self.dead_functions = regions, dead_functions

    def reason(self, fs, pos, stack):
        if any(a <= pos < b for a, b in self.regions.get(fs.rel, ())):
            return 'flag-off'
        fn = next((x.name for x in reversed(stack) if x.kind == 'func'), None)
        if fn in self.dead_functions:
            return 'debug-or-flag-off-callers-only'
        return None


def unreachable(scans, by_rel, off_props):
    regions = defaultdict(list)      # file -> [(start, end)] of text that never runs
    for fs in scans:
        for prop in off_props & fs.words:
            name = r'(?:self\s*\.\s*)?' + prop + r'\b'
            for m in re.finditer(r'\bguard\s+' + name + r'\s*(?:,|else\b)', fs.text):
                else_open = re.compile(r'\belse\s*\{').search(fs.text, m.start())
                else_block = next((x for x in fs.scopes if else_open and x.start == else_open.end() - 1), None)
                outer = fs.stack_at(m.start())
                if else_block is not None and else_block.end is not None and outer:
                    end = outer[-1].end if outer[-1].end is not None else len(fs.text)
                    case = None
                    if outer[-1].header.startswith('switch'):  # the guard sits in a case body: the next case is live
                        case = re.compile(r'\n[ \t]*(?:case\b[^\n]*|default\s*):').search(fs.text, else_block.end, end)
                    regions[fs.rel].append((else_block.end, case.start() if case else end))
            for m in re.finditer(r'\bif\s+' + name + r'\s*\{', fs.text):
                block = next((x for x in fs.scopes if x.start == m.end() - 1), None)
                if block is not None and block.end is not None:
                    regions[fs.rel].append((block.start, block.end))

    single = {}                      # function name -> (file scan, scope), for names with exactly one definition
    count = Counter()
    for fs in scans:
        for sc in fs.scopes:
            if sc.kind == 'func' and sc.name not in ('init', 'deinit', 'subscript'):
                count[sc.name] += 1
                single[sc.name] = (fs, sc)
                if re.search(r'@objc\b|\boverride\b', sc.header):  # the system calls these, with no mention to see
                    count[sc.name] += 1
    single = {n: v for n, v in single.items() if count[n] == 1}
    word = re.compile(r'\w+')

    def static_dead(fs, pos):
        return line_of(fs.starts, pos) in fs.debug or any(a <= pos < b for a, b in regions.get(fs.rel, ()))

    def names_in(text):
        return {w for w in word.findall(text) if w in single}  # raw text: a name in a string (`Selector("x")`) is a mention

    # Names that can be dead are the ones mentioned in dead code; a dead function's body then names more of them.
    candidates = set()
    for fs in scans:
        lines = fs.raw.split('\n')
        candidates |= names_in('\n'.join(lines[n - 1] for n in fs.debug if n <= len(lines)))
        for a, b in regions.get(fs.rel, ()):
            candidates |= names_in(fs.raw[a:b])
    dead = set()
    while True:
        uses = defaultdict(list)     # candidate name -> [(file scan, position)]
        for fs in scans:
            hit = candidates & fs.words
            if hit:
                for m in re.finditer(r'\b(?:' + '|'.join(sorted(hit)) + r')\b', fs.raw):
                    if not re.search(r'\bfunc\s+$', fs.raw[max(0, m.start() - 8):m.start()]):
                        uses[m.group(0)].append((fs, m.start()))

        def in_dead_code(fs, pos, others):
            if static_dead(fs, pos):
                return True
            fn = fs.enclosing('func', pos)
            return fn is not None and fn.name in others

        new = {n for n, sites_ in uses.items() if n not in dead and sites_ and all(in_dead_code(fs, pos, dead - {n}) for fs, pos in sites_)}
        if not new:
            break
        dead |= new
        for n in new:
            fs, sc = single[n]
            candidates |= names_in(fs.raw[sc.start:sc.end])
    return Unreachable(regions, dead)


def mark_serial_queues(scans):
    """`writer.async { … }` runs on `writer`'s queue when the file made `writer` with `DispatchQueue(label:…)`. A queue
    that is only an alias (`let ui = DispatchQueue.main`) or a scheduler object with an `.async` method stays main."""
    for fs in scans:
        for sc in fs.scopes:
            if sc.queue and re.search(r'\b(?:let|var)\s+' + re.escape(sc.queue) + r'\b[^=\n]*=\s*DispatchQueue\s*\(', fs.text):
                sc.iso = 'off'


def scan(files, apis, off_props=frozenset()):
    """All rows for the given (path, source) pairs, and counts of what could not be resolved or never runs
    (`off_props`: model properties whose project.yml flag is false, see BUILD_FLAGS)."""
    store_rx, other = patterns(apis)
    scans = [FileScan(rel, raw) for rel, raw in files]
    by_rel = {fs.rel: fs for fs in scans}
    main_types = {s.name for fs in scans for s in fs.scopes if s.kind == 'type' and s.iso == 'main' and not s.ext}

    mark_serial_queues(scans)

    # Every function that runs on the main thread or on its caller's thread. A nonisolated async function runs
    # elsewhere, so a call to it leaves the main thread and is not followed.
    funcs = defaultdict(list)         # function name -> [(file, type, ctx)]
    for fs in scans:
        for s in fs.scopes:
            if s.kind == 'func' and s.name not in ('init', 'deinit', 'subscript'):
                stack = fs.stack_at(s.start + 1)
                ctx = context(stack, main_types)
                if ctx in ('main', 'caller'):
                    funcs[s.name].append((fs.rel, next((x.name for x in reversed(stack[:-1]) if x.kind == 'type'), None), ctx))

    type_files = defaultdict(set)     # type name -> files that declare or extend it
    for fs in scans:
        for s in fs.scopes:
            if s.kind == 'type':
                type_files[s.name].add(fs.rel)
    decl_rx = re.compile(r'(?:\b(?:let|var)\s+|[(,]\s*(?:\w+\s+)?)(\w+)\s*(?::\s*\[?([A-Z]\w*)|=(?!=)\s*([^\n;{]*))')
    decl_cache = {}

    def declarations(rel, var):
        """Where `var` is declared in a file: [(position, annotated type or None, initialiser text or None)]."""
        if rel not in decl_cache:
            index = defaultdict(list)
            for m in decl_rx.finditer(by_rel[rel].text):
                index[m.group(1)].append((m.start(), m.group(2), m.group(3)))
            decl_cache[rel] = index
        return decl_cache[rel].get(var, [])

    def declared(rel, here, pos, var):
        """What `var` was declared as: the nearest declaration above the call in this file (a local, a parameter or
        a property), else a property in another file of the enclosing type. Returns (annotated types, initialisers)."""
        before = [d for d in declarations(rel, var) if d[0] < pos]
        found = before[-1:] or [d for r in sorted(type_files.get(here, set()) - {rel}) for d in declarations(r, var)]
        return {t for _, t, _ in found if t}, [i for _, t, i in found if not t and i]

    def pick_by_variable(cands, rel, here, pos, var):
        """The callee of `var.name(` when the receiver is a variable: its annotated type (`var engine:
        SessionEngine?`), else the type its initialiser names (`let s = try resolvedSourceLinkHandoffStore()`), else a
        type named like it (`sessionEngine` -> SessionEngine, `engine` -> …Engine), else a type containing it. A tier
        that still names two types is ambiguous and returns None, never the first file's."""
        typed = [c for c in cands if c[1]]
        annotated, inits = declared(rel, here, pos, var)
        if annotated:  # the type is known; a protocol or a type with no such helper is not guessed past
            return [c for c in typed if c[1] in annotated]
        named = [c for c in typed if any(c[1] in i for i in inits)]
        longest = max((len(c[1]) for c in named), default=0)
        cap = var[:1].upper() + var[1:]
        tiers = [
            [c for c in named if len(c[1]) == longest],
            [c for c in typed if c[1] == cap],
            [c for c in typed if c[1].endswith(cap)],
            [c for c in typed if len(var) > 2 and var.lower() in c[1].lower()],
        ]
        for tier in tiers:
            if tier:
                return tier if len({c[1] for c in tier}) == 1 else None
        return []

    rows, skipped = [], Counter()
    direct = defaultdict(set)         # function key -> {(class, api)} read on the thread that runs it
    calls = defaultdict(list)         # function key -> [callee keys]
    sites = []                        # calls made on the main thread: (file, line, stack, callee key, callee ctx)
    name_rx = re.compile(r'(?<![\w])(\w+)\s*\(')

    for fs in scans:
        for rx_class, api0, rx in [('store', None, store_rx)] + list(other):
            for m in rx.finditer(fs.text):
                if rx_class == 'store':
                    name = m.group(1)
                    bare = re.compile(r'\s*\)').match(fs.text, m.end())
                    klass, api = apis[name][0 if bare else 1], f'store.{name}'
                else:
                    klass, api = rx_class, api0
                stack = fs.stack_at(m.start())
                ctx = context(stack, main_types)
                if ctx not in ('main', 'caller'):
                    continue
                key = func_key(fs.rel, stack)
                if key:
                    direct[key].add((klass, api))
                if ctx == 'main':
                    line = line_of(fs.starts, m.start())
                    rows.append({'file': fs.rel, 'line': line, 'function': decl_name(stack), 'api': api, 'class': klass,
                                 'in_loop': in_loop(stack), 'labelled': is_labelled(stack), 'debug': line in fs.debug,
                                 'kind': 'direct', 'area': area_of(fs.rel), '_stack': stack, '_pos': m.start()})
        for m in name_rx.finditer(fs.text):
            name = m.group(1)
            if name not in funcs:
                continue
            if re.search(r'\bfunc\s+$', fs.text[max(0, m.start() - 12):m.start()]):
                continue
            stack = fs.stack_at(m.start())
            ctx = context(stack, main_types)
            if ctx not in ('main', 'caller'):
                continue
            here = next((x.name for x in reversed(stack) if x.kind == 'type'), None)
            qual = re.search(r'(\w+)\s*[?!]?\s*\.\s*$', fs.text[max(0, m.start() - 60):m.start()])
            cands = funcs[name]
            if qual:
                q = here if qual.group(1) in ('self', 'Self') else qual.group(1)
                if q[:1].isupper() or q == here:
                    picked = [c for c in cands if c[1] == q]
                else:  # a variable: `engine.run` is a SessionEngine's when the name says so, else it is not guessed
                    picked = pick_by_variable(cands, fs.rel, here, m.start(), q)
                    if picked is None:
                        skipped['ambiguous-callee'] += 1
                        continue
            else:
                picked = [c for c in cands if c[1] == here] or [c for c in cands if c[1] is None]
            if not picked:
                skipped['unresolved-callee'] += 1
                continue
            callee = (picked[0][0], picked[0][1], name)
            here_key = func_key(fs.rel, stack)
            if here_key and callee != here_key:
                calls[here_key].append(callee)
            if ctx == 'main':
                sites.append((fs, line_of(fs.starts, m.start()), stack, callee, picked[0][2], m.start()))

    # Fixed point: a function's reads include the reads of the functions it calls on its own thread.
    summary = {k: set(v) for k, v in direct.items()}
    for _ in range(MAX_HELPER_DEPTH):
        changed = False
        for key, callees in calls.items():
            mine = summary.setdefault(key, set())
            for callee in callees:
                extra = summary.get(callee, set()) - mine
                if extra:
                    mine |= extra
                    changed = True
        if not changed:
            break

    reach = []                        # rows that only feed the unlabelled-Task check
    for fs, line, stack, callee, callee_ctx, pos in sites:
        reads = summary.get(callee)
        if not reads:
            continue
        row = {'file': fs.rel, 'line': line, 'function': decl_name(stack), 'in_loop': in_loop(stack),
               'labelled': is_labelled(stack), 'debug': line in fs.debug, 'area': area_of(fs.rel), '_stack': stack,
               '_pos': pos, 'api': 'via ' + (f'{callee[1]}.' if callee[1] else '') + callee[2],
               'class': min((c for c, _ in reads), key=CLASS_PRIORITY.index),
               'detail': sorted({a for _, a in reads})}
        if callee_ctx == 'caller':
            rows.append({**row, 'kind': 'helper'})   # the helper's reads happen here, on the main thread
        else:
            reach.append(row)                        # a main-actor callee reports its own reads where they are

    # A Task { } on the main thread whose reads the hang probe cannot name (#2255): one row per outermost Task that
    # holds a main-thread read, directly or through a call, and no `labels.scoped(` anywhere around it.
    groups = defaultdict(list)
    for row in rows + reach:
        task = enclosing_task(row['_stack'], main_types)
        if task is not None:
            groups[(row['file'], task.start)].append(row)
    extra = []
    for (rel, start), inner in groups.items():
        if any(r['labelled'] for r in inner):
            continue
        stack = inner[0]['_stack']
        stack = stack[:next(i for i, sc in enumerate(stack) if sc.start == start) + 1]
        line = line_of(by_rel[rel].starts, start)
        extra.append({'file': rel, 'line': line, 'function': decl_name(stack), 'api': 'Task {}',
                      'class': 'unlabelled-main-task', 'in_loop': False, 'labelled': False,
                      'debug': line in by_rel[rel].debug, 'kind': 'task', 'area': area_of(rel),
                      'detail': sorted({r['api'] for r in inner}), '_pos': start, '_stack': stack})
    # Code that never runs in a shipping build is not main-thread work (#2514).
    dead = unreachable(scans, by_rel, off_props)
    kept = []
    for r in rows + extra:
        why = dead.reason(by_rel[r['file']], r['_pos'], r['_stack'])
        if why:
            skipped[why] += 1
        else:
            kept.append(r)
    final = [{k: v for k, v in r.items() if not k.startswith('_')} for r in kept]
    final.sort(key=lambda r: (r['file'], r['line'], r['api']))
    return final, skipped


# --- Baseline and report -----------------------------------------------------------------------------------------


def key_of(row):
    """A row's identity: enclosing type.function, API and class. Not the file, so moving a read to another file (a
    split, an extension move) keeps its baseline row (#2256). The file is kept in the baseline for the reader only."""
    return (row['function'], row['api'], row['class'])


def counts(rows):
    c = Counter()
    for r in rows:
        if not r['debug']:
            c[key_of(r)] += 1
    return c


PLACEHOLDER_MARKS = ('not triaged', 'not accepted as correct', 'moved unchanged')


def is_placeholder(reason):
    """An empty reason, or the first-run "not triaged yet" text, says nothing about why the read is on the main thread."""
    r = (reason or '').strip().lower()
    return not r or any(m in r for m in PLACEHOLDER_MARKS) or r in ('todo', 'tbd', 'n/a', 'reason', 'one-line reason')


def placeholder_count(entries):
    return sum(1 for e in entries if is_placeholder(e.get('reason')))


def load_ceiling(path: Path):
    """The placeholder-reason count the baseline allows; it only ever goes down."""
    if not path.exists():
        return 0
    return json.loads(path.read_text()).get('placeholder_ceiling', 0)


def load_baseline(path: Path):
    if not path.exists():
        return {}
    data = json.loads(path.read_text())
    return {(e['function'], e['api'], e['class']): e for e in data['entries']}


def write_baseline(path: Path, entries, ceiling=None):
    now = placeholder_count(entries)
    ceiling = now if ceiling is None else min(ceiling, now)
    head = {'version': 1, 'placeholder_ceiling': ceiling, 'note': 'Main-thread store/file/audio reads that existed when the scanner arrived (#2257). '
            'Keyed by function, API and class (the file is informational, so moving code between files keeps its rows). A fix deletes rows (scripts/main_thread_reads.py --update); a new row '
            'needs --accept "reason". Do not add rows to make a check pass: move the read off the main thread.'}
    lines = [json.dumps(e, sort_keys=True) for e in sorted(entries, key=lambda e: (e['function'], e['api'], e['class'], e['file']))]
    body = ',\n    '.join(lines)
    path.write_text(json.dumps(head, indent=2)[:-2].rstrip() + ',\n  "entries": [\n    ' + body + '\n  ]\n}\n')


def compare(rows, baseline):
    current = counts(rows)
    new, stale = [], []
    for key, n in current.items():
        have = baseline.get(key, {}).get('count', 0)
        if n > have:
            mine = [r for r in rows if key_of(r) == key and not r['debug']]
            new.append((key, n - have, mine[have:]))
    for key, entry in baseline.items():
        if current.get(key, 0) < entry['count']:
            stale.append((key, entry['count'] - current.get(key, 0)))
    return new, stale


def summarize(rows, skipped):
    by_class, by_area, cross = Counter(), Counter(), Counter()
    for r in rows:
        if r['debug']:
            continue
        by_class[r['class']] += 1
        by_area[r['area']] += 1
        cross[(r['class'], r['area'])] += 1
    return {'rows': sum(by_class.values()), 'by_class': dict(by_class), 'by_area': dict(by_area),
            'by_class_and_area': {f'{c} | {a}': n for (c, a), n in sorted(cross.items())},
            'in_loop': sum(1 for r in rows if r['in_loop'] and not r['debug']),
            'debug_only_not_counted': sum(1 for r in rows if r['debug']), 'skipped': dict(skipped)}


def scan_ref(root: Path, rev: str, left_out=None):
    with tempfile.TemporaryDirectory() as tmp:
        archive = subprocess.run(['git', '-C', str(root), 'archive', rev, *ARCHIVE_PATHS], capture_output=True)
        if archive.returncode:
            sys.exit(f'git archive {rev} failed: {archive.stderr.decode()[:200]}')
        subprocess.run(['tar', '-x', '-C', tmp], input=archive.stdout, check=True)
        return read_sources(Path(tmp), left_out), store_apis(Path(tmp)), project_build(Path(tmp))[1]


def main(argv=None, root: Path = ROOT):
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('--root', type=Path, default=root)
    ap.add_argument('--baseline', default=BASELINE)
    ap.add_argument('--ref')
    ap.add_argument('--json', dest='json_out')
    ap.add_argument('--summary', action='store_true')
    ap.add_argument('--update', action='store_true')
    ap.add_argument('--accept', metavar='REASON')
    ap.add_argument('--strict', action='store_true', help='fail on stale baseline rows too')
    args = ap.parse_args(argv)
    root = args.root
    left_out = []
    if args.ref:
        files, apis, off_props = scan_ref(root, args.ref, left_out)
    else:
        files, apis, off_props = read_sources(root, left_out), store_apis(root), project_build(root)[1]
    rows, skipped = scan(files, apis, off_props)
    summary = summarize(rows, skipped)
    if args.json_out:
        Path(args.json_out).write_text(json.dumps({'version': 1, 'ref': args.ref or 'worktree', 'summary': summary,
                                                   'rows': rows}, indent=1) + '\n')
    if args.summary or args.ref:
        summary['not_in_the_app_process'] = sorted(left_out)
        print(json.dumps(summary, indent=2))
        return 0
    baseline_path = root / args.baseline
    baseline = load_baseline(baseline_path)
    ceiling = load_ceiling(baseline_path)
    if args.accept is not None and is_placeholder(args.accept):
        print('main-thread-reads: --accept needs a real one-line reason (why the read is cheap or must stay on main), '
              'not an empty or "not triaged" placeholder.')
        return 2
    new, stale = compare(rows, baseline)
    if args.update or args.accept:
        current = counts(rows)
        files_of = {}
        for r in rows:
            if not r['debug']:
                files_of.setdefault(key_of(r), r['file'])
        entries = []
        for key, n in current.items():
            old = baseline.get(key)
            if old and args.accept and n > old['count']:  # one more call of a baselined read, accepted on its own reason
                entries.append({**old, 'count': n, 'reason': f"{old['reason']}; {args.accept}"})
            elif old:
                entries.append({**old, 'count': min(n, old['count'])})
            elif args.accept:
                entries.append({'file': files_of[key], 'function': key[0], 'api': key[1], 'class': key[2], 'count': n,
                                'reason': args.accept})
        for e in entries:   # the file is informational: follow the code when it moves
            k = (e['function'], e['api'], e['class'])
            if k in files_of:
                e['file'] = files_of[k]
        write_baseline(baseline_path, entries, ceiling)
        print(f'baseline: {len(entries)} entries ({len(stale)} tightened, {len(new) if args.accept else 0} accepted)')
        return 0
    placeholders = placeholder_count(baseline.values())
    if placeholders > ceiling:
        print(f'main-thread-reads: {placeholders} baseline rows have an empty or "not triaged" reason, above the '
              f'ceiling of {ceiling}. Write a one-line reason (or TODO(#slice): ...) instead of a placeholder.')
        return 1
    if stale:
        print(f'main-thread-reads: {len(stale)} baseline row(s) are fixed or gone; run scripts/main_thread_reads.py --update '
              f'to tighten the ratchet.')
        if args.strict:
            return 1
    if new:
        print('main-thread-reads: new main-thread store/file/audio work (not in scripts/main_thread_reads_baseline.json):')
        for key, extra, mine in new:
            for r in mine[:extra] if mine else []:
                note = f" via {r['detail']}" if r.get('detail') else ''
                print(f"  {r['file']}:{r['line']}  {r['function']}  {r['api']}  [{r['class']}]{note}")
        print('Move the read off the main thread (SessionKit async, or Task.detached then publish back). If a row above is '
              'a false positive or a read that must stay, accept it with:')
        print('  python3 scripts/main_thread_reads.py --accept "one-line reason"')
        print('  python3 scripts/main_thread_reads.py --update')
        print('then commit scripts/main_thread_reads_baseline.json. (Rows are keyed by type.function, API and class, so a '
              'read that only moved between files is never listed here.)')
        return 1
    print(f"main-thread-reads: ok ({summary['rows']} baselined rows, {len(files)} files)")
    return 0


if __name__ == '__main__':
    sys.exit(main())
