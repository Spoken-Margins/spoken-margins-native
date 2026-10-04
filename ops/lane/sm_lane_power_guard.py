#!/usr/bin/env python3
"""Lane power guard: pause the self-hosted lane runners while the Mac can't stay awake (#762).

On battery, or with the lid closed and no external display, the Mac sleeps and wakes only for
seconds at a time (maintenance dark wakes). A runner that picks up a job during one of those wakes
goes back to sleep with it. GitHub stops hearing from the runner, and 10 minutes after the job
started it cancels the job. No log is uploaded, the tidy-up step never runs and no lane report is
posted. On 2026-10-02 to 10-04 the Mac was unplugged for 42 hours and lost about ten runs this way.

Every 15 seconds this checks the power source and the lid:

- Mac can stay awake (on power, lid open or an external display keeps it awake): start any lane
  runner service that isn't running.
- Mac can't stay awake, runner idle: stop the runner service. Queued jobs wait on GitHub until it's
  back on power, instead of being taken and lost.
- Mac can't stay awake, a job already running: leave it, and hold a `caffeinate` assertion until the
  job's worker exits. On battery with the lid open that keeps idle sleep away; nothing can keep a
  closed lid awake. The runner is stopped on the first check after the job ends.

It finds the runners from their launchd plists (actions.runner.uncomposed-spoken-margins-native.*)
in ~/Library/LaunchAgents. It logs only changes, to ~/SpokenMarginsOps/lane-power-guard/log.txt.
`--dry-run` prints what it would do and changes nothing.

Stdlib only, Python 3.9+.
"""
from __future__ import annotations

import argparse
import datetime as dt
import os
import plistlib
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import List, Optional, Tuple

HOME = Path.home()
LAUNCH_AGENTS = HOME / 'Library' / 'LaunchAgents'
RUNNER_PREFIX = 'actions.runner.uncomposed-spoken-margins-native.'
LOG = HOME / 'SpokenMarginsOps' / 'lane-power-guard' / 'log.txt'


@dataclass(frozen=True)
class Runner:
    label: str
    directory: str
    service_running: bool
    worker_pid: Optional[int]

    @property
    def name(self) -> str:
        return self.label[len(RUNNER_PREFIX):] if self.label.startswith(RUNNER_PREFIX) else self.label


@dataclass(frozen=True)
class Action:
    kind: str  # 'start', 'stop' or 'hold'
    runner: Runner
    note: str


def awake_state(power_line: str, clamshell: str) -> Tuple[bool, str]:
    """Whether the Mac can stay awake for a job, from `pmset -g ps` and `ioreg` output."""
    if 'AC Power' not in power_line:
        return False, 'on battery'
    closed = re.search(r'"AppleClamshellState" = Yes', clamshell)
    sleeps = re.search(r'"AppleClamshellCausesSleep" = Yes', clamshell)
    if closed and sleeps:
        return False, 'lid closed'
    return True, 'on power'


def decide(can_stay_awake: bool, reason: str, runners: List[Runner], held_pids: List[int]) -> List[Action]:
    actions: List[Action] = []
    for runner in runners:
        if can_stay_awake:
            if not runner.service_running:
                actions.append(Action('start', runner, f'{runner.name}: started ({reason})'))
        elif runner.worker_pid is not None:
            if runner.worker_pid not in held_pids:
                actions.append(Action('hold', runner,
                                      f'{runner.name}: {reason} with a job running (worker {runner.worker_pid}); '
                                      'holding the Mac awake until it ends'))
        elif runner.service_running:
            actions.append(Action('stop', runner, f'{runner.name}: paused ({reason})'))
    return actions


def run(cmd: List[str]) -> str:
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=20).stdout
    except (OSError, subprocess.SubprocessError):
        return ''


def find_runners(uid: int) -> List[Runner]:
    runners = []
    for plist in sorted(LAUNCH_AGENTS.glob(RUNNER_PREFIX + '*.plist')):
        try:
            with plist.open('rb') as handle:
                data = plistlib.load(handle)
        except (OSError, plistlib.InvalidFileException):
            continue
        label = data.get('Label', plist.stem)
        directory = data.get('WorkingDirectory', '')
        state = run(['/bin/launchctl', 'print', f'gui/{uid}/{label}'])
        service_running = re.search(r'^\tstate = running$', state, re.MULTILINE) is not None
        workers = run(['/usr/bin/pgrep', '-f', f'{directory}/bin/Runner.Worker']).split()
        runners.append(Runner(label, directory, service_running, int(workers[0]) if workers else None))
    return runners


def held_worker_pids() -> List[int]:
    """Workers that already have this guard's caffeinate hold on them."""
    held = []
    for line in run(['/usr/bin/pgrep', '-fl', 'caffeinate -ims -w ']).splitlines():
        match = re.search(r'caffeinate -ims -w (\d+)', line)
        if match:
            held.append(int(match.group(1)))
    return held


def apply(action: Action, uid: int) -> None:
    target = f'gui/{uid}/{action.runner.label}'
    if action.kind == 'start':
        subprocess.run(['/bin/launchctl', 'kickstart', target], timeout=20)
    elif action.kind == 'stop':
        # runsvc.sh turns TERM into INT, which stops the listener cleanly. The plist has no
        # KeepAlive, so it stays stopped until the next 'start'.
        subprocess.run(['/bin/launchctl', 'kill', 'TERM', target], timeout=20)
    elif action.kind == 'hold':
        subprocess.Popen(['/usr/bin/caffeinate', '-ims', '-w', str(action.runner.worker_pid)],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)


def log(line: str) -> None:
    LOG.parent.mkdir(parents=True, exist_ok=True)
    stamp = dt.datetime.now(dt.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
    with LOG.open('a') as handle:
        handle.write(f'{stamp} {line}\n')


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    parser.add_argument('--dry-run', action='store_true', help='print what it would do and change nothing')
    args = parser.parse_args(argv)

    uid = os.getuid()
    can_stay_awake, reason = awake_state(run(['/usr/bin/pmset', '-g', 'ps']),
                                         run(['/usr/sbin/ioreg', '-r', '-k', 'AppleClamshellState', '-d', '4']))
    runners = find_runners(uid)
    actions = decide(can_stay_awake, reason, runners, held_worker_pids())
    if args.dry_run:
        print(f'Mac {"can" if can_stay_awake else "cannot"} stay awake ({reason}); '
              f'{len(runners)} runner(s): ' + ', '.join(
                  f'{r.name} {"running" if r.service_running else "stopped"}'
                  + (f' with worker {r.worker_pid}' if r.worker_pid else '') for r in runners))
        for action in actions:
            print('would ' + action.note)
        if not actions:
            print('nothing to do')
        return 0
    for action in actions:
        apply(action, uid)
        log(action.note)
    return 0


if __name__ == '__main__':
    sys.exit(main())
