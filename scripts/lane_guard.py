#!/usr/bin/env python3
"""Claude Code PreToolUse hook: only the Test Desk touches simulators in Spoken Margins sessions.

Installed as a copy in ~/.claude/hooks/ (scripts/install-lane-guard.py) and registered in the
user-level ~/.claude/settings.json, so it covers every session on every branch. It acts only on
sessions working in the guarded repository or one of its worktrees; other projects pass through.

In a guarded session it blocks (exit 2, reason on stderr):
- simulator state changes: `simctl boot|install|launch|shutdown|erase|...`, opening Simulator.app,
  killing CoreSimulator, simulator MCP tools, installs and launches on a physical device;
- simulator test runs: `xcodebuild test|test-without-building`, `verify-tests.py --plan` other
  than fast, and the repo scripts that boot simulators;
unless the session is the Test Desk: opened on the <repo>-test-desk worktree next to the
repository, or started with SM_LANE_ROLE=test-desk. In every guarded session, including the Test Desk, it also sends raw
`xcodebuild` builds to scripts/xcodebuild-lane, the Mac-wide build semaphore. Guarded calls are
logged to ~/Library/Caches/SpokenMarginsLane/guard.log.

Stdlib only and Python 3.9-compatible: it runs under /usr/bin/python3, outside any checkout.
Anything unexpected fails open, because a crashing hook must not block every project's shell.
"""
from __future__ import annotations

import json
import os
import re
import shlex
import subprocess
import sys
import time

TEST_DESK_ENV = 'SM_LANE_ROLE'
TEST_DESK_VALUE = 'test-desk'
TEST_DESK_SUFFIX = '-test-desk'  # the Test Desk's worktree sits next to the checkout: <repo>-test-desk

KEYWORDS = ('simctl', 'xcodebuild', 'devicectl', 'verify-tests', 'Simulator', 'smoke-simulator',
            'verify-gate', 'posterboard')
SEPARATORS = {';', '&&', '||', '|', '&', '(', ')', '|&', ';;'}
PREFIX_COMMANDS = {'env', 'command', 'exec', 'time', 'nice', 'nohup', 'caffeinate', 'sudo',
                   'timeout', 'gtimeout', 'stdbuf', 'arch', 'xargs'}
# Options of those wrappers that take a separate value, e.g. `env -u NAME` or `timeout -s KILL`.
PREFIX_VALUE_OPTIONS = {'-u', '-n', '-s', '-k', '-S', '-C', '-P', '-t', '-w', '-g', '-I', '-L', '-a'}
SHELLS = {'bash', 'sh', 'zsh', 'dash'}
PYTHON = re.compile(r'python(\d+(\.\d+)*)?$')

SIMCTL_READ_ONLY = {'list', 'help', 'get_app_container', 'appinfo', 'listapps', 'getenv'}
XCRUN_VALUE_OPTIONS = {'--sdk', '-sdk', '--toolchain', '-toolchain'}
HEREDOC = re.compile(r"(?<!<)<<(?!<)-?\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\1")
SIM_TEST_ACTIONS = {'test', 'test-without-building'}
XCODEBUILD_NO_BUILD = {'-version', '-list', '-showsdks', '-showBuildSettings', '-showdestinations',
                       '-showTestPlans', '-help', '-usage', '-license', '-checkFirstLaunchStatus',
                       '-exportArchive', '-exportLocalizations', '-importLocalizations',
                       '-exportNotarizedApp', '-create-xcframework'}
HOST_PLANS = {'fast'}
SIMULATOR_SCRIPTS = {'smoke-simulator.sh', 'check_posterboard_repair.py', 'verify-gate1.sh',
                     'verify-gate1-routine.sh', 'verify-gate1-closeout.sh', 'verify-gate2.sh'}

SIM = 'simulator'
BUILD = 'build'


def strip_heredocs(command: str) -> str:
    """Drop heredoc bodies (commit messages, file contents), which are text rather than commands."""
    kept, pending = [], []
    for line in command.split('\n'):
        if pending:
            if line.strip() == pending[0]:
                pending.pop(0)
            continue
        kept.append(line)
        pending.extend(match.group(2) for match in HEREDOC.finditer(line))
    return '\n'.join(kept)


def words(command: str) -> list[str]:
    lexer = shlex.shlex(command.replace('\n', ' ; ').replace('`', ' ; '), posix=True, punctuation_chars=True)
    lexer.whitespace_split = True
    lexer.commenters = ''
    return list(lexer)


def simple_commands(command: str) -> list[list[str]]:
    """Split a shell command line into simple commands (argv lists), best effort."""
    command = strip_heredocs(command)
    try:
        tokens = words(command)
    except ValueError:
        # Unbalanced quotes (often a heredoc body): fall back to plain whitespace splitting per line.
        return [line.split() for line in command.splitlines()]
    result, current = [], []
    for token in tokens:
        if token in SEPARATORS or set(token) <= set('();<>|&'):
            if current:
                result.append(current)
            current = []
        else:
            current.append(token)
    if current:
        result.append(current)
    return result


def strip_prefixes(argv: list[str]) -> list[str]:
    """Drop VAR=value assignments and wrappers like `env`, `timeout 600` or `caffeinate -i`."""
    argv = list(argv)
    while argv:
        head = argv[0]
        if re.match(r'^[A-Za-z_][A-Za-z0-9_]*=', head):
            argv.pop(0)
        elif os.path.basename(head) in PREFIX_COMMANDS:
            argv.pop(0)
            while argv and (argv[0].startswith('-') or re.match(r'^[A-Za-z_][A-Za-z0-9_]*=', argv[0])
                            or re.match(r'^\d+(\.\d+)?[smhd]?$', argv[0])):
                option = argv.pop(0)
                if option in PREFIX_VALUE_OPTIONS and argv:
                    argv.pop(0)
        else:
            break
    return argv


def classify_argv(argv: list[str], depth: int = 0) -> list[tuple[str, str]]:
    """Return (kind, description) for each guarded operation in one simple command."""
    argv = strip_prefixes(argv)
    if not argv:
        return []
    program = os.path.basename(argv[0])
    rest = argv[1:]
    if program in SHELLS:
        if '-c' in rest:
            index = rest.index('-c')
            return classify_command(rest[index + 1], depth + 1) if index + 1 < len(rest) and depth < 3 else []
        rest = [arg for arg in rest if not arg.startswith('-')]
        if not rest:
            return []
        program, rest = os.path.basename(rest[0]), rest[1:]
    if program == 'xcrun':
        while rest and rest[0].startswith('-'):
            if rest[0] in ('-f', '--find', '--show-sdk-path', '--show-sdk-version', '--show-sdk-platform-path'):
                return []
            rest = rest[2:] if rest[0] in XCRUN_VALUE_OPTIONS else rest[1:]
        if not rest:
            return []
        program, rest = os.path.basename(rest[0]), rest[1:]
    if program == 'simctl':
        while rest and rest[0].startswith('-'):
            rest = rest[2:] if rest[0] == '--set' else rest[1:]
        sub = rest[0] if rest else ''
        if not sub or sub in SIMCTL_READ_ONLY:
            return []
        if sub == 'runtime' and rest[1:2] in (['list'], ['match']):
            return []
        return [(SIM, f'simctl {sub}')]
    if program == 'devicectl':
        if rest[:1] == ['list'] or rest[:2] == ['device', 'info'] or not rest or rest[0] in ('help', '--help'):
            return []
        return [(SIM, 'devicectl ' + ' '.join(rest[:3]))]
    if program in ('xcodebuild', 'xcodebuild-lane'):
        if any(arg in XCODEBUILD_NO_BUILD for arg in rest):
            return []
        found = []
        if any(arg in SIM_TEST_ACTIONS for arg in rest):
            found.append((SIM, f'{program} ' + next(a for a in rest if a in SIM_TEST_ACTIONS)))
        if program == 'xcodebuild':
            found.append((BUILD, 'raw xcodebuild build'))
        return found
    if program == 'open':
        if any(arg == 'Simulator' or arg.rstrip('/').endswith('Simulator.app') or arg == 'com.apple.iphonesimulator'
               for arg in rest):
            return [(SIM, 'open Simulator')]
        return []
    if program in ('killall', 'pkill'):
        if any('Simulator' in arg for arg in rest):
            return [(SIM, f'{program} simulator processes')]
        return []
    if PYTHON.match(program):
        rest = [arg for arg in rest if arg not in ('-u', '-B', '-E', '-I')]
        if not rest:
            return []
        program, rest = os.path.basename(rest[0]), rest[1:]
    if program == 'verify-tests.py':
        if '--list' in rest:
            return []
        plan = 'fast'
        for index, arg in enumerate(rest):
            if arg == '--plan' and index + 1 < len(rest):
                plan = rest[index + 1]
            elif arg.startswith('--plan='):
                plan = arg.split('=', 1)[1]
        return [] if plan in HOST_PLANS else [(SIM, f'verify-tests.py --plan {plan}')]
    if program in SIMULATOR_SCRIPTS:
        return [(SIM, program)]
    return []


def classify_command(command: str, depth: int = 0) -> list[tuple[str, str]]:
    found = []
    for argv in simple_commands(command):
        found.extend(classify_argv(argv, depth))
    return found


def classify_tool(tool_name: str, tool_input: dict) -> list[tuple[str, str]]:
    if tool_name == 'Bash':
        command = tool_input.get('command') or ''
        if not any(keyword in command for keyword in KEYWORDS):
            return []
        return classify_command(command)
    if re.search('simulator', tool_name, re.I):
        return [(SIM, f'{tool_name} {tool_input.get("action", "")}'.strip())]
    return []


def same_repository(path: str, repos: list[str]) -> bool:
    """True when path is inside a guarded repository or any of its worktrees."""
    real = os.path.realpath(path)
    for repo in repos:
        root = os.path.realpath(repo)
        if real == root or real.startswith(root + os.sep):
            return True
    try:
        common = subprocess.run(['git', '-C', real, 'rev-parse', '--path-format=absolute', '--git-common-dir'],
                                capture_output=True, text=True, timeout=5).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return False
    return bool(common) and any(os.path.realpath(common) == os.path.realpath(os.path.join(repo, '.git'))
                                for repo in repos)


def in_scope(event: dict, repos: list[str], environ) -> bool:
    command = (event.get('tool_input') or {}).get('command') or ''
    if any(os.path.realpath(repo) in command or repo in command for repo in repos):
        return True
    places = [event.get('cwd'), environ.get('CLAUDE_PROJECT_DIR')]
    return any(place and same_repository(place, repos) for place in places)


def project_key(path: str) -> str:
    """Claude Code's folder name for a project under ~/.claude/projects."""
    return re.sub(r'[^A-Za-z0-9]', '-', path)


def test_desk(event: dict, repos: list[str], environ) -> str | None:
    """How this session is the Test Desk, or None.

    Either it was started with SM_LANE_ROLE=test-desk (a terminal session), or its project folder,
    which `cd` can't change, is the <repo>-test-desk worktree (a desktop app or terminal
    session opened on that folder).
    """
    if environ.get(TEST_DESK_ENV) == TEST_DESK_VALUE:
        return TEST_DESK_ENV
    desks = [os.path.realpath(repo) + TEST_DESK_SUFFIX for repo in repos]
    project = environ.get('CLAUDE_PROJECT_DIR')
    if project:
        return 'project folder' if os.path.realpath(project) in desks else None
    transcript = event.get('transcript_path') or ''
    if transcript and os.path.basename(os.path.dirname(transcript)) in {project_key(d) for d in desks}:
        return 'project folder'
    return None


def log_decision(event: dict, found, decision: str, desk: str | None, environ) -> None:
    """Append guarded calls to a local log, so blocks and Test Desk runs can be audited later."""
    try:
        directory = environ.get('SM_LANE_STATE_DIR') or os.path.expanduser('~/Library/Caches/SpokenMarginsLane')
        os.makedirs(directory, exist_ok=True)
        with open(os.path.join(directory, 'guard.log'), 'a') as log:
            log.write(json.dumps({'time': time.strftime('%Y-%m-%dT%H:%M:%S'), 'decision': decision,
                                  'what': sorted({what for _, what in found}), 'test_desk': desk,
                                  'session': event.get('session_id'), 'cwd': event.get('cwd'),
                                  'project_dir': environ.get('CLAUDE_PROJECT_DIR'),
                                  'transcript_path': event.get('transcript_path')}) + '\n')
    except (OSError, TypeError, ValueError):
        pass


def decide(event: dict, repos: list[str], environ=None) -> str | None:
    """Return the reason to block this tool call, or None to let it through."""
    environ = os.environ if environ is None else environ
    found = classify_tool(event.get('tool_name') or '', event.get('tool_input') or {})
    if not found or not in_scope(event, repos, environ):
        return None
    desk = test_desk(event, repos, environ)
    sim = sorted({what for kind, what in found if kind == SIM})
    reason = None
    if sim and not desk:
        reason = (f'Spoken Margins lane guard: blocked {", ".join(sim)}. Only the Test Desk session boots, '
                  'installs on or drives simulators, and runs simulator test plans, so parallel sessions '
                  'cannot start a simulator crash flood. Ask the lane for a T3/T4 run instead: see '
                  '.claude/skills/lane-request/SKILL.md and docs/workstreams/test-lane.md. Host checks '
                  '(verify-tests.py --plan fast, swift test) and builds through scripts/xcodebuild-lane '
                  'are allowed.')
    elif any(kind == BUILD for kind, _ in found):
        reason = ('Spoken Margins lane guard: run xcodebuild through scripts/xcodebuild-lane with the same '
                  'arguments. It queues for one of the two Mac-wide build slots and uses this worktree\'s '
                  'own DerivedData (.build/dd) unless you pass -derivedDataPath. Information-only calls '
                  '(-version, -list, -showBuildSettings, -exportArchive) may use xcodebuild directly.')
    log_decision(event, found, 'blocked' if reason else 'allowed', desk, environ)
    return reason


def main(argv: list[str]) -> int:
    repos = [argv[i + 1] for i, arg in enumerate(argv) if arg == '--repo' and i + 1 < len(argv)]
    try:
        event = json.load(sys.stdin)
        reason = decide(event, repos)
    except Exception as error:  # noqa: BLE001 - fail open, but say so
        print(f'lane guard error (allowed the call): {error!r}', file=sys.stderr)
        return 0
    if reason:
        print(reason, file=sys.stderr)
        return 2
    return 0


if __name__ == '__main__':
    raise SystemExit(main(sys.argv[1:]))
