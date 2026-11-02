#!/usr/bin/env python3
"""Keep the checkout a scheduled Mac job runs from pinned to `main` (#2372).

The launchd jobs `phone-build` and `daily-phone-plan` used to run from the owner's development checkout. On
2026-10-21 a session left it on `ws/810-clipped-page-voiceover`: the phone-build job ran code from before #2361 and
the `phone-plan` binary was missing there. The two jobs now run from the ops checkout (`~/SpokenMarginsOps/repo`,
the one `codex-audit` and `integration-run` already use), and this module keeps that checkout on `origin/main`:

    pin(repo)                    fetch `main`, then move the checkout to it, detached, whatever it was on
    pin_from_env()               pin() for the path in SM_PIN_CHECKOUT, which the two job plists set; unset does nothing
    ensure_validator(repo)       build `phone-plan` when it is missing or its sources changed since the last build

Both jobs call `pin_from_env()` first thing. A script run by hand from a development checkout has no
SM_PIN_CHECKOUT, so nothing here ever switches a checkout a person is working in. A checkout with uncommitted changes
to tracked files is left alone and named in the log and in one Mac notification a day: the jobs run what is there,
which is the old behaviour, rather than lose work. A failed fetch (offline) is not a problem; the checkout still moves
to the `origin/main` it already has.

Stdlib only, Python 3.9+. `python3 scripts/ops_checkout.py --repo PATH` pins by hand and prints the result.
"""
from __future__ import annotations

import argparse
import datetime
import fcntl
import json
import os
import subprocess
import sys
import time
from pathlib import Path
from typing import Callable, Optional

sys.path.insert(0, str(Path(__file__).resolve().parent))
import sm_paths  # noqa: E402

PIN_ENV = 'SM_PIN_CHECKOUT'
DONE_ENV = 'SM_OPS_PINNED'  # set once this process (and what it starts) has pinned, so a script that loads another pins once
MIN_INTERVAL = 240          # seconds: the two jobs tick every 5 and 10 minutes, so a fetch per job tick is enough
VALIDATOR = 'Packages/SessionKitTools/.build/release/phone-plan'
VALIDATOR_STAMP = VALIDATOR + '.tree'
VALIDATOR_SOURCES = ('Packages/SessionKitTools', 'Packages/SessionKit')  # phone-plan depends on SessionKit
BUILD_COMMAND = ['swift', 'build', '--package-path', 'Packages/SessionKitTools', '-c', 'release',
                 '--product', 'phone-plan', '--disable-sandbox']
BUILD_TIMEOUT = 1800


def git(repo: Path, *args: str, timeout: int = 120) -> subprocess.CompletedProcess:
    return subprocess.run(['git', *args], cwd=str(repo), capture_output=True, text=True, timeout=timeout,
                          env={**os.environ, 'GIT_TERMINAL_PROMPT': '0'})


def osascript_notify(title: str, message: str) -> None:
    script = ['-e', 'on run argv', '-e', 'display notification (item 1 of argv) with title (item 2 of argv)',
              '-e', 'end run']
    try:
        subprocess.run(['osascript', *script, message, title], capture_output=True, timeout=30)
    except (OSError, subprocess.TimeoutExpired):
        pass


def _problem(state: Path, text: str, notify: Optional[Callable[[str, str], None]], today: str) -> str:
    """Say a problem in the return value (so the job log has it) and in one notification a day per distinct text."""
    record = state / 'problem.json'
    try:
        last = json.loads(record.read_text())
    except (OSError, ValueError):
        last = {}
    if notify and last != {'day': today, 'text': text}:
        notify('Spoken Margins: scheduled jobs are not on main', text)
        record.write_text(json.dumps({'day': today, 'text': text}) + '\n')
    return f'problem: {text}'


def pin(repo: Path, branch: str = 'main', state: Optional[Path] = None,
        notify: Optional[Callable[[str, str], None]] = None, min_interval: int = MIN_INTERVAL,
        now: Callable[[], float] = time.time) -> str:
    """Move `repo` to `origin/<branch>`, detached. Returns one line: what it did, or "problem: ..." when it could not."""
    repo = Path(repo)
    state = Path(state) if state else sm_paths.state_dir('ops-checkout')
    state.mkdir(parents=True, exist_ok=True)
    today = datetime.date.fromtimestamp(now()).isoformat()
    with open(state / 'lock', 'a+') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return 'busy: another job is pinning the checkout'
        stamp = state / 'last-pin'
        if git(repo, 'rev-parse', '--is-inside-work-tree').stdout.strip() != 'true':
            return _problem(state, f'{repo} is not a git checkout, so the jobs run whatever code is there. '
                                   'Clone the repository there again (docs/scheduled-jobs.md).', notify, today)
        head = git(repo, 'rev-parse', 'HEAD').stdout.strip()
        wrong_ref = git(repo, 'symbolic-ref', '-q', 'HEAD').returncode == 0  # on a branch: the 2026-10-21 failure
        try:
            recent = now() - stamp.stat().st_mtime < min_interval
        except OSError:
            recent = False
        # A recent check skips only the fetch; a checkout that someone moved onto a branch is put back every time.
        fetched = ''
        if not recent:
            done = git(repo, 'fetch', 'origin', branch, '-q', timeout=300)
            fetched = '' if done.returncode == 0 else ' (could not fetch; used the main it already had)'
            stamp.write_text(f'{int(now())}\n')
            os.utime(stamp, (now(), now()))
        target = git(repo, 'rev-parse', '--verify', '-q', f'origin/{branch}^{{commit}}').stdout.strip()
        if not target:
            return _problem(state, f'{repo} has no origin/{branch}; the jobs run whatever code is there.', notify, today)
        if head == target and not wrong_ref:
            return f'current: {target[:7]}{fetched}'
        if git(repo, 'status', '--porcelain', '--untracked-files=no').stdout.strip():
            return _problem(state, f'{repo} has uncommitted changes to tracked files, so it stays on '
                                   f'{head[:7]} instead of main {target[:7]}. Commit or discard them.', notify, today)
        moved = git(repo, 'checkout', '--detach', '-q', target)
        if moved.returncode:
            return _problem(state, f'{repo} could not move to main {target[:7]}: '
                                   f'{(moved.stderr or moved.stdout).strip()[:200]}', notify, today)
        (state / 'problem.json').unlink(missing_ok=True)
        return f'moved: {head[:7]} -> {target[:7]}{fetched}'


def pinned_repo() -> Optional[Path]:
    """The checkout the job plists ask to keep on main (SM_PIN_CHECKOUT), or None for a script run by hand."""
    value = (os.environ.get(PIN_ENV) or '').strip()
    return Path(os.path.abspath(os.path.expanduser(value))) if value else None


def pin_from_env(notify: Optional[Callable[[str, str], None]] = osascript_notify,
                 reexec: bool = False) -> Optional[str]:
    """pin() for SM_PIN_CHECKOUT. None when it is unset or this process already pinned. Never raises.

    reexec=True: after the checkout moved, start this script again from the new files (the process loaded the old
    ones), so a run never executes the previous main's code. The pin is recorded in the environment, so it happens once.
    """
    repo = pinned_repo()
    if repo is None or os.environ.get(DONE_ENV):
        return None
    os.environ[DONE_ENV] = '1'
    try:
        from trunk import trunk_branch  # the trunk is `main` unless SM_TRUNK says otherwise (#1492)
        result = pin(repo, trunk_branch(), notify=notify)
    except (OSError, subprocess.SubprocessError, ImportError, ValueError) as error:
        result = f'problem: could not pin {repo}: {error}'
    print(f'ops checkout: {result}', file=sys.stderr)
    if reexec and result.startswith('moved:'):
        sys.stderr.flush()
        os.execv(sys.executable, [sys.executable, *sys.argv])
    return result


def _trees(repo: Path) -> str:
    out = git(repo, 'rev-parse', *[f'HEAD:{path}' for path in VALIDATOR_SOURCES])
    return out.stdout.strip() if out.returncode == 0 else ''


def ensure_validator(repo: Path, run: Callable = subprocess.run) -> Path:
    """The `phone-plan` binary in `repo`, built first when it is missing or the sources it was built from changed.

    A binary is current when its stamp holds the git tree ids of the two packages it builds from. If the build
    fails and an older binary exists, that one is used and the failure goes to the log; without any binary this raises.
    """
    repo = Path(repo)
    binary, stamp = repo / VALIDATOR, repo / VALIDATOR_STAMP
    trees = _trees(repo)
    try:
        # No tree ids (a shallow clone, say): an existing binary stands, rather than a rebuild on every tick.
        current = binary.exists() and (not trees or stamp.read_text().strip() == trees)
    except OSError:
        current = False
    if current:
        return binary
    try:
        done = run(BUILD_COMMAND, cwd=str(repo), capture_output=True, text=True, timeout=BUILD_TIMEOUT)
        failure = '' if done.returncode == 0 else (done.stderr or done.stdout).strip()[-400:] or f'exit {done.returncode}'
    except (OSError, subprocess.TimeoutExpired) as error:
        failure = str(error)
    if failure:
        if binary.exists():
            print(f'phone-plan could not be rebuilt ({failure}); using the binary from the last build', file=sys.stderr)
            return binary
        raise RuntimeError(f'phone-plan is missing and could not be built in {repo}: {failure}')
    if trees:
        stamp.write_text(trees + '\n')
    return binary


def main(argv: Optional[list] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    parser.add_argument('--repo', required=True, help='the checkout to pin')
    parser.add_argument('--branch', default='main')
    args = parser.parse_args(argv)
    result = pin(Path(args.repo), args.branch, min_interval=0)
    print(result)
    return 1 if result.startswith('problem') else 0


if __name__ == '__main__':
    sys.exit(main())
