#!/usr/bin/env python3
"""Claude Code PreToolUse hook: a worktree session's shell commands write only inside its own worktree.

Installed as a copy in ~/.claude/hooks/ (scripts/install-lane-guard.py) and registered in the user-level
~/.claude/settings.json with --repo <main checkout>, so it only ever acts in this repository.

The desktop app already refuses the Write and Edit tools outside a session's worktree. It does not look at Bash. In
cluster run #3632 (2026-11-07) helpers wrote into other worktrees with heredocs, `sed -i` and short scripts, and no
guard saw it (#3665).

It blocks (exit 2, reason on stderr) a command run by a session in a linked worktree when the command writes into the
main checkout or another worktree of this repository: `>`/`>>`/`>|`, `tee`, `truncate`, `dd of=`, `cp`, `mv`,
`install`, `ln`, `rsync`, `sed -i`, `perl -i`, `rm` and `touch`, also inside `bash -c`. Allowed anywhere: paths under
ALLOWED_FOLDERS, and everything outside the repository (scratchpad, /tmp, memory).

It cannot see what a program does once it runs: a Python script that writes files stays a written rule
(docs/workstreams/clusters.md). A path it cannot work out, such as `$(...)`, is let through.

Each refusal, and each command it could not read, is one line in REFUSAL_LOG. That file is the waste signal: no
refusals over 30 days of cluster runs means this hook comes out.

Stdlib only and Python 3.9-compatible: it runs under /usr/bin/python3, outside any checkout. Anything unexpected
fails open, because a crashing hook must not block every shell.
"""
from __future__ import annotations

import argparse
import datetime
import glob
import json
import os
from pathlib import Path
import re
import shlex
import sys

ALLOWED_FOLDERS = ('artifacts', '.build', 'build', 'DerivedData', 'node_modules')
REFUSAL_LOG = Path.home() / '.claude/hooks/state/worktree-write-guard.jsonl'
REDIRECT = re.compile(r'\d*>>?\|?|&>>?')
HEREDOC = re.compile(r"(?<!<)<<(?!<)-?\s*(['\"\\]?)([\w.-]+)\1")
VARIABLE = re.compile(r'\$(?:\{(\w+)\}|(\w+))')
ASSIGNMENT = re.compile(r'^([A-Za-z_]\w*)=(.*)$', re.DOTALL)
SEPARATORS = {';', '&&', '||', '|', '&', '(', ')', '|&', ';;'}
SHELLS = {'bash', 'sh', 'zsh', 'dash'}
LEADERS = {'sudo', 'env', 'command', 'exec', 'time', 'nohup', 'nice', 'caffeinate', 'timeout', 'xargs',
           'then', 'do', 'else', 'elif', 'if', 'while', 'until', '!', '{'}
LAST_OPERAND_IS_TARGET = {'cp', 'install', 'ln', 'rsync', 'mv'}
EVERY_OPERAND_IS_TARGET = {'tee', 'truncate', 'rm', 'touch'}
MESSAGE = ('Spoken Margins write guard: this session works in {own}, but this command writes to {path}, which is in '
           '{owner}. Write inside your own worktree, in artifacts/, or in your scratchpad. Do what this asks or stop '
           'and report it; do not hide the write from the guard (docs/workstreams/clusters.md).')


def without_heredocs_and_comments(command: str) -> str:
    """The command with here-document bodies and comment lines removed: both are text, not shell."""
    kept, closing = [], []
    for line in command.split('\n'):
        if closing:
            if line.strip() == closing[0]:
                closing.pop(0)
            continue
        if line.lstrip().startswith('#'):
            continue
        kept.append(line)
        closing = [match.group(2) for match in HEREDOC.finditer(line)]
    return '\n'.join(kept)


def simple_commands(command: str) -> list[list[str]]:
    """Split a shell command line into argv lists; redirect operators stay in as their own tokens."""
    lexer = shlex.shlex(without_heredocs_and_comments(command).replace('\n', ' ; '), posix=True, punctuation_chars=True)
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


def strip_leaders(argv: list[str]) -> list[str]:
    while argv and (argv[0] in LEADERS or ASSIGNMENT.match(argv[0])):
        argv = argv[1:]
    return argv


def in_place_targets(name: str, words: list[str]) -> list[str]:
    """The files `sed -i` or `perl -i` edits, or nothing when the command does not edit in place."""
    in_place, has_script, operands, takes_value = False, False, [], False
    for word in words:
        if takes_value:
            takes_value = False
        elif word in ('-e', '-f'):
            has_script, takes_value = True, True
        elif word == '--in-place' or word.startswith('--in-place=') or re.fullmatch(r'-[A-Za-z]*i.*', word):
            in_place = True
            if re.fullmatch(r'-[A-Za-z]*i.*e', word):  # perl -pie and friends: the script follows
                has_script, takes_value = True, True
        elif not word.startswith('-') and word:  # BSD sed's `-i ''` leaves an empty word
            operands.append(word)
    if not in_place:
        return []
    return operands if has_script else operands[1:]


def write_targets(argv: list[str]) -> list[str]:
    """Each path this simple command writes to, best effort. Nested `bash -c` scripts come back through `nested`."""
    found, words, skip = [], [], False
    for index, token in enumerate(argv):
        if skip:
            skip = False
        elif REDIRECT.fullmatch(token):
            skip = True
            if index + 1 < len(argv):
                found.append(argv[index + 1])
            if words and words[-1].isdigit() and index > 0 and argv[index - 1] == words[-1]:
                words.pop()  # the 2 of `2> file`
        else:
            words.append(token)
    words = strip_leaders(words)
    if not words:
        return found
    name, rest = os.path.basename(words[0]), words[1:]
    found.extend(word[3:] for word in rest if word.startswith('of='))
    operands, target_dir, skip = [], None, False
    for index, word in enumerate(rest):
        if skip:
            skip = False
        elif word in ('-t', '--target-directory') and index + 1 < len(rest):
            target_dir, skip = rest[index + 1], True
        elif word.startswith('--target-directory='):
            target_dir = word.split('=', 1)[1]
        elif not word.startswith('-') and not word.startswith('of='):
            operands.append(word)
    if name in LAST_OPERAND_IS_TARGET:
        if target_dir:
            found.append(target_dir)
        elif len(operands) >= 2:
            found.append(operands[-1])
        if name == 'mv':
            found.extend(operands[:-1])  # moving a file away changes the place it came from
    elif name in EVERY_OPERAND_IS_TARGET:
        found.extend(operands)
    elif name in ('sed', 'gsed', 'perl'):
        found.extend(in_place_targets(name, rest))
    return found


def nested_script(argv: list[str]) -> str | None:
    words = strip_leaders([token for token in argv if not REDIRECT.fullmatch(token)])
    if words and os.path.basename(words[0]) in SHELLS:
        for flag, script in zip(words[1:], words[2:]):
            if re.fullmatch(r'-[A-Za-z]*c[A-Za-z]*', flag):
                return script
    return None


def expand(path: str, known: dict[str, str]) -> str | None:
    """`path` with ~ and known variables filled in, or None when part of it can only be known at run time."""
    if '$(' in path or '`' in path:
        return None
    unknown = False

    def fill(match):
        nonlocal unknown
        name = match.group(1) or match.group(2)
        if name not in known:
            unknown = True
            return ''
        return known[name]
    filled = VARIABLE.sub(fill, path)
    return None if unknown or '$' in filled else os.path.expanduser(filled)


def targets_in(command: str, cwd: str, known: dict[str, str]) -> list[str]:
    """Absolute paths the command writes to, following `cd` and plain NAME=value lines through the command."""
    found = []
    for argv in simple_commands(command):
        if len(argv) == 1 and ASSIGNMENT.match(argv[0]):
            name, value = ASSIGNMENT.match(argv[0]).groups()
            filled = expand(value, known)
            if filled is None:
                known.pop(name, None)
            else:
                known[name] = filled
            continue
        if argv[0] in ('cd', 'pushd') and len(argv) >= 2 and argv[1] != '-':
            filled = expand(argv[1], known)
            if filled is not None:
                cwd = os.path.normpath(os.path.join(cwd, filled))
            continue
        script = nested_script(argv)
        if script is not None:
            found.extend(targets_in(script, cwd, dict(known)))
        for target in write_targets(argv):
            filled = expand(target, known)
            if filled is not None:
                found.append(os.path.normpath(os.path.join(cwd, filled)))
    return found


def checkouts(repo: str) -> list[str]:
    """The main checkout and every linked worktree git knows about, as real paths."""
    roots = [os.path.realpath(repo)]
    for record in glob.glob(os.path.join(repo, '.git', 'worktrees', '*', 'gitdir')):
        try:
            roots.append(os.path.realpath(os.path.dirname(Path(record).read_text().strip())))
        except OSError:
            continue
    return roots


def inside(path: str, root: str) -> bool:
    return path == root or path.startswith(root + os.sep)


def checkout_holding(path: str, roots: list[str]) -> str | None:
    """The deepest checkout that holds `path`: worktrees live inside the main checkout's .claude/worktrees."""
    holding = [root for root in roots if inside(path, root)]
    return max(holding, key=len) if holding else None


def project_folder_name(path: str) -> str:
    """How Claude Code names a project folder under ~/.claude/projects."""
    return re.sub(r'[^A-Za-z0-9]', '-', path)


def own_checkout(cwd: str, transcript: str, roots: list[str]) -> str | None:
    """The checkout this session works in.

    A shell inside a linked worktree is that worktree's: a helper with its own worktree keeps its transcript under
    its parent's project folder, so the transcript cannot outrank the shell. From the main checkout or outside the
    repository the shell may have wandered off, and the transcript's folder says where the session started.
    """
    holding = checkout_holding(os.path.realpath(cwd), roots)
    if holding is not None and holding != roots[0]:
        return holding
    parts = Path(transcript).parts if transcript else ()
    if 'projects' in parts and parts.index('projects') + 1 < len(parts):
        folder = parts[parts.index('projects') + 1]
        for root in roots:
            if project_folder_name(root) == folder:
                return root
    return holding


def decide(command: str, cwd: str, repo: str, transcript: str = '') -> tuple[str, str] | None:
    """(reason, offending path) when this command must be refused, else None."""
    if not command:
        return None
    targets = targets_in(command, cwd, {'HOME': str(Path.home()), 'PWD': cwd})
    if not targets:
        return None
    roots = checkouts(repo)
    own = own_checkout(cwd, transcript, roots)
    if own is None or own == roots[0]:  # the main checkout's own sessions are outside this rule, as with the app's
        return None
    for target in targets:
        real = os.path.realpath(target)
        owner = checkout_holding(real, roots)
        if owner is None or owner == own:
            continue
        relative = os.path.relpath(real, owner).split(os.sep)
        if relative[0] in ALLOWED_FOLDERS:
            continue
        return MESSAGE.format(own=own, path=real, owner=owner), real
    return None


def log(entry: dict) -> None:
    try:
        REFUSAL_LOG.parent.mkdir(parents=True, exist_ok=True)
        stamped = {'at': datetime.datetime.now(datetime.timezone.utc).isoformat(timespec='seconds'), **entry}
        with REFUSAL_LOG.open('a') as handle:
            handle.write(json.dumps(stamped) + '\n')
    except OSError:
        pass  # a full disk must not turn a refusal into a crash


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument('--repo', required=True)
    command, cwd = '', ''
    try:
        args = parser.parse_args()
        event = json.load(sys.stdin)
        command = (event.get('tool_input') or {}).get('command') or ''
        cwd = event.get('cwd') or os.getcwd()
        verdict = decide(command, cwd, args.repo, event.get('transcript_path') or '')
    except Exception as error:  # noqa: BLE001 - fail open, but leave a mark
        log({'event': 'unreadable', 'cwd': cwd, 'error': repr(error)[:200], 'command': command[:200]})
        return 0
    if verdict:
        reason, path = verdict
        log({'event': 'refused', 'cwd': cwd, 'path': path, 'command': command[:200]})
        print(reason, file=sys.stderr)
        return 2
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
