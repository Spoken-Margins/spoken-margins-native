#!/usr/bin/env python3
"""Claude Code PreToolUse hook: agents never write into the Mac's toolchain.

Installed as a copy in ~/.claude/hooks/ (scripts/install-lane-guard.py installs it next to the lane
guard) and registered in the user-level ~/.claude/settings.json.

On 2026-10-22 an agent ran `cp /bin/sleep .venv/bin/python3.14`. That path is a symlink into
Homebrew's Cellar, so the copy overwrote Homebrew's Python and broke every .venv on the Mac.

It blocks (exit 2, reason on stderr) a shell command that writes to a path that is, or resolves
into, a toolchain directory or a .venv/bin or .venv/lib: `cp`, `mv`, `install`, `ln`, `rsync`, `tee`,
`truncate`, `dd of=` and `>`/`>>` redirects. Reading, executing, `pip install` into .venv and
`brew` commands are fine: Homebrew changes itself through brew.

Stdlib only and Python 3.9-compatible: it runs under /usr/bin/python3, outside any checkout.
Anything unexpected fails open, because a crashing hook must not block every project's shell.
"""
from __future__ import annotations

import json
import os
import re
import shlex
import sys

# The last root is a prefix, so it also covers Xcode-beta.app.
PROTECTED_ROOTS = ('/opt/homebrew', '/usr/local/Cellar', '/usr/bin', '/bin', '/usr/sbin',
                   '/Library/Developer', '/Applications/Xcode')
VENV = re.compile(r'(^|/)\.venv/(bin|lib)(/|$)')
REDIRECT = re.compile(r'\d*>>?\|?|&>>?')
SEPARATORS = {';', '&&', '||', '|', '&', '(', ')', '|&', ';;'}
SHELLS = {'bash', 'sh', 'zsh', 'dash'}
WRAPPERS = {'sudo', 'env', 'command', 'exec', 'time', 'nohup', 'nice', 'caffeinate', 'timeout', 'xargs'}
MESSAGE = ('Spoken Margins toolchain guard: blocked a write to {path}. Toolchain paths are read-only for agents. '
           'For a stand-in binary, create a new file in a temp dir you made, or use `exec -a`. '
           'Ask the owner if Homebrew itself needs a change.')


def simple_commands(command: str) -> list[list[str]]:
    """Split a shell command line into argv lists; redirect operators stay in as their own tokens."""
    lexer = shlex.shlex(command.replace('\n', ' ; '), posix=True, punctuation_chars=True)
    lexer.whitespace_split = True
    lexer.commenters = ''
    result, current = [], []
    for token in lexer:
        if token in SEPARATORS:
            if current:
                result.append(current)
            current = []
        else:
            current.append(token)
    if current:
        result.append(current)
    return result


def protected(path: str, cwd: str, roots=PROTECTED_ROOTS) -> str | None:
    """The offending absolute path when writing to `path` would touch the toolchain, else None.

    Checks the path as written and where it lands once symlinks are followed.
    """
    absolute = os.path.normpath(os.path.join(cwd, os.path.expanduser(path)))
    real = os.path.realpath(absolute)
    for candidate in (absolute, real):
        if VENV.search(candidate) or any(candidate.startswith(root) and
                                         (root.endswith('Xcode') or candidate[len(root):len(root) + 1] in ('', '/'))
                                         for root in roots):
            return absolute if real == absolute else f'{absolute} (a symlink into {real})'
    return None


def destinations(argv: list[str]) -> list[tuple[str, list[str]]]:
    """(destination, names of what is copied there) for each write in this simple command, best effort."""
    found = []
    for index, token in enumerate(argv):
        if REDIRECT.fullmatch(token) and index + 1 < len(argv):
            found.append((argv[index + 1], []))
        elif token.startswith('of='):
            found.append((token[3:], []))
    while argv and (argv[0] in WRAPPERS or re.match(r'^[A-Za-z_]\w*=', argv[0])):
        argv = argv[1:]
    if not argv:
        return found
    name, operands, target_dir, skip = os.path.basename(argv[0]), [], None, False
    for index, token in enumerate(argv[1:], 1):
        if skip:
            skip = False
        elif REDIRECT.fullmatch(token):
            skip = True
        elif token in ('-t', '--target-directory') and index + 1 < len(argv):
            target_dir, skip = argv[index + 1], True
        elif token.startswith('--target-directory='):
            target_dir = token.split('=', 1)[1]
        elif not token.startswith('-') and not token.startswith('of='):
            operands.append(token)
    if name in SHELLS:
        for flag, script in zip(argv[1:], argv[2:]):
            if re.fullmatch(r'-[A-Za-z]*c[A-Za-z]*', flag):
                found.extend(item for sub in simple_commands(script) for item in destinations(sub))
    elif name in ('cp', 'install', 'ln', 'rsync', 'mv'):
        if target_dir:
            found.append((target_dir, operands))
        elif len(operands) >= 2:
            found.append((operands[-1], operands[:-1]))
        if name == 'mv':
            found.extend((source, []) for source in operands)  # moving a toolchain file away changes it too
    elif name in ('tee', 'truncate'):
        found.extend((operand, []) for operand in operands)
    return found


def decide(command: str, cwd: str, roots=PROTECTED_ROOTS) -> str | None:
    """Return the reason to block this shell command, or None to let it through."""
    for argv in simple_commands(command):
        for destination, sources in destinations(argv):
            hit = protected(destination, cwd, roots)
            if hit is None and os.path.isdir(os.path.join(cwd, os.path.expanduser(destination))):
                # `cp a dir` writes dir/a: check where the copy would land
                for source in sources:
                    hit = hit or protected(os.path.join(destination, os.path.basename(source)), cwd, roots)
            if hit:
                return MESSAGE.format(path=hit)
    return None


def main() -> int:
    try:
        event = json.load(sys.stdin)
        command = (event.get('tool_input') or {}).get('command') or ''
        reason = decide(command, event.get('cwd') or os.getcwd()) if command else None
    except Exception as error:  # noqa: BLE001 - fail open, but say so
        print(f'toolchain guard error (allowed the call): {error!r}', file=sys.stderr)
        return 0
    if reason:
        print(reason, file=sys.stderr)
        return 2
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
