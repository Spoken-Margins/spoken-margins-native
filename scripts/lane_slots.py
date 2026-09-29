"""Mac-wide lane locks, shared by every checkout, stream session, the Test Desk and the runner.

This Mac has 16 GB. A simulator job next to two builds pushed the load average to about 690 and
filled swap (2026-09-29, #184), so:
- Simulator slots: one simulator job at a time (the runner's T3 or the Test Desk's T4), held for
  the whole job, not just the boot; a second job may join only while memory pressure is normal and
  the second slot hasn't been switched off (after the owner freed memory, 2026-09-29, #184).
- Build slots: at most two xcodebuild runs at once, and only one while a simulator job runs.
- Simulator boot: one simulator boots at a time (two boots at once crash-flooded SpringBoard, #184).

Each lock is an flock on a file in one per-user directory. The kernel releases a lock when its
last holder exits, however it exits, so a crash never leaves one stuck. A lock can be handed to a
child process (lane-sim-boot gives the simulator slot to the device's watcher).
"""
import contextlib
import datetime
import fcntl
import json
import os
from pathlib import Path
import sys
import time

SLOTS = 2
POLL_SECONDS = 2.0
NOTE_EVERY_SECONDS = 60.0
SIMULATOR_SLOT = 'simulator-slot.lock'
SIMULATOR_SLOTS = [SIMULATOR_SLOT, 'simulator-slot-2.lock']
SECOND_SLOT_OFF = 'second-simulator-slot.off'
PRESSURE_NAMES = {1: 'normal', 2: 'warn', 4: 'critical'}


def memory_pressure_level():
    """The kernel's memory pressure level: 1 normal, 2 warn, 4 critical (None if unreadable)."""
    if os.environ.get('SM_LANE_MEMORY_PRESSURE'):  # tests
        return int(os.environ['SM_LANE_MEMORY_PRESSURE'])
    try:
        import subprocess
        return int(subprocess.check_output(['sysctl', '-n', 'kern.memorystatus_vm_pressure_level'], text=True))
    except (OSError, ValueError, subprocess.CalledProcessError):
        return None


def state_dir():
    return Path(os.environ.get('SM_LANE_STATE_DIR') or Path.home() / 'Library/Caches/SpokenMarginsLane')


def build_slot_names():
    return [f'xcodebuild-slot-{index}.lock' for index in range(SLOTS)]


def _read_holders(names, directory=None):
    found = []
    for name in names:
        try:
            found.append(json.loads((Path(directory or state_dir()) / name).read_text()))
        except (OSError, ValueError):
            continue
    return found


def holders(directory=None):
    """Who holds each build slot right now, as recorded by the holder (best effort, for messages only)."""
    return _read_holders(build_slot_names(), directory)


def _describe(holder):
    return f"pid {holder.get('pid')} in {holder.get('cwd')} ({holder.get('label')}, since {holder.get('started')})"


def _held(name):
    path = state_dir() / name
    if not path.exists():
        return False
    with open(path, 'a+') as handle:
        try:
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return True
        fcntl.flock(handle, fcntl.LOCK_UN)
    return False


def simulator_jobs_running():
    """How many simulator slots some process (possibly this one) holds: 0, 1 or 2."""
    return sum(_held(name) for name in SIMULATOR_SLOTS)


def simulator_job_running():
    """Whether some process (possibly this one) holds a simulator slot."""
    return simulator_jobs_running() > 0


def second_slot_status():
    """(allowed, why): may a second simulator job start now?"""
    off = state_dir() / SECOND_SLOT_OFF
    if off.exists():
        return False, f'the second slot is switched off ({off.read_text().strip()})'
    level = memory_pressure_level()
    if level not in (1, None):
        return False, f'memory pressure is {PRESSURE_NAMES.get(level, level)}, and a second simulator needs normal'
    return True, 'memory pressure is normal'


def disable_second_slot(reason):
    """Switch the second slot off (back to one simulator). Returns True if this call switched it off."""
    state_dir().mkdir(parents=True, exist_ok=True)
    try:
        with open(state_dir() / SECOND_SLOT_OFF, 'x') as handle:
            handle.write(f'{datetime.datetime.now().isoformat(timespec="seconds")}: {reason}\n')
        return True
    except FileExistsError:
        return False


def enable_second_slot():
    (state_dir() / SECOND_SLOT_OFF).unlink(missing_ok=True)


def acquire(names, what, label, out=sys.stderr, max_wait=None, allowed=None, why=None, decide=None):
    """Wait for one of the named lock files and return (open handle, index, seconds waited).

    The lock lasts as long as the handle stays open, here or in a child that inherited it.
    allowed(), if given, returns how many of the names may be used right now; why() says why not all.
    decide, if given, is a lock file held while allowed() is checked and a slot taken, so two
    processes can't both act on the same check.
    """
    directory = state_dir()
    directory.mkdir(parents=True, exist_ok=True)
    started = time.monotonic()
    last_note = None
    while True:
        decision = None
        if decide:
            decision = open(directory / decide, 'a+')
            fcntl.flock(decision, fcntl.LOCK_EX)
        usable = names[:allowed()] if allowed else names
        taken = None
        for index, name in enumerate(usable):
            handle = open(directory / name, 'a+')
            try:
                fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                handle.close()
                continue
            handle.seek(0)
            handle.truncate()
            handle.write(json.dumps({'pid': os.getpid(), 'cwd': os.getcwd(), 'label': label,
                                     'started': datetime.datetime.now().isoformat(timespec='seconds')}))
            handle.flush()
            taken = (handle, index)
            break
        if decision:
            decision.close()
        if taken:
            handle, index = taken
            waited = round(time.monotonic() - started, 1)
            slot = f' {index + 1}/{len(names)}' if len(names) > 1 else ''
            print(f'[lane] {what}{slot} acquired after {waited:.0f}s: {label}', file=out, flush=True)
            return handle, index, waited
        now = time.monotonic()
        busy = '; '.join(_describe(h) for h in _read_holders(names, directory)) or 'nothing holds them'
        if len(usable) < len(names):
            busy += f' ({why() if why else f"only {len(usable)} of {len(names)} while a simulator job runs"})'
        if max_wait is not None and now - started >= max_wait:
            raise TimeoutError(f'no {what} free within {max_wait:.0f}s: {busy}')
        if last_note is None or now - last_note >= NOTE_EVERY_SECONDS:
            print(f'[lane] waiting for a {what} ({now - started:.0f}s so far): {busy}', file=out, flush=True)
            last_note = now
        time.sleep(POLL_SECONDS)


def release_handle(handle):
    """Clear the holder note and close; the lock ends once no other process holds the handle."""
    try:
        handle.seek(0)
        handle.truncate()
    finally:
        handle.close()


@contextlib.contextmanager
def _hold(names, what, label, out, max_wait, allowed=None):
    handle, index, waited = acquire(names, what, label, out, max_wait, allowed)
    try:
        yield {'slot': index, 'waited_seconds': waited}
    finally:
        release_handle(handle)


def build_slot(label, out=sys.stderr, max_wait=None):
    """Hold a build slot for the with-block: one of two, or the first only while a simulator job runs.

    Yields {'slot': index, 'waited_seconds': seconds}. By default waiting has no deadline, because
    queueing is the point; with max_wait (seconds) it raises TimeoutError instead of waiting longer.
    """
    return _hold(build_slot_names(), 'build slot', label, out, max_wait,
                 allowed=lambda: 1 if simulator_job_running() else SLOTS)


def build_slot_file(index, label, out=sys.stderr, max_wait=None):
    """Hold one specific build slot (used to hold both while a simulator boots)."""
    return _hold([build_slot_names()[index]], f'build slot {index + 1}', label, out, max_wait)


def simulator_boot_lock(label, out=sys.stderr, max_wait=None):
    """Hold the one simulator-boot lock for the with-block: from `simctl boot` until the device is ready."""
    return _hold(['simulator-boot.lock'], 'simulator boot lock', label, out, max_wait)


def _simulator_slots_usable():
    """Any free slot when no simulator job runs; joining a running one needs second_slot_status()."""
    if simulator_jobs_running() == 0 or second_slot_status()[0]:
        return len(SIMULATOR_SLOTS)
    return 0


def _simulator_slot_args(label, out, max_wait):
    return (SIMULATOR_SLOTS, 'simulator slot', label, out, max_wait, _simulator_slots_usable,
            lambda: second_slot_status()[1], 'simulator-slot-decision.lock')


@contextlib.contextmanager
def simulator_slot(label, out=sys.stderr, max_wait=None):
    """Hold a simulator slot for a whole simulator job (the with-block)."""
    handle, index, waited = acquire(*_simulator_slot_args(label, out, max_wait))
    try:
        yield {'slot': index, 'waited_seconds': waited}
    finally:
        release_handle(handle)


def acquire_simulator_slot(label, out=sys.stderr, max_wait=None):
    """Take a simulator slot and return its open handle, to hand to a longer-lived child process."""
    return acquire(*_simulator_slot_args(label, out, max_wait))[0]
