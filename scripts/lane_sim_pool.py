"""The Test Desk's pool of approved simulators (#688). Used by scripts/lane-sim-boot --pool and --done.

The owner approves each simulator device once in the simulator panel, and the approval survives an
erase. A fresh device per journey run therefore cost a click every run (five on 2026-10-01, twice
unanswered, so journeys were skipped). The desk keeps up to POOL_SIZE devices named
"SM Lane Desk pool N" and, instead of creating one, erases the least recently used free one and boots
it. A new device joins the pool only when none is free and the pool has room, so the owner approves
one only then.

The boot rules in lane_sim.py are unchanged and still decide whether a device is fit to use:
- a device marked unsafe (a failed or crashed boot, a SpringBoard crash, a late crash report) is retired:
  shut down, deleted and dropped from the pool, never erased or booted again;
- a boot is never retried on the same device;
- the first boot after an erase gets the first-boot tolerance, because an erased device migrates its
  data like a new one (the case the tolerance was granted for, #184).
The old standing device (1330F268, AGENTS.md: never boot it) is never adopted.

The pool is recorded in desk-simulator-pool.json in the lane state folder: the devices, when each was
last used and, while a process is taking or releasing one, who claimed it. A device is busy while simctl
lists it as anything but Shutdown, its watcher is running, or a live process claimed it, so two desk
runs never get the same device. The claim covers the gaps (before the boot, while --done erases); a
booted device is held by its Booted state and its watcher. A device whose erase fails stays in the pool
but goes last, and the next free one is used. Stdlib only, Python 3.9-compatible.
"""
from __future__ import annotations

import collections
import contextlib
import datetime
import fcntl
import json
import os
from pathlib import Path
import re
import subprocess
import sys

import lane_audio
import lane_sim
from lane_sim import BootError
from lane_slots import state_dir

POOL_SIZE = 3
NAME_PREFIX = 'SM Lane Desk pool '
# The old standing device, retired after it crash-flooded (AGENTS.md: never boot 1330F268).
RETIRED = frozenset({'1330F268-5467-4421-9D55-1FCC3FF5CF8A'})
ERASE_TIMEOUT = 300

Plan = collections.namedtuple('Plan', 'action udid name pool drop')
# action: 'reuse' (erase and boot udid), 'create' (make a device called name), or 'busy' (no device is free
# and the pool is full). pool: the entries to keep. drop: (udid, reason, delete) for each entry to retire.


def pool_path() -> Path:
    return state_dir() / 'desk-simulator-pool.json'


def now() -> str:
    return datetime.datetime.now(datetime.timezone.utc).isoformat(timespec='seconds')


def load() -> dict:
    try:
        entries = json.loads(pool_path().read_text()).get('devices', {})
    except (OSError, ValueError, AttributeError):
        return {}
    return entries if isinstance(entries, dict) else {}


def save(entries: dict) -> None:
    path = pool_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    scratch = path.with_name(path.name + '.tmp')
    scratch.write_text(json.dumps({'devices': entries}, indent=2, sort_keys=True) + '\n')
    os.replace(scratch, path)


@contextlib.contextmanager
def locked():
    """Hold the pool file's lock while reading and changing it, so two desk runs can't pick the same device."""
    path = state_dir() / 'desk-simulator-pool.lock'
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open('a') as handle:
        fcntl.flock(handle, fcntl.LOCK_EX)
        yield


def in_pool(udid: str) -> bool:
    return udid in load()


def runtime_major(runtime: str) -> int | None:
    match = re.search(r'iOS-(\d+)', runtime)
    return int(match.group(1)) if match else None


def listed_devices() -> dict:
    """{udid: {name, state, major}} for every available device simctl lists.

    Raises BootError when simctl can't say: an empty answer would retire the whole pool.
    """
    try:
        listing = json.loads(subprocess.check_output(lane_sim.simctl() + ['list', 'devices', 'available', '--json'],
                                                     text=True, timeout=120))
        return {device['udid']: {'name': device.get('name', ''), 'state': device.get('state', 'Shutdown'),
                                 'major': runtime_major(runtime)}
                for runtime, group in listing.get('devices', {}).items() for device in group}
    except (OSError, ValueError, KeyError, AttributeError, subprocess.SubprocessError) as error:
        raise BootError(f'simctl could not list the devices ({error}); no desk device was chosen.') from None


def pid_alive(pid) -> bool:
    if not isinstance(pid, int) or pid <= 0:
        return False
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except OSError:  # PermissionError: another user's process
        return True
    return True


def watcher_alive(udid: str) -> bool:
    try:
        return pid_alive(int(lane_sim.watch_files(udid)[2].read_text()))
    except (OSError, ValueError):
        return False


def busy_devices(entries: dict, devices: dict, alive=pid_alive, watching=watcher_alive) -> set:
    """The pool devices a run holds: simctl shows them up, a watcher runs for them, or a live process claimed them."""
    return {udid for udid, entry in entries.items()
            if devices.get(udid, {}).get('state', 'Shutdown') != 'Shutdown'
            or alive((entry.get('claimed') or {}).get('pid')) or watching(udid)}


def choose(entries: dict, devices: dict, unsafe: dict, busy: set, size: int = POOL_SIZE) -> Plan:
    """What the next desk run does with the pool. Pure, so the rules can be tested without a simulator.

    entries: the pool file's devices. devices: what simctl lists (listed_devices). unsafe: the lane's
    unsafe list. busy: the devices a run holds (busy_devices).
    """
    kept, drop = {}, []
    for udid, entry in entries.items():
        if udid in RETIRED:
            drop.append((udid, 'the old standing device stays retired', False))
        elif udid in unsafe and udid not in busy:
            drop.append((udid, f'marked unsafe ({unsafe[udid].get("reason", "no reason recorded")})', True))
        elif udid not in devices:
            drop.append((udid, 'simctl no longer lists it', False))
        elif devices[udid]['major'] != lane_sim.IOS_MAJOR:
            drop.append((udid, f'it is not an iOS {lane_sim.IOS_MAJOR} device', False))
        else:
            kept[udid] = entry
    for udid, device in sorted(devices.items()):  # the pool file was lost: take our own devices back by name
        if (len(kept) < size and udid not in entries and udid not in unsafe and udid not in RETIRED
                and device['name'].startswith(NAME_PREFIX) and device['major'] == lane_sim.IOS_MAJOR):
            kept[udid] = {'name': device['name']}
    free = [udid for udid in kept if udid not in busy and udid not in unsafe]
    if free:  # least recently used first, so every device gets used and the wear is even; one that failed an erase last
        udid = min(free, key=lambda u: (bool(kept[u].get('erase_failed')), kept[u].get('last_used') or '',
                                        kept[u].get('name', ''), u))
        return Plan('reuse', udid, kept[udid].get('name'), kept, drop)
    if len(kept) < size:
        taken = {entry.get('name') for entry in kept.values()}
        name = next(f'{NAME_PREFIX}{number}' for number in range(1, size + 1) if f'{NAME_PREFIX}{number}' not in taken)
        return Plan('create', None, name, kept, drop)
    return Plan('busy', None, None, kept, drop)


def retire(udid: str, reason: str, delete: bool, out=sys.stderr) -> None:
    """Drop a device from the pool; shut it down and delete it when delete (only devices the lane made)."""
    if delete:
        retire_now(udid)
    lane_sim.record_event(udid, f'left the desk pool: {reason}')
    print(f'[lane] desk pool: {udid} left the pool ({reason}){" and was deleted" if delete else ""}', file=out, flush=True)


def erase(udid: str) -> None:
    """Erase a shut-down device back to a new device's state. A failure doesn't retire it: it is approved."""
    try:
        done = subprocess.run(lane_sim.simctl() + ['erase', udid], capture_output=True, text=True,
                              timeout=ERASE_TIMEOUT)
    except subprocess.TimeoutExpired:
        raise BootError(f'simctl erase hung for {ERASE_TIMEOUT}s. {udid} was not booted and stays in the pool.') from None
    if done.returncode:
        detail = (done.stderr.strip().splitlines() or [f'exit {done.returncode}'])[-1]
        raise BootError(f'simctl erase failed: {detail}. {udid} was not booted and stays in the pool.')


def take(label: str, out=sys.stderr) -> str:
    """Pick the desk device for this run, make it clean and claim it. Raises BootError when it can't.

    Erases the least recently used free device, or creates one while the pool has room. Retires devices
    the lane marked unsafe. A device whose erase fails stays in the pool but goes to the back of the
    line, and the next free one is tried, so one stuck device can't stop every run. The caller boots
    the device as a first boot and calls unclaim() once it is up or if the boot fails.
    """
    with locked():
        entries = load()
        devices = listed_devices()
        unsafe = lane_sim.unsafe_devices()
        busy = busy_devices(entries, devices)
        plan = choose(entries, devices, unsafe, busy)
        for udid, reason, delete in plan.drop:
            retire(udid, reason, delete, out)
        pool, stuck, errors = plan.pool, set(), []
        while plan.action == 'reuse':
            try:
                erase(plan.udid)
                pool[plan.udid].pop('erase_failed', None)
                break
            except BootError as error:
                errors.append(str(error))
                pool[plan.udid]['erase_failed'] = now()
                stuck.add(plan.udid)
                plan = choose(pool, devices, unsafe, busy | stuck)
        save(pool)
        if plan.action == 'busy':
            raise BootError(' '.join(errors) or f'all {len(pool)} desk simulators are in use, so none was booted. '
                            'Finish a run with --done, or look at desk-simulator-pool.json in the lane state folder.')
        if plan.action == 'create':
            udid = lane_sim.create_temporary(plan.name)
            pool[udid] = {'name': plan.name, 'created': now()}
            print(f'[lane] desk pool: created {plan.name} ({udid}); the owner approves it once in the simulator panel',
                  file=out, flush=True)
        else:
            udid = plan.udid
            print(f'[lane] desk pool: erased {plan.name} ({udid}); its approval stays', file=out, flush=True)
        pool[udid].update(last_used=now(), claimed={'pid': os.getpid(), 'label': label, 'at': now()})
        save(pool)
        lane_sim.record_event(udid, f'taken from the desk pool as {pool[udid]["name"]} ({plan.action})')
        return udid


def unclaim(udid: str, pid: int | None = None) -> None:
    """Drop this process's claim on a device: once its boot has worked (the Booted state and the watcher keep it
    busy from then on), or after a boot that failed, so the next run retires or reuses it. Another run's claim stays."""
    pid = os.getpid() if pid is None else pid
    with locked():
        entries = load()
        if udid in entries and (entries[udid].get('claimed') or {}).get('pid') == pid:
            entries[udid].pop('claimed')
            save(entries)


def retire_after_flood(udid: str, reason: str) -> bool:
    """Mark a pool device unsafe after a crash flood (verify-tests.py, `lane-sim-boot --retire`), before it is shut
    down, so the next --pool deletes it instead of erasing and booting it. Other devices are left to their callers."""
    if not in_pool(udid):
        return False
    lane_sim.mark_unsafe(udid, reason)
    lane_sim.record_event(udid, f'marked unsafe: {reason}')
    return True


def simctl_quietly(command: str, udid: str) -> None:
    with contextlib.suppress(OSError, subprocess.SubprocessError):
        subprocess.run(lane_sim.simctl() + [command, udid], capture_output=True, timeout=120)


def shut_down(udid: str) -> None:
    """Shut a device down without the pool lock. `--retire` does this first: a crash flood must stop at once,
    and release() may wait for the lock behind another run's erase (up to ERASE_TIMEOUT)."""
    simctl_quietly('shutdown', udid)
    lane_audio.settle(drop=udid)


def retire_now(udid: str) -> None:
    shut_down(udid)
    simctl_quietly('delete', udid)


def release(udid: str, wait: float = lane_sim.RELEASE_WAIT, out=sys.stderr) -> str:
    """`lane-sim-boot --done` for a pool device. Returns 'kept', 'retired' or 'idle'.

    Stops the watcher and shuts the device down, then erases it and keeps it (the next run erases again,
    but a shut-down device shouldn't hold a run's app data). A device the lane marked unsafe, checked after
    the watcher has stopped because it can still mark one then, is deleted and dropped instead.
    A device nobody holds is left alone ('idle'): pool devices are reused, so a second --done on one
    would shut down whoever took it since.
    While it releases, this process holds the claim, so no other run can take the device half-erased.
    """
    with locked():
        entries = load()
        entry = entries.get(udid)
        if entry is None:
            return 'idle'
        try:
            idle = udid not in busy_devices({udid: entry}, listed_devices())
        except BootError:
            idle = False  # simctl can't say: release it the way a busy device is
        if idle and udid not in lane_sim.unsafe_devices():
            return 'idle'
        if not idle:
            entry['claimed'] = {'pid': os.getpid(), 'label': 'releasing', 'at': now()}
            save(entries)
    if not idle:
        lane_sim.release(udid, wait, keep=True)
    with locked():
        entries = load()
        entry = entries.get(udid)
        if udid in lane_sim.unsafe_devices():
            retire_now(udid)
            entries.pop(udid, None)
            save(entries)
            lane_sim.record_event(udid, 'left the desk pool: marked unsafe; deleted')
            return 'retired'
        try:
            erase(udid)
        except BootError as error:  # not fatal: take() erases before the next boot
            print(f'[lane] desk pool: {error}', file=out, flush=True)
        if entry is not None and (entry.get('claimed') or {}).get('pid') == os.getpid():
            entry.pop('claimed')
            save(entries)
        return 'kept'
