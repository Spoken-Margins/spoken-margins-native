#!/usr/bin/env python3
"""The phone-only build settings both rolling phone builds share, and the check that a built app carries them (#3354).

Config/PhoneBuild.xcconfig lists them. scripts/phone-build (the Mac) and .github/workflows/phone-build.yml (the
GitHub-hosted build the owner's Mac installs) pass it with `-xcconfig`, then check the app before the installer
may see it:

  python3 scripts/phone_build_settings.py check path/to/SpokenMarginsApp.app

Each setting writes an Info.plist key (project.yml), so the check reads what the build actually compiled with.
It exits 0 when every key matches, 1 naming each mismatch, 2 when the file or the app can't be read. Stdlib only:
the hosted runner runs it with the system python3.
"""
from __future__ import annotations

import plistlib
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
XCCONFIG = ROOT / 'Config' / 'PhoneBuild.xcconfig'
# The Info.plist key each setting writes (project.yml, the app target's info properties).
PLIST_KEYS = {'SM_PHONE_BUILD': 'SMPhoneBuild', 'SM_SHARE_LINK_CREATION': 'SMShareLinkCreation'}
_LINE = re.compile(r'^\s*([A-Z][A-Z0-9_]*)\s*=\s*(\S.*?)\s*;?\s*$')


def read(path: Path = XCCONFIG) -> dict[str, str]:
    """The settings in an xcconfig: NAME = VALUE lines, with // comments and blank lines skipped."""
    settings = {}
    for raw in path.read_text().splitlines():
        line = raw.split('//', 1)[0]
        if not line.strip():
            continue
        match = _LINE.match(line)
        if not match:
            raise ValueError(f'{path.name}: not a NAME = VALUE line: {raw!r}')
        settings[match.group(1)] = match.group(2)
    return settings


def mismatches(info: dict, settings: dict[str, str]) -> list[str]:
    """What the app's Info.plist says differently from `settings`, one line each; empty when they agree.

    A key missing from the plist counts as a mismatch: a build without it can't show it carries the setting."""
    problems = []
    for name, value in settings.items():
        key = PLIST_KEYS.get(name)
        if key is None:
            problems.append(f'{name} has no Info.plist key in PLIST_KEYS, so no build can show it carries it')
        elif info.get(key) != value:
            problems.append(f'{key} is {info.get(key)!r}, but {XCCONFIG.name} sets {name} = {value}')
    return problems


def main(argv: list[str]) -> int:
    if len(argv) != 2 or argv[0] != 'check':
        print(__doc__.split('\n\n')[1].strip(), file=sys.stderr)
        return 2
    try:
        settings = read()
        info = plistlib.loads((Path(argv[1]) / 'Info.plist').read_bytes())
    except (OSError, ValueError, plistlib.InvalidFileException) as error:
        print(f"phone build settings: can't read the inputs: {error}", file=sys.stderr)
        return 2
    problems = mismatches(info, settings)
    for problem in problems:
        print(f'phone build settings: {problem}', file=sys.stderr)
    if not problems:
        print('phone build settings: ' + ', '.join(f'{PLIST_KEYS[n]}={v}' for n, v in settings.items()))
    return 1 if problems else 0


if __name__ == '__main__':
    raise SystemExit(main(sys.argv[1:]))
