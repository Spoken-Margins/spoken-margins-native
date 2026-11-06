#!/usr/bin/env python3
"""Guard: a closure handed to a system callback that runs off the main thread must not be main-actor code (#3513).

Under Swift 6 a closure written in `@MainActor` code is main-actor isolated unless it says `@Sendable`. Handed to an
Apple API whose header doesn't mark the parameter `@Sendable`, it compiles, and the compiler puts an isolation check
at its start. When the API calls it on its own queue, the check stops the app. The Watch app crashed at every
launch that way (#2964, `WCSession.sendMessage`'s reply). Nothing warns, and tests that fake the boundary never
reach it.

The inventory came from the compiled app (scripts/isolation_check_inventory.py, verdicts on #3513): of 2,880
isolation checks, the only system callbacks that can arrive off the main thread were the WatchConnectivity reply
and MediaPlayer's remote-command handlers. This scan keeps new ones out. It knows two shapes:

1. A closure handed to one of CALLBACK_APIS must be a literal that starts `{ @Sendable`, so the compiler makes the
   body hop to the main actor itself (`Task { @MainActor in … }`). A `nil` is fine, and so is a `.main` queue where
   the API takes one (`using: .main`); a named function or variable is a row, because the scan can't see its type.
   Background Tasks and the record-permission callbacks aren't in the inventory's unsafe list today (each site is
   on main or nonisolated) but are listed because they call off the main thread.
2. A notification that is posted off the main thread (OFF_MAIN_NOTIFICATIONS) must reach main-actor code through a
   hop. A Combine publisher of one needs `.receive(on:)` before its `sink` (whose closure isn't `@Sendable`). An
   `addObserver(forName:)` block is `@Sendable` in the SDK, so the trap there is `MainActor.assumeIsolated` without
   `queue: .main`. A selector observer is always a row: its `@objc` method on a main-actor type traps the same way.

  scripts/system_callback_isolation.py           check: exit 1 on a row that ALLOWED doesn't name
  scripts/system_callback_isolation.py --list    every matched site and its verdict

Blind spots: an API not in the lists (rerun the binary inventory when adding a new kind of system callback, and add
it here), a closure stored first and handed over later, and code in a nonisolated type, which needs no hop but is
still a row until it says `@Sendable` or ALLOWED names it. Stdlib only, Python 3.9-compatible.
"""
from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

# name: (where the call starts, labels whose closures are checked, the queue label that `.main` makes safe). The
# trailing closure is always checked.
CALLBACK_APIS = {
    'MPRemoteCommand.addTarget(handler:)': (r'\.addTarget\s*(?=\(\s*handler\s*:|\{)', ('handler',), None),
    'WCSession.sendMessage': (r'\.sendMessage(?:Data)?\s*(?=\()', ('replyHandler', 'errorHandler'), None),
    'MPMediaItemArtwork(boundsSize:requestHandler:)':
        (r'\bMPMediaItemArtwork\s*(?=\(\s*boundsSize)', ('requestHandler',), None),
    'BGTaskScheduler.register(forTaskWithIdentifier:using:launchHandler:)':
        (r'\.register\s*(?=\(\s*forTaskWithIdentifier\s*:)', ('launchHandler',), 'using'),
    'requestRecordPermission(_:)': (r'\.requestRecordPermission\s*(?=\(\s*(?:completionHandler\s*:|\{)|\{)',
                                    ('completionHandler',), None),
}

OFF_MAIN_NOTIFICATIONS = (
    'thermalStateDidChangeNotification', 'powerStateDidChangeNotification', 'NSProcessInfoPowerStateDidChange',
    'interruptionNotification', 'routeChangeNotification', 'mediaServicesWereLostNotification',
    'mediaServicesWereResetNotification', 'silenceSecondaryAudioHintNotification', 'AVAudioEngineConfigurationChange',
    'AVPlayerItemDidPlayToEndTime', 'AVPlayerItemFailedToPlayToEndTime', 'AVPlayerItemPlaybackStalled',
    'AVPlayerItemTimeJumped', 'AVPlayerItemNewErrorLogEntry', 'AVPlayerItemNewAccessLogEntry',
    'didPlayToEndTimeNotification', 'failedToPlayToEndTimeNotification', 'playbackStalledNotification',
    'timeJumpedNotification', 'newErrorLogEntryNotification', 'newAccessLogEntryNotification',
    'configurationChangeNotification',
)
NOTIFICATION = r'(?:\.|\b)(?:' + '|'.join(OFF_MAIN_NOTIFICATIONS) + r')\b'

# (file, api): (how many rows, why they are safe without `@Sendable`). A further row in the same file still fails.
ALLOWED = {
    ('Packages/SessionKit/Sources/SessionKitAudio/AudioAdapters.swift', 'MPRemoteCommand.addTarget(handler:)'): (1,
        'AVPlayerStreamPlaybackClient is a nonisolated @unchecked Sendable class: its handlers are not main-actor '
        'code and carry no isolation check (absent from the #3513 binary inventory).'),
}
# A file that names none of these can't have a row; skipping it keeps the scan to a second.
MENTIONS = re.compile(r'addTarget|sendMessage|MPMediaItemArtwork|forTaskWithIdentifier|requestRecordPermission|'
                      r'Notification\b|' + '|'.join(OFF_MAIN_NOTIFICATIONS))


def blank_comments_and_strings(text: str) -> str:
    """The source with comments and string contents replaced by spaces, so offsets and line numbers still hold."""
    out, i, n = list(text), 0, len(text)
    while i < n:
        if text.startswith('//', i):
            end = text.find('\n', i)
            end = n if end < 0 else end
        elif text.startswith('/*', i):
            end = text.find('*/', i + 2)
            end = n if end < 0 else end + 2
        elif text[i] == '"' or (text[i] == '#' and re.match(r'#+"', text[i:])):
            hashes = len(text[i:]) - len(text[i:].lstrip('#'))
            quote = '"""' if text.startswith('"""', i + hashes) else '"'
            opening, closing, escape = '#' * hashes + quote, quote + '#' * hashes, '\\' + '#' * hashes
            end, j = n, i + len(opening)
            while j < n:
                if text.startswith(escape, j):
                    j += len(escape) + 1
                    continue
                if text.startswith(closing, j) or (quote == '"' and text[j] == '\n'):
                    end = j + len(closing)
                    break
                j += 1
            for k in range(i + len(opening), max(i + len(opening), end - len(closing))):
                if out[k] != '\n':
                    out[k] = ' '
            i = end
            continue
        else:
            i += 1
            continue
        for k in range(i, end):
            if out[k] != '\n':
                out[k] = ' '
        i = end
    return ''.join(out)


def matching(text: str, start: int, open_: str, close: str) -> int:
    """Index of the bracket that closes the one at `start`, or len(text)."""
    depth = 0
    for i in range(start, len(text)):
        if text[i] == open_:
            depth += 1
        elif text[i] == close:
            depth -= 1
            if depth == 0:
                return i
    return len(text)


def is_sendable_closure(text: str, brace: int) -> bool:
    return re.match(r'\{\s*@Sendable\b', text[brace:]) is not None


def labelled_arguments(text: str, paren: int):
    """(label, offset of the value) for each `label:` argument at the top level of the call's parentheses."""
    end, depth, starts = matching(text, paren, '(', ')'), 0, [paren + 1]
    for i in range(paren + 1, end):
        if text[i] in '([{':
            depth += 1
        elif text[i] in ')]}':
            depth -= 1
        elif text[i] == ',' and depth == 0:
            starts.append(i + 1)
    args = []
    for at in starts:
        match = re.compile(r'\s*([A-Za-z_]\w*)\s*:\s*').match(text, at, end)
        if match:
            args.append((match.group(1), match.end()))
    return args, end


def callback_rows(path: str, text: str):
    rows = []
    for api, (pattern, labels, queue_label) in CALLBACK_APIS.items():
        for match in re.finditer(pattern, text):
            at, closures = match.end(), []
            if text[at] == '(':
                args, end = labelled_arguments(text, at)
                queue = dict(args).get(queue_label)
                if queue is not None and re.match(r'(?:\.main|DispatchQueue\.main|OperationQueue\.main)\b', text[queue:]):
                    continue
                for label, value in args:
                    if label not in labels:
                        continue
                    if text.startswith('{', value):
                        closures.append((label, value))
                    elif not re.match(r'nil\b', text[value:]):
                        closures.append((label, None))
                after = end + 1
                while after < len(text) and text[after] in ' \t\n':
                    after += 1
                if after < len(text) and text[after] == '{':
                    closures.append(('trailing', after))
            else:
                closures.append(('trailing', at))
            for label, brace in closures:
                line = text.count('\n', 0, match.start()) + 1
                if brace is None:
                    rows.append((path, line, api, f'`{label}:` is not a closure literal, so its isolation is unseen'))
                elif not is_sendable_closure(text, brace):
                    rows.append((path, line, api, f'the {label} closure is not `@Sendable`'))
    return rows


def notification_rows(path: str, text: str):
    rows = []
    for match in re.finditer(r'\.addObserver\s*\(', text):
        paren = match.end() - 1
        args, end = labelled_arguments(text, paren)
        call = text[paren:end]
        if not re.search(NOTIFICATION, call):
            continue
        line = text.count('\n', 0, match.start()) + 1
        api = 'NotificationCenter.addObserver'
        if re.search(r'\bselector\s*:', call):
            rows.append((path, line, api, 'a selector observer of a notification posted off the main thread'))
            continue
        queue = dict(args).get('queue')
        if queue is not None and re.match(r'(?:\.main|OperationQueue\.main)\b', text[queue:]):
            continue
        # The block is `@Sendable` in the SDK, so the compiler keeps main-actor state out of it; the way back in
        # that traps off the main thread is `MainActor.assumeIsolated`.
        after = end + 1
        while after < len(text) and text[after] in ' \t\n':
            after += 1
        block = text[after:matching(text, after, '{', '}')] if text.startswith('{', after) else call
        if 'assumeIsolated' in block:
            rows.append((path, line, api, 'posted off the main thread into `MainActor.assumeIsolated`: use `queue: .main`'))
    for match in re.finditer(r'\.publisher\s*\(\s*for\s*:', text):
        paren = text.index('(', match.start())
        if not re.search(NOTIFICATION, text[paren:matching(text, paren, '(', ')')]):
            continue
        # The chain up to the first closure is where a `.receive(on:)` hop has to be.
        brace = text.find('{', match.end())
        brace = len(text) if brace < 0 else brace
        if re.search(r'\.receive\s*\(\s*on\s*:', text[match.end():brace]) or is_sendable_closure(text, brace):
            continue
        line = text.count('\n', 0, match.start()) + 1
        rows.append((path, line, 'NotificationCenter.publisher', 'posted off the main thread: add `.receive(on:)`'))
    return rows


def scan(sources):
    """Rows for (path, text) pairs: (path, line, api, problem)."""
    rows = []
    for path, text in sources:
        if MENTIONS.search(text):
            clean = blank_comments_and_strings(text)
            rows += callback_rows(path, clean) + notification_rows(path, clean)
    return sorted(rows)


def tree_sources(root: Path = ROOT):
    files = subprocess.run(['git', 'ls-files', '--', 'App/*.swift', 'Packages/*.swift'], cwd=root,
                           capture_output=True, text=True, check=True).stdout.split()
    for name in files:
        # App/SpokenMarginsWatch/ is the old Watch bridge; project.yml builds none of it.
        if '/Tests/' in name or name.endswith('Tests.swift') or name.startswith('App/SpokenMarginsWatch/'):
            continue
        yield name, (root / name).read_text(errors='replace')


def unallowed(rows):
    """Rows ALLOWED doesn't cover: all of a (file, api) pair's rows once it has more than its count."""
    counts = {}
    for path, _, api, _ in rows:
        counts[(path, api)] = counts.get((path, api), 0) + 1
    return [row for row in rows if counts[(row[0], row[2])] > ALLOWED.get((row[0], row[2]), (0, ''))[0]]


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    parser.add_argument('--list', action='store_true', help='print every row with its allowance')
    args = parser.parse_args(argv)
    rows = scan(tree_sources())
    if args.list:
        for path, line, api, problem in rows:
            reason = ALLOWED.get((path, api), (0, ''))[1]
            print(f'{path}:{line}: {api}: ' + (f'allowed: {reason}' if reason else problem))
        return 0
    bad = unallowed(rows)
    for path, line, api, problem in bad:
        print(f'{path}:{line}: {api}: {problem} (#3513)')
    if bad:
        print(f'{len(bad)} system callback(s) can run main-actor code off the main thread. Mark the closure '
              '`@Sendable` and hop with `Task {{ @MainActor in … }}`, or name the site in ALLOWED with why it is safe.')
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())
