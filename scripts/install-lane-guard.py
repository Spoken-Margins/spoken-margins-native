#!/usr/bin/env python3
"""Install the lane guard hook for every Claude Code session on this Mac.

Copies scripts/lane_guard.py to ~/.claude/hooks/ (a stable path, so switching branches in a
checkout can't remove the hook) and prints the entry for ~/.claude/settings.json. It never edits
settings.json itself: that file is the owner's, and changing it is an owner-approved step.

  scripts/install-lane-guard.py          copy the guards and print the settings entries
  scripts/install-lane-guard.py --check  exit 1 if an installed copy is missing or differs
  scripts/install-lane-guard.py --context-handoff
                                         also copy the context hand-off hook (scripts/context_handoff_hook.py)

The context hand-off hook (the 250k/300k token line, #2750) is checked for drift every time but installed only
with --context-handoff: changing the live copy is an owner-approved step, so a plain run for a lane-guard change
never swaps it.
"""
import argparse
import filecmp
import json
from pathlib import Path
import shutil
import subprocess
import sys

SOURCE = Path(__file__).resolve().parent / 'lane_guard.py'
TARGET = Path.home() / '.claude/hooks/spoken-margins-lane-guard.py'
TOOLCHAIN_SOURCE = SOURCE.parent / 'toolchain_guard.py'
TOOLCHAIN_TARGET = Path.home() / '.claude/hooks/spoken-margins-toolchain-guard.py'
HANDOFF_SOURCE = SOURCE.parent / 'context_handoff_hook.py'
HANDOFF_TARGET = Path.home() / '.claude/hooks/spoken-margins-context-handoff.py'
PYTHON = '/usr/bin/python3'


def main_checkout():
    common = subprocess.check_output(['git', '-C', str(SOURCE.parent), 'rev-parse', '--path-format=absolute',
                                      '--git-common-dir'], text=True).strip()
    return Path(common).parent


def settings_entry():
    return {'matcher': 'Bash|Monitor|mcp__terminal__.*|mcp__.*[Ss]imulator.*',
            'hooks': [{'type': 'command', 'timeout': 10,
                       'command': f'{PYTHON} {TARGET} --repo {main_checkout()}'}]}


def toolchain_entry():
    return {'matcher': 'Bash|Monitor|mcp__terminal__.*',
            'hooks': [{'type': 'command', 'timeout': 10, 'command': f'{PYTHON} {TOOLCHAIN_TARGET}'}]}


def handoff_entries():
    command = {'type': 'command', 'timeout': 10, 'command': f'{PYTHON} {HANDOFF_TARGET}'}
    return {'PreToolUse': {'matcher': '*', 'hooks': [command]}, 'PostToolUse': {'matcher': '*', 'hooks': [command]}}


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--check', action='store_true')
    parser.add_argument('--context-handoff', action='store_true', help='also install the context hand-off hook')
    args = parser.parse_args()
    pairs = [(SOURCE, TARGET), (TOOLCHAIN_SOURCE, TOOLCHAIN_TARGET), (HANDOFF_SOURCE, HANDOFF_TARGET)]
    matches = [target.exists() and filecmp.cmp(source, target, shallow=False) for source, target in pairs]
    if args.check:
        for (source, target), ok in zip(pairs, matches):
            print(f'{target}: ' + ('matches ' + str(source) if ok else 'missing or different from ' + str(source)))
        return 0 if all(matches) else 1
    for (source, target), ok in zip(pairs, matches):
        if source == HANDOFF_SOURCE and not args.context_handoff:
            if not ok:
                state = 'differs from' if target.exists() else 'is missing; the source is'
                print(f'Left {target} as it is: it {state} {source}. Re-run with --context-handoff once the '
                      'owner has approved changing the live hook.')
            continue
        subprocess.run([PYTHON, '-m', 'py_compile', str(source)], check=True)
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, target)
        print(f'Installed {target}' + (' (unchanged)' if ok else ''))
    print('PreToolUse entries for ~/.claude/settings.json (hooks.PreToolUse):')
    print(json.dumps([settings_entry(), toolchain_entry()], indent=2))
    if args.context_handoff:
        print('Context hand-off entries for ~/.claude/settings.json (hooks.PreToolUse and hooks.PostToolUse):')
        print(json.dumps(handoff_entries(), indent=2))
    return 0


if __name__ == '__main__':
    sys.exit(main())
