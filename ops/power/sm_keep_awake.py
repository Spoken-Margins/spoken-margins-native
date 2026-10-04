#!/usr/bin/env python3
"""Keep awake: hold the Mac awake with Amphetamine while builds or agents are working.

Owner, 2026-10-04: keep the project's builds going on Wi-Fi and on battery down to 10%.

Every minute (launchd), it looks for work and, when there is some, asks Amphetamine for a short
session through `ops/power/amph ensure`. The session renews at half-life while the work goes on
and simply runs out once it stops, so the Mac goes back to its normal sleep settings by itself.

Work means either of these:
- a build or test process is running: xcodebuild, swift-build, swift-test, swift-frontend,
  xctest, or a lane job's Runner.Worker. This holds even without a network, so a local build
  can finish.
- an agent wrote to its transcript in the last 10 minutes (Claude Code under ~/.claude/projects,
  Codex under ~/.codex/sessions), and the Mac has a reachable network. An open Claude app or an
  idle session doesn't count, and an agent without a network is stuck anyway.

On battery at or below 10% it never asks for a session; Amphetamine's own low-battery setting
ends any session at the same level. It never ends or shortens a session; `amph ensure` keeps
sessions that run until stopped, until a time, while an app runs, or from a Trigger.

`--lid` also keeps the Mac running with its lid closed (Amphetamine's closed-display mode).

Stdlib only, Python 3.9+. `--dry-run` prints what it sees and decides, and changes nothing.
Decisions that change, and every session it starts, go to ~/SpokenMarginsOps/keep-awake/log.txt.
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path
from typing import Iterable, List, Optional, Tuple

BUILD_PROCESSES = ('xcodebuild', 'swift-build', 'swift-test', 'swift-frontend', 'xctest',
                   'Runner.Worker')
TRANSCRIPT_ROOTS = (Path.home() / '.claude' / 'projects', Path.home() / '.codex' / 'sessions')
STATE_DIR = Path.home() / 'SpokenMarginsOps' / 'keep-awake'
AMPH = Path(__file__).resolve().with_name('amph')


def parse_battery(pmset_batt: str) -> Tuple[bool, Optional[int]]:
    """(on battery, charge %) from `pmset -g batt`. A Mac without a battery reads as on power."""
    on_battery = "'Battery Power'" in pmset_batt
    match = re.search(r'(\d+)%', pmset_batt)
    return on_battery, int(match.group(1)) if match else None


def network_reachable(scutil_nwi: str) -> bool:
    """True when `scutil --nwi` reports a reachable network on any interface."""
    return '(Reachable)' in scutil_nwi


def build_processes(ps_comm: str) -> List[str]:
    """Names of build or test processes in `ps -axo comm` output, each listed once."""
    found = []
    for line in ps_comm.splitlines():
        name = os.path.basename(line.strip())
        if name in BUILD_PROCESSES and name not in found:
            found.append(name)
    return found


def newest_transcript_age(roots: Iterable[Path], now: float) -> Optional[float]:
    """Seconds since any agent transcript (*.jsonl) under `roots` was last written."""
    newest = None
    for root in roots:
        for dirpath, _dirs, files in os.walk(root):
            for name in files:
                if not name.endswith('.jsonl'):
                    continue
                try:
                    mtime = os.stat(os.path.join(dirpath, name)).st_mtime
                except OSError:
                    continue
                if newest is None or mtime > newest:
                    newest = mtime
    return None if newest is None else max(0.0, now - newest)


def decide(on_battery: bool, charge: Optional[int], network: bool, builds: List[str],
           agent_age: Optional[float], low_battery: int = 10,
           fresh_seconds: int = 600) -> Tuple[bool, str]:
    """(hold the Mac awake, why)."""
    if on_battery and charge is not None and charge <= low_battery:
        return False, f'battery at {charge}%, at or below {low_battery}%'
    if builds:
        return True, 'build running: ' + ', '.join(builds)
    agent_fresh = agent_age is not None and agent_age <= fresh_seconds
    if agent_fresh and network:
        return True, f'agent active (transcript written {int(agent_age)}s ago)'
    if agent_fresh:
        return False, 'agent active but no network'
    return False, 'no builds or agent activity'


def run(cmd: List[str], timeout: int = 30) -> str:
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout).stdout
    except (OSError, subprocess.TimeoutExpired):
        return ''


def amph(args: List[str]) -> Tuple[bool, str]:
    """Run the amph CLI. Amphetamine may show a one-time permission prompt, hence the timeout."""
    try:
        done = subprocess.run(['/usr/bin/osascript', str(AMPH)] + args, capture_output=True,
                              text=True, timeout=60)
    except subprocess.TimeoutExpired:
        return False, 'amph timed out (a permission or closed-display prompt may be waiting)'
    output = (done.stdout or done.stderr).strip()
    return done.returncode == 0, output


def log(line: str) -> None:
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    stamp = dt.datetime.now().astimezone().strftime('%Y-%m-%d %H:%M:%S %z')
    with open(STATE_DIR / 'log.txt', 'a') as handle:
        handle.write(f'{stamp} {line}\n')


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    parser.add_argument('--dry-run', action='store_true', help='print, change nothing')
    parser.add_argument('--lid', action='store_true', help='also keep running with the lid closed')
    parser.add_argument('--minutes', type=int, default=20, help='session length (default 20)')
    parser.add_argument('--low-battery', type=int, default=10, help='stop holding at this %%')
    parser.add_argument('--fresh-minutes', type=int, default=10,
                        help='how recent an agent transcript write counts as active')
    args = parser.parse_args(argv)

    on_battery, charge = parse_battery(run(['/usr/bin/pmset', '-g', 'batt']))
    network = network_reachable(run(['/usr/sbin/scutil', '--nwi']))
    builds = build_processes(run(['/bin/ps', '-axo', 'comm']))
    agent_age = newest_transcript_age(TRANSCRIPT_ROOTS, time.time())
    keep, why = decide(on_battery, charge, network, builds, agent_age, args.low_battery,
                       args.fresh_minutes * 60)

    if args.dry_run:
        print(json.dumps({'on_battery': on_battery, 'charge': charge, 'network': network,
                          'builds': builds,
                          'agent_age_seconds': None if agent_age is None else int(agent_age),
                          'hold_awake': keep, 'why': why}, indent=2))
        return 0

    state_file = STATE_DIR / 'last.json'
    try:
        last = json.loads(state_file.read_text())
    except (OSError, ValueError):
        last = {}
    if last.get('hold_awake') != keep:
        log(('hold: ' if keep else 'release: ') + why)

    result = ''
    if keep:
        ok, result = amph(['ensure', str(args.minutes)] + (['--lid'] if args.lid else []))
        if not ok or result.startswith('started') or 'turned on' in result:
            log(('amph: ' if ok else 'amph failed: ') + result)

    STATE_DIR.mkdir(parents=True, exist_ok=True)
    state_file.write_text(json.dumps({'hold_awake': keep, 'why': why, 'amph': result}))
    return 0


if __name__ == '__main__':
    sys.exit(main())
