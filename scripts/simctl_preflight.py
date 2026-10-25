"""Fail fast when `xcrun simctl` would hang on Xcode's first-launch install (#2591).

Since Xcode 27.1, `<developer dir>/usr/bin/simctl` is a bash wrapper. It reads CoreSimulator's CFBundleVersion and,
when that is missing or older than the wrapper's EXPECTED_VERSION, runs `xcodebuild -runFirstLaunch` before every
simctl command. That install asks for an admin password; an unattended job can't answer, so the call waits forever.
On 2026-10-24, after an overnight Xcode update, 17 orphaned `-runFirstLaunch` waiters piled up behind one dialog.

`problem()` reads the same two values the wrapper reads and compares them the same way (trailing `.0` parts
stripped, then a version sort). It returns a message naming the cause and the fix, or None. A wrapper that is
missing, is not a script, or has no EXPECTED_VERSION line passes: nothing to compare, so no claim is made.

`bounded_output()` runs a command in its own process group and, at its timeout, kills the whole group, so a timed-out
`simctl` never leaves its `xcodebuild` child behind (the 17 waiters were such orphans, most with ppid 1).

Run it as a script for a one-line check (the Mac tick): exit 0 prints OK, exit 1 prints the problem.
Stdlib only, Python 3.9-compatible.
"""
from __future__ import annotations

import os
from pathlib import Path
import plistlib
import re
import signal
import subprocess
import sys
from typing import Optional

CORESIMULATOR_PLIST = Path('/Library/Developer/PrivateFrameworks/CoreSimulator.framework/Versions/A/Resources/Info.plist')
FIX = 'run `sudo xcodebuild -runFirstLaunch` in Terminal (it needs the Mac password), then retry'
EXPECTED_LINE = re.compile(r'^\s*EXPECTED_VERSION=["\']?([^"\'\s]+)["\']?\s*$', re.M)


def canonical(version: str) -> str:
    """The wrapper's canonicalize_version: strip trailing `.0` parts (1107.0 -> 1107)."""
    while version.endswith('.0'):
        version = version[:-2]
    return version


def _sort_key(version: str) -> list:
    # Close to `sort --version-sort` for dotted versions: numbers compare as numbers, other text as text.
    return [(0, int(part), '') if part.isdigit() else (1, 0, part) for part in re.findall(r'\d+|\D+', version)]


def is_older(current: str, expected: str) -> bool:
    """The wrapper's version_is_older."""
    a, b = canonical(current), canonical(expected)
    return a != b and _sort_key(a) < _sort_key(b)


def expected_version(wrapper: Path) -> Optional[str]:
    """The wrapper's EXPECTED_VERSION, or None when it is missing, not a script, or has no such line."""
    try:
        with wrapper.open('rb') as handle:
            head = handle.read(64 * 1024)
    except OSError:
        return None
    if not head.startswith(b'#!'):
        return None
    match = EXPECTED_LINE.search(head.decode('utf-8', 'replace'))
    return match.group(1) if match else None


def installed_version(plist: Path) -> str:
    """CoreSimulator's CFBundleVersion, or '' when the plist is missing or unreadable (the wrapper's empty case)."""
    try:
        with plist.open('rb') as handle:
            value = plistlib.load(handle).get('CFBundleVersion')
    except (OSError, ValueError, plistlib.InvalidFileException, AttributeError):
        return ''
    return str(value).strip() if value is not None else ''


def developer_dir() -> Optional[Path]:
    if os.environ.get('DEVELOPER_DIR'):
        return Path(os.environ['DEVELOPER_DIR'])
    try:
        found = subprocess.run(['xcode-select', '-p'], capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.SubprocessError):
        return None
    return Path(found.stdout.strip()) if found.returncode == 0 and found.stdout.strip() else None


def default_wrapper() -> Optional[Path]:
    root = developer_dir()
    return root / 'usr' / 'bin' / 'simctl' if root else None


def problem(wrapper: Optional[Path] = None, plist: Path = CORESIMULATOR_PLIST) -> Optional[str]:
    """Why `xcrun simctl` would wait on Xcode's first-launch install, or None when it won't."""
    wrapper = default_wrapper() if wrapper is None else wrapper
    expected = expected_version(wrapper) if wrapper else None
    if not expected:
        return None
    current = installed_version(plist)
    if not current:
        return (f'CoreSimulator is missing (no CFBundleVersion in {plist}), so every simctl call would wait on '
                f'an admin-password prompt for Xcode {expected} components; {FIX}.')
    if is_older(current, expected):
        return (f'CoreSimulator is older than Xcode expects ({current}, Xcode wants {expected}), so every simctl '
                f'call would wait on an admin-password prompt; {FIX}.')
    return None


def bounded_output(cmd: list, timeout: float, text: bool = True) -> str:
    """subprocess.check_output, except that at the timeout the command's whole process group is killed.

    Raises subprocess.TimeoutExpired or CalledProcessError like check_output."""
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, text=text, start_new_session=True)
    try:
        out, _ = proc.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        kill_group(proc)
        raise
    except BaseException:
        kill_group(proc)
        raise
    if proc.returncode:
        raise subprocess.CalledProcessError(proc.returncode, cmd, output=out)
    return out


def kill_group(proc: subprocess.Popen) -> None:
    try:
        os.killpg(proc.pid, signal.SIGKILL)  # the group start_new_session made; its id is the child's pid
    except (ProcessLookupError, PermissionError):
        pass
    try:
        proc.communicate(timeout=5)
    except (subprocess.TimeoutExpired, ValueError, OSError):
        pass


def main() -> int:
    found = problem()
    print(found or 'OK: simctl will not wait on Xcode first-launch')
    return 1 if found else 0


if __name__ == '__main__':
    sys.exit(main())
