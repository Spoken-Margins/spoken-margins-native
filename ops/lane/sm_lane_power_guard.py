#!/usr/bin/env python3
"""Lane power guard: pause the self-hosted lane runners while the Mac can't stay awake (#762).

On battery, or with the lid closed and no external display, the Mac sleeps and wakes only for
seconds at a time (maintenance dark wakes). A runner that picks up a job during one of those wakes
goes back to sleep with it. GitHub stops hearing from the runner, and 10 minutes after the job
started it cancels the job. No log is uploaded, the tidy-up step never runs and no lane report is
posted. On 2026-10-02 to 10-04 the Mac was unplugged for 42 hours and lost about ten runs this way.

Every 15 seconds this checks the power source and the lid:

- Mac can stay awake (on power with the lid open or an external display, or an Amphetamine
  session above 10% battery, with its lid-closed running on if the lid is shut): start the runners
  this guard paused. A runner stopped some other way (by hand, or after a session conflict) is left
  alone.
- Mac can't stay awake, runner idle: stop the runner service and remember that the guard paused it.
  Queued jobs wait on GitHub until it's back on power, instead of being taken and lost.
- Mac can't stay awake, a job already running (a worker process, or the listener's log shows a job
  started and not finished): leave it, and hold a `caffeinate` assertion until the job's worker
  exits, then check again at once so the runner is paused before it takes the next queued job. On
  battery with the lid open that keeps idle sleep away; caffeinate can't keep a closed lid awake.

It finds the runners from their launchd plists (actions.runner.<owner>-spoken-margins-native.*)
in ~/Library/LaunchAgents. It logs only changes, to ~/SpokenMarginsOps/lane-power-guard/log.txt.
`--dry-run` prints what it would do and changes nothing.

Stdlib only, Python 3.9+.
"""
from __future__ import annotations

import argparse
import contextlib
import datetime as dt
import fcntl
import os
import plistlib
import re
import shlex
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Iterator, List, Optional, Tuple

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'scripts'))
import sm_paths  # noqa: E402

HOME = Path.home()
LAUNCH_AGENTS = HOME / 'Library' / 'LaunchAgents'
RUNNER_PREFIX = 'actions.runner.uncomposed-spoken-margins-native.'
# A runner registered again after the move to the org (#2169) gets the org's prefix.
RUNNER_PREFIXES = (RUNNER_PREFIX, 'actions.runner.Spoken-Margins-spoken-margins-native.')
STATE_DIR = sm_paths.state_dir('lane-power-guard', home=HOME)
LOG = STATE_DIR / 'log.txt'
PAUSED = STATE_DIR / 'paused'  # one runner label per line: the runners this guard stopped
LOCK = STATE_DIR / 'lock'  # held for a whole look-decide-act cycle (#836)
LOW_BATTERY = 10  # percent; Amphetamine ends its sessions here too


@dataclass(frozen=True)
class Runner:
    label: str
    directory: str
    service_running: bool
    worker_pid: Optional[int]
    listener_has_job: bool = False

    @property
    def busy(self) -> bool:
        return self.worker_pid is not None or self.listener_has_job

    @property
    def name(self) -> str:
        for prefix in RUNNER_PREFIXES:
            if self.label.startswith(prefix):
                return self.label[len(prefix):]
        return self.label


@dataclass(frozen=True)
class Action:
    kind: str  # 'start', 'stop' or 'hold'
    runner: Runner
    note: str


def awake_state(power_line: str, clamshell: str, amphetamine: Optional[Tuple[bool, bool]] = None,
                low_battery: int = LOW_BATTERY) -> Tuple[bool, str]:
    """Whether the Mac can stay awake for a job, from `pmset -g ps`, `ioreg` and Amphetamine.

    `amphetamine` is (session active, lid-closed running on), or None when it isn't running or
    can't be asked. An Amphetamine session keeps the Mac awake on battery above `low_battery`
    percent (where Amphetamine itself ends sessions), and with the lid closed when its lid-closed
    running is on. macOS still reports that closing the lid causes sleep while Amphetamine holds
    it, so the clamshell reading alone can't tell."""
    on_power = 'AC Power' in power_line
    closed = re.search(r'"AppleClamshellState" = Yes', clamshell)
    sleeps = re.search(r'"AppleClamshellCausesSleep" = Yes', clamshell)
    lid_sleeps = bool(closed and sleeps)
    if on_power and not lid_sleeps:
        return True, 'on power'
    blocked = 'on battery' if not on_power else 'lid closed'
    active, lid_awake = amphetamine or (False, False)
    if not active:
        return False, blocked
    if not on_power:
        match = re.search(r'(\d+)%', power_line)
        charge = int(match.group(1)) if match else None
        if charge is None or charge <= low_battery:
            return False, f'on battery at {charge if charge is not None else "unknown"}%'
    if lid_sleeps and not lid_awake:
        return False, 'lid closed'
    where = 'on power' if on_power else f'on battery at {charge}%'
    return True, f'Amphetamine holds the Mac awake ({where}{", lid closed" if lid_sleeps else ""})'


AMPHETAMINE_QUERY = '''if application "Amphetamine" is running then
    tell application "Amphetamine" to return ((session is active) as text) & "," & ((closed display mode enabled) as text)
end if
return "not running"'''


def amphetamine_state() -> Optional[Tuple[bool, bool]]:
    """(session active, lid-closed running on) from Amphetamine, or None. Never launches it."""
    answer = run(['/usr/bin/osascript', '-e', AMPHETAMINE_QUERY]).strip()
    if ',' not in answer:
        return None
    active, lid_awake = answer.split(',', 1)
    return active == 'true', lid_awake == 'true'


def listener_has_job(runner_log_tail: str) -> bool:
    """Whether the listener has taken a job it hasn't finished, from the end of its Runner_*.log.

    Covers the moment between the listener accepting a job and its worker process starting, when a
    stop would cancel the job."""
    started = runner_log_tail.rfind('Running job:')
    finished = runner_log_tail.rfind('completed with result:')
    return started > finished


def decide(can_stay_awake: bool, reason: str, runners: List[Runner], held_pids: List[int],
           paused_labels: List[str]) -> List[Action]:
    actions: List[Action] = []
    for runner in runners:
        if can_stay_awake:
            if not runner.service_running and runner.label in paused_labels:
                actions.append(Action('start', runner, f'{runner.name}: started ({reason})'))
        elif runner.busy:
            if runner.worker_pid is not None and runner.worker_pid not in held_pids:
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
    for plist in sorted(p for prefix in RUNNER_PREFIXES for p in LAUNCH_AGENTS.glob(prefix + '*.plist')):
        try:
            with plist.open('rb') as handle:
                data = plistlib.load(handle)
        except (OSError, plistlib.InvalidFileException):
            continue
        runners.append(observe(uid, data.get('Label', plist.stem), data.get('WorkingDirectory', '')))
    return runners


def observe(uid: int, label: str, directory: str) -> Runner:
    """One runner's service state, worker and listener job, read now."""
    state = run(['/bin/launchctl', 'print', f'gui/{uid}/{label}'])
    service_running = re.search(r'^\tstate = running$', state, re.MULTILINE) is not None
    workers = run(['/usr/bin/pgrep', '-f', f'{directory}/bin/Runner.Worker']).split()
    return Runner(label, directory, service_running, int(workers[0]) if workers else None,
                  listener_has_job(runner_log_tail(Path(directory) / '_diag')))


def runner_log_tail(diag: Path, size: int = 256 * 1024) -> str:
    logs = sorted(diag.glob('Runner_*.log'))
    if not logs:
        return ''
    try:
        with logs[-1].open('rb') as handle:
            handle.seek(max(0, logs[-1].stat().st_size - size))
            return handle.read().decode('utf-8', 'replace')
    except OSError:
        return ''


def paused_labels() -> List[str]:
    try:
        return [line for line in PAUSED.read_text().split() if line]
    except OSError:
        return []


def set_paused(label: str, paused: bool) -> None:
    """Record or forget one paused runner. Callers hold cycle_lock(), so two guards (the scheduled
    one and a worker-exit one) can't each rewrite the file from a stale read and drop a label."""
    labels = [l for l in paused_labels() if l != label] + ([label] if paused else [])
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    partial = PAUSED.with_name(PAUSED.name + '.partial')
    partial.write_text(''.join(l + '\n' for l in labels))
    partial.replace(PAUSED)


@contextlib.contextmanager
def cycle_lock() -> Iterator[None]:
    """One guard at a time looks at the runners, decides and acts (#836)."""
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    with LOCK.open('a') as handle:
        fcntl.flock(handle, fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.flock(handle, fcntl.LOCK_UN)


def held_worker_pids() -> List[int]:
    """Workers that already have this guard's caffeinate hold on them."""
    held = []
    for line in run(['/usr/bin/pgrep', '-fl', 'caffeinate -ims -w ']).splitlines():
        match = re.search(r'caffeinate -ims -w (\d+)', line)
        if match:
            held.append(int(match.group(1)))
    return held


def launchctl(args: List[str]) -> int:
    try:
        return subprocess.run(['/bin/launchctl', *args], capture_output=True, timeout=20).returncode
    except (OSError, subprocess.SubprocessError):
        return -1


def apply(action: Action, uid: int, control: Callable[[List[str]], int] = launchctl,
          look_again: Optional[Callable[[Runner], Runner]] = None) -> str:
    """Carry out one action and return the line to log."""
    target = f'gui/{uid}/{action.runner.label}'
    if action.kind == 'start':
        code = control(['kickstart', target])
        if code != 0:  # keep it marked paused, so the next check tries again (#836)
            return f'{action.runner.name}: start failed (launchctl kickstart exit {code}); will retry'
        set_paused(action.runner.label, False)
    elif action.kind == 'stop':
        # The runner looked idle when the cycle began; it may have taken a job since. Look once more
        # right before stopping it, because a stop cancels a job it holds (#836).
        now = (look_again or (lambda r: observe(uid, r.label, r.directory)))(action.runner)
        if now.busy:
            return f'{action.runner.name}: not paused; it took a job since the last look'
        # runsvc.sh turns TERM into INT, which stops the listener cleanly. The plist has no
        # KeepAlive, so it stays stopped until the next 'start'.
        code = control(['kill', 'TERM', target])
        if code != 0:
            return f'{action.runner.name}: pause failed (launchctl kill exit {code})'
        set_paused(action.runner.label, True)
    elif action.kind == 'hold':
        # Hold the Mac awake until the worker exits, then run the guard again straight away so the
        # runner is paused before its listener takes the next queued job.
        script = (f'/usr/bin/caffeinate -ims -w {action.runner.worker_pid}; '
                  f'exec /usr/bin/python3 {shlex.quote(str(Path(__file__).resolve()))}')
        subprocess.Popen(['/bin/sh', '-c', script],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    return action.note


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
    if args.dry_run:
        return cycle(uid, dry_run=True)
    with cycle_lock():
        return cycle(uid, dry_run=False)


def cycle(uid: int, dry_run: bool) -> int:
    power_line = run(['/usr/bin/pmset', '-g', 'ps'])
    clamshell = run(['/usr/sbin/ioreg', '-r', '-k', 'AppleClamshellState', '-d', '4'])
    can_stay_awake, reason = awake_state(power_line, clamshell)
    if not can_stay_awake:
        can_stay_awake, reason = awake_state(power_line, clamshell, amphetamine_state())
    runners = find_runners(uid)
    actions = decide(can_stay_awake, reason, runners, held_worker_pids(), paused_labels())
    if dry_run:
        print(f'Mac {"can" if can_stay_awake else "cannot"} stay awake ({reason}); '
              f'{len(runners)} runner(s): ' + ', '.join(
                  f'{r.name} {"running" if r.service_running else "stopped"}'
                  + (f' with worker {r.worker_pid}' if r.worker_pid else '')
                  + (' (listener holds a job)' if r.listener_has_job else '') for r in runners))
        for action in actions:
            print('would ' + action.note)
        if not actions:
            print('nothing to do')
        return 0
    for action in actions:
        log(apply(action, uid))
    return 0


if __name__ == '__main__':
    sys.exit(main())
