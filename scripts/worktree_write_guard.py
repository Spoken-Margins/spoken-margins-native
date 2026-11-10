#!/usr/bin/env python3
"""Claude Code PreToolUse hook: a worktree session's shell commands write only inside its own worktree.

Installed as a copy in ~/.claude/hooks/ (scripts/install-lane-guard.py) and registered in the user-level
~/.claude/settings.json with --repo <main checkout>, so it only ever acts in this repository.

The desktop app already refuses the Write and Edit tools outside a session's worktree. It does not look at Bash. In
cluster run #3632 (2026-11-07) helpers wrote into other worktrees with heredocs, `sed -i` and short scripts, and no
guard saw it (#3665).

It blocks (exit 2, reason on stderr) a command run by a session in a linked worktree when the command writes into the
main checkout or another worktree of this repository: `>`/`>>`/`>|`, `tee`, `truncate`, `dd of=`, `cp`, `mv`,
`install`, `ln`, `rsync`, `sed -i`, `perl -i`, `rm`, `unlink` and `touch`, also inside `bash -c`. Allowed anywhere:
paths under ALLOWED_FOLDERS, and everything outside the repository (scratchpad, /tmp, memory). `rm`, `unlink`, `mv`
and `ln -n` act on a symlink itself, so a worktree may remove or re-link its own `.venv` link into the main checkout.
It follows `cd`, `pushd`, `popd` and subshells; once the folder can't be worked out, relative paths are let through.

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
EVERY_OPERAND_IS_TARGET = {'tee', 'truncate', 'rm', 'touch', 'unlink'}
ACTS_ON_THE_LINK = {'rm', 'unlink'}  # these change a symlink itself, never what it points to
# How a target is turned into the place that changes: THROUGH follows every link, LINK keeps a final symlink as the
# thing changed, and INTO follows a final symlink only when it points to a folder (`ln`/`mv` then write inside it).
THROUGH, LINK, INTO = 'through', 'link', 'into'
MESSAGE = ('Spoken Margins write guard: this session works in {own}, but this command writes to {path}, which is in '
           '{owner}. Write inside your own worktree, in artifacts/, or in your scratchpad. Do what this asks or stop '
           'and report it; do not hide the write from the guard (docs/workstreams/clusters.md).')


def without_comment(line: str, quote: str) -> tuple[str, str]:
    """(the line up to a `#` that starts a word outside quotes, the quote still open at its end).

    shlex's own comment handling also cuts at a `#` inside a word (`a#b`, `${#x}`), which would hide a write after it.
    """
    escaped = False
    for index, char in enumerate(line):
        if escaped:
            escaped = False
        elif quote:
            if char == quote:
                quote = ''
            elif char == '\\' and quote == '"':
                escaped = True
        elif char == '\\':
            escaped = True
        elif char in '\'"':
            quote = char
        elif char == '#' and (index == 0 or line[index - 1] in ' \t;&|()'):
            return line[:index], quote
    return line, quote


def without_heredocs_and_comments(command: str) -> str:
    """The command with here-document bodies and comments removed: both are text, not shell."""
    kept, closing, quote = [], [], ''
    for line in command.split('\n'):
        if closing:
            if line.strip() == closing[0]:
                closing.pop(0)
            continue
        line, quote = without_comment(line, quote)
        kept.append(line)
        closing = [match.group(2) for match in HEREDOC.finditer(line)]
    return '\n'.join(kept)


def simple_commands(command: str) -> list[list[str] | str]:
    """Split a shell command line into argv lists; redirect operators stay in as their own tokens.

    Each `(` and `)` comes back as its own item, so the caller can put the folder back when a subshell ends. The lexer
    glues neighbouring punctuation into one token (`);`, `))`), so those are taken apart here.
    """
    lexer = shlex.shlex(without_heredocs_and_comments(command).replace('\n', ' ; '), posix=True, punctuation_chars=True)
    lexer.whitespace_split = True
    lexer.commenters = ''
    result, current = [], []
    for token in lexer:
        pieces = re.findall(r'[()]|[^()]+', token) if re.fullmatch(r'[();<>|&]+', token) else [token]
        for piece in pieces:
            if piece in SEPARATORS:
                if current:
                    result.append(current)
                current = []
                if piece in ('(', ')'):
                    result.append(piece)
            else:
                current.append(piece)
    if current:
        result.append(current)
    return result


def strip_leaders(argv: list[str]) -> list[str]:
    while argv and (argv[0] in LEADERS or ASSIGNMENT.match(argv[0])):
        argv = argv[1:]
    return argv


def perl_switches(word: str) -> tuple[bool, bool, bool]:
    """(edits in place, carries the script, the next word is the script) for one perl switch bundle such as `-pie`.

    Perl reads a bundle letter by letter. After `i` the rest is the backup suffix; after `e` or `E` the rest, or the
    next word, is the script; after a switch that takes a value (`-M`, `-I`, `-0`...) the rest is that value. So
    `-Mstrict` or `-MList::Util` never edit in place, while `-pi` and `-pie` do.
    """
    for index, letter in enumerate(word[1:], start=1):
        if letter == 'i':
            return True, False, False
        if letter in 'eE':
            return False, True, index == len(word) - 1
        if letter in 'MmIxCdDFl0V':
            return False, False, False
    return False, False, False


def in_place_targets(name: str, words: list[str]) -> list[str]:
    """The files `sed -i` or `perl -i` edits, or nothing when the command does not edit in place."""
    in_place, has_script, operands, takes_value = False, False, [], False
    for word in words:
        if takes_value:
            takes_value = False
        elif word == '--':
            continue
        elif name == 'perl' and word.startswith('-') and not word.startswith('--') and len(word) > 1:
            edits, script, script_follows = perl_switches(word)
            in_place, has_script, takes_value = in_place or edits, has_script or script, script_follows
        elif word in ('-e', '-f') or re.fullmatch(r'-[nErsuz]*[ef]', word):
            has_script, takes_value = True, True
        elif word.startswith(('--expression=', '--file=')):
            has_script = True
        elif word == '--in-place' or word.startswith('--in-place=') or re.fullmatch(r'-[nErsuz]*i.*', word):
            in_place = True  # GNU reads everything after the i as the backup suffix, so `-ie` is suffix e
        elif not word.startswith('-') and word:  # BSD sed's `-i ''` leaves an empty word
            operands.append(word)
    if not in_place:
        return []
    return operands if has_script else operands[1:]


def write_targets(argv: list[str]) -> list[tuple[str, str]]:
    """(path, how to resolve it) for each path this simple command writes to, best effort.

    Nested `bash -c` scripts come back through `nested_script`.
    """
    found, words, skip = [], [], False
    for index, token in enumerate(argv):
        if skip:
            skip = False
        elif REDIRECT.fullmatch(token):
            skip = True
            if index + 1 < len(argv):
                found.append((argv[index + 1], THROUGH))
            if words and words[-1].isdigit() and index > 0 and argv[index - 1] == words[-1]:
                words.pop()  # the 2 of `2> file`
        else:
            words.append(token)
    words = strip_leaders(words)
    if not words:
        return found
    name, rest = os.path.basename(words[0]), words[1:]
    found.extend((word[3:], THROUGH) for word in rest if word.startswith('of='))
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
    flags = ''.join(word[1:] for word in rest if re.fullmatch(r'-[A-Za-z]+', word))
    no_dereference = ({'--no-dereference', '--no-target-directory'} & set(rest) or 'T' in flags
                      or (name == 'ln' and ('n' in flags or 'h' in flags)))
    if name in LAST_OPERAND_IS_TARGET:
        destination = LINK if name in ('ln', 'mv') and no_dereference else INTO if name in ('ln', 'mv') else THROUGH
        if target_dir:
            found.append((target_dir, THROUGH))
        elif len(operands) >= 2:
            found.append((operands[-1], destination))
        if name == 'mv':
            found.extend((source, LINK) for source in operands[:-1])  # moving away changes the place it came from
    elif name in EVERY_OPERAND_IS_TARGET:
        found.extend((operand, LINK if name in ACTS_ON_THE_LINK else THROUGH) for operand in operands)
    elif name in ('sed', 'gsed', 'perl'):
        found.extend((target, THROUGH) for target in in_place_targets(name, rest))
    # `rm -r link/` goes through the link to the folder it names, so a trailing slash always follows
    return [(path, THROUGH if path.endswith('/') else how) for path, how in found]


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


def changed_folder(argv: list[str], cwd: str | None, oldpwd: str | None, stack: list[str | None],
                   known: dict[str, str]) -> tuple[str | None, str | None]:
    """(folder, previous folder) after a `cd`, `pushd` or `popd`. None is a folder the guard cannot work out."""
    name, operands = argv[0], [word for word in argv[1:] if not re.fullmatch(r'-[LPe@]+', word)]
    if name == 'popd':
        return (stack.pop() if stack else None), cwd
    if not operands:
        if name == 'pushd':  # swaps the top two folders
            if not stack:
                return None, cwd
            top = stack.pop()
            stack.append(cwd)
            return top, cwd
        return known.get('HOME'), cwd
    if name == 'pushd':
        stack.append(cwd)
    if operands[0] == '-':
        return oldpwd, cwd
    filled = expand(operands[0], known)
    if filled is None or (cwd is None and not os.path.isabs(filled)):
        return None, cwd
    return os.path.normpath(os.path.join(cwd or '/', filled)), cwd


def targets_in(command: str, cwd: str | None, known: dict[str, str]) -> list[tuple[str, str]]:
    """(absolute path, how to resolve it) for each write, following `cd`, `pushd`, `popd`, subshells and plain
    NAME=value lines through the command. Once the folder can't be worked out, relative paths are let through."""
    found, oldpwd, stack, saved = [], None, [], []
    for argv in simple_commands(command):
        if argv == '(':
            saved.append((cwd, oldpwd, list(stack), dict(known)))
            continue
        if argv == ')':
            if saved:
                cwd, oldpwd, stack, known = saved.pop()
            continue
        if len(argv) == 1 and ASSIGNMENT.match(argv[0]):
            name, value = ASSIGNMENT.match(argv[0]).groups()
            filled = expand(value, known)
            if filled is None:
                known.pop(name, None)
            else:
                known[name] = filled
            continue
        if argv[0] in ('cd', 'pushd', 'popd'):
            cwd, oldpwd = changed_folder(argv, cwd, oldpwd, stack, known)
            if cwd is None:
                known.pop('PWD', None)
            else:
                known['PWD'] = cwd
            continue
        script = nested_script(argv)
        if script is not None:
            found.extend(targets_in(script, cwd, dict(known)))
        for target, how in write_targets(argv):
            filled = expand(target, known)
            if filled is not None and (cwd is not None or os.path.isabs(filled)):
                found.append((os.path.normpath(os.path.join(cwd or '/', filled)), how))
    return found


def resolved(path: str, how: str) -> str:
    """The real place a write to `path` changes. See THROUGH, LINK and INTO."""
    if how == LINK or (how == INTO and not os.path.isdir(path)):
        return os.path.join(os.path.realpath(os.path.dirname(path)), os.path.basename(path))
    return os.path.realpath(path)


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
    for target, how in targets:
        real = resolved(target, how)
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
