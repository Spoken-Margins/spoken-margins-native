#!/usr/bin/env python3
"""Install the lane guard hook for every Claude Code session on this Mac.

Copies scripts/lane_guard.py to ~/.claude/hooks/ (a stable path, so switching branches in a
checkout can't remove the hook) and prints the entry for ~/.claude/settings.json. It never edits
settings.json itself: that file is the owner's, and changing it is an owner-approved step.

  scripts/install-lane-guard.py          copy the guard and print the settings entry
  scripts/install-lane-guard.py --check  exit 1 if the installed copy is missing or differs
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
PYTHON = '/usr/bin/python3'


def main_checkout():
    common = subprocess.check_output(['git', '-C', str(SOURCE.parent), 'rev-parse', '--path-format=absolute',
                                      '--git-common-dir'], text=True).strip()
    return Path(common).parent


def settings_entry():
    return {'matcher': 'Bash|Monitor|mcp__terminal__.*|mcp__.*[Ss]imulator.*',
            'hooks': [{'type': 'command', 'timeout': 10,
                       'command': f'{PYTHON} {TARGET} --repo {main_checkout()}'}]}


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    current = TARGET.exists() and filecmp.cmp(SOURCE, TARGET, shallow=False)
    if args.check:
        print(f'{TARGET}: ' + ('matches ' + str(SOURCE) if current else 'missing or different from ' + str(SOURCE)))
        return 0 if current else 1
    subprocess.run([PYTHON, '-m', 'py_compile', str(SOURCE)], check=True)
    TARGET.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(SOURCE, TARGET)
    print(f'Installed {TARGET}' + (' (unchanged)' if current else ''))
    print('PreToolUse entry for ~/.claude/settings.json (hooks.PreToolUse):')
    print(json.dumps(settings_entry(), indent=2))
    return 0


if __name__ == '__main__':
    sys.exit(main())
