"""Mac-wide lane locks, shared by every checkout, stream session, the Test Desk and the runner.

This Mac has 16 GB. A simulator job next to two builds pushed the load average to about 690 and
filled swap (2026-09-29, #184), so:
- Simulator slots: one simulator job at a time (the runner's T3 or the Test Desk's T4), held for
  the whole job, not just the boot; a second job may join only while memory pressure is normal and
  the second slot hasn't been switched off (after the owner freed memory, 2026-09-29, #184). An
  automatic switch-off expires after a cooldown once pressure is normal again; one made by hand
  stays until someone switches it on (the 2026-09-29 trip stayed three weeks, #2157).
- Build slots: at most two xcodebuild runs at once, and only one while a simulator job runs.
- Host-test slots: at most two heavy host test runs at once (a --plan fast run, a full `swift test`
  through scripts/host-test-lane), and only one while a simulator job runs. Ungated, five sessions'
  runs pushed the load to 150-420 and timing tests flaked (#350). They are separate from the build
  slots, so a simulator test run holding the one build slot doesn't stall every merge check. A
  host-slot holder never takes a build slot, so the two can't deadlock, and the slot passes to
  the holder's children (SM_LANE_HOST_SLOT), so a run's own `swift test` doesn't queue again.
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
import re
import sys
import time

SLOTS = 2
HOST_SLOTS = 2
HOST_SLOT_ENV = 'SM_LANE_HOST_SLOT'
POLL_SECONDS = 2.0
NOTE_EVERY_SECONDS = 60.0
SIMULATOR_SLOT = 'simulator-slot.lock'
SIMULATOR_SLOTS = [SIMULATOR_SLOT, 'simulator-slot-2.lock']
SECOND_SLOT_OFF = 'second-simulator-slot.off'
SECOND_SLOT_TRIPS = 'second-simulator-slot.trips'
# An automatic switch-off lasts 4 h, doubling for each earlier trip in the past week, at most 24 h.
SECOND_SLOT_COOLDOWN = 4 * 3600
SECOND_SLOT_COOLDOWN_MAX = 24 * 3600
SECOND_SLOT_TRIP_WINDOW = 7 * 24 * 3600
SIMULATOR_DECISION = 'simulator-slot-decision.lock'
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


def _pid_running(pid):
    """False only when no process has this pid; unreadable or foreign pids count as running."""
    if not isinstance(pid, int) or pid <= 0:
        return True
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except OSError:  # PermissionError: another user's process
        return True
    return True


def _read_holders(names, directory=None):
    """The holder notes of the named locks that are really held, each with 'gone' set when its pid has exited.

    The flock is the truth; a note is only what the last taker wrote. A holder that dies without
    clearing its note (the simulator watcher that inherited lane-sim-boot's slot, #395) leaves a
    note on a free lock, so notes on free locks are skipped. A held lock whose recorded pid has
    exited was handed to a child (lane-sim-boot gives its slot to the watcher), so it is kept and
    marked gone.
    """
    found = []
    for name in names:
        path = Path(directory or state_dir()) / name
        try:
            holder = json.loads(path.read_text())
        except (OSError, ValueError):
            continue
        if not isinstance(holder, dict) or not _lock_held(path):
            continue
        found.append({**holder, 'gone': not _pid_running(holder.get('pid'))})
    return found


def holders(directory=None):
    """Who holds each build slot right now, as recorded by the holder (best effort, for messages only)."""
    return _read_holders(build_slot_names(), directory)


def host_holders(directory=None):
    """Who holds each host-test slot right now (best effort, for records only)."""
    return _read_holders(host_slot_names(), directory)


def simulator_holders(directory=None):
    """Who holds each simulator slot right now (best effort, for records only)."""
    return _read_holders(SIMULATOR_SLOTS, directory)


def _describe(holder):
    pid = f"pid {holder.get('pid')}" + (' (gone; a child still holds its lock)' if holder.get('gone') else '')
    return f"{pid} in {holder.get('cwd')} ({holder.get('label')}, since {holder.get('started')})"


def _held(name):
    return _lock_held(state_dir() / name)


def _lock_held(path):
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


def _read_second_slot_off(path):
    """The switch-off record: {'since', 'until', 'reason'}; until is None when it was switched off by hand.

    Files written before #2157 hold one line, "<time>: <reason>". Only an automatic trip expires: it counts as
    tripped at the file's modification time with the base cooldown. The old `--second-slot off` wrote the same
    shape with a reason ending "(switched off by hand)", and that one, or any file not in the old writer's shape,
    stays off until switched on, as it always did.
    """
    text = path.read_text()
    try:
        record = json.loads(text)
        if isinstance(record, dict) and 'since' in record:
            return record
    except ValueError:
        pass
    since = path.stat().st_mtime
    reason = text.strip()
    automatic = _LEGACY_LINE.match(reason) and not reason.endswith(_LEGACY_BY_HAND)
    return {'since': since, 'until': since + SECOND_SLOT_COOLDOWN if automatic else None, 'reason': reason}


_LEGACY_LINE = re.compile(r'\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d: ')  # the pre-#2157 writer's "<time>: "
_LEGACY_BY_HAND = '(switched off by hand)'


def _clock(when):
    return datetime.datetime.fromtimestamp(when).strftime('%Y-%m-%d %H:%M')


def second_slot_status(now=None):
    """(allowed, why): may a second simulator job start now?

    An expired automatic switch-off is removed here, once memory pressure is normal: the brake trips
    again (with a longer cooldown) if two simulators still push pressure up.
    """
    now = time.time() if now is None else now
    off = state_dir() / SECOND_SLOT_OFF
    level = memory_pressure_level()
    try:
        record = _read_second_slot_off(off)
    except OSError:
        record = None
    if record is not None:
        until = record.get('until')
        if until is None:
            return False, f"the second slot is switched off by hand ({record.get('reason')}); it stays off until switched on"
        if now < until:
            return False, f"the second slot is switched off ({record.get('reason')}); it comes back on after {_clock(until)}"
        if level not in (1, None):
            return False, (f"the second slot is switched off ({record.get('reason')}); its cooldown is over, and it "
                           f"comes back on once memory pressure is normal (now {PRESSURE_NAMES.get(level, level)})")
        off.unlink(missing_ok=True)
        return True, 'memory pressure is normal (the second slot came back on after its cooldown)'
    if level not in (1, None):
        return False, f'memory pressure is {PRESSURE_NAMES.get(level, level)}, and a second simulator needs normal'
    return True, 'memory pressure is normal'


def _record_trip(now):
    """Add this trip to the past week's trips; returns how many trips that makes (this one included)."""
    path = state_dir() / SECOND_SLOT_TRIPS
    try:
        trips = [t for t in json.loads(path.read_text()) if isinstance(t, (int, float))]
    except (OSError, ValueError, TypeError):
        trips = []
    trips = [t for t in trips if now - t < SECOND_SLOT_TRIP_WINDOW] + [now]
    path.write_text(json.dumps(trips))
    return len(trips)


def second_slot_cooldown(trips):
    """How long an automatic switch-off lasts, given this week's trip count (this one included)."""
    return min(SECOND_SLOT_COOLDOWN * 2 ** max(trips - 1, 0), SECOND_SLOT_COOLDOWN_MAX)


def disable_second_slot(reason, by_hand=False, now=None):
    """Switch the second slot off (back to one simulator). Returns True if this call switched it off.

    An automatic switch-off expires (second_slot_status); one made by hand stays until enable_second_slot,
    and replaces an automatic one that is still running so its end time no longer applies.
    """
    now = time.time() if now is None else now
    state_dir().mkdir(parents=True, exist_ok=True)
    path = state_dir() / SECOND_SLOT_OFF
    if path.exists():
        if not by_hand:
            return False
        try:
            if _read_second_slot_off(path).get('until') is None:
                return False
        except OSError:
            pass  # switched on meanwhile: write the hand switch-off below
        else:
            spare = path.with_name(f'{SECOND_SLOT_OFF}.{os.getpid()}.tmp')
            spare.write_text(json.dumps({'since': now, 'until': None, 'reason': reason}) + '\n')
            os.replace(spare, path)
            return True
    until = None if by_hand else now + second_slot_cooldown(_record_trip(now))
    try:
        with open(path, 'x') as handle:
            handle.write(json.dumps({'since': now, 'until': until, 'reason': reason}) + '\n')
        return True
    except FileExistsError:
        return False


def second_slot_back_on_at():
    """When an automatic switch-off ends (epoch seconds), or None when the slot is on or was switched off by hand."""
    try:
        return _read_second_slot_off(state_dir() / SECOND_SLOT_OFF).get('until')
    except OSError:
        return None


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
        timed_out = max_wait is not None and now - started >= max_wait
        if timed_out or last_note is None or now - last_note >= NOTE_EVERY_SECONDS:
            # Only when saying it: reading the holders probes each lock, which shouldn't happen every poll.
            busy = '; '.join(_describe(h) for h in _read_holders(names, directory)) or 'nothing holds them'
            if len(usable) < len(names):
                busy += f' ({why() if why else f"only {len(usable)} of {len(names)} while a simulator job runs"})'
            if timed_out:
                raise TimeoutError(f'no {what} free within {max_wait:.0f}s: {busy}')
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


def host_slot_names():
    return [f'host-test-slot-{index}.lock' for index in range(HOST_SLOTS)]


@contextlib.contextmanager
def host_test_slot(label, out=sys.stderr, max_wait=None):
    """Hold a host-test slot for the with-block: one of two, or the first only while a simulator job runs.

    Inside a process that already holds one (SM_LANE_HOST_SLOT is set), it yields at once.
    Yields {'slot': index or None, 'waited_seconds': seconds}.
    """
    if os.environ.get(HOST_SLOT_ENV):
        yield {'slot': None, 'waited_seconds': 0, 'held_by': os.environ[HOST_SLOT_ENV]}
        return
    handle, index, waited = acquire(host_slot_names(), 'host-test slot', label, out, max_wait,
                                    allowed=lambda: 1 if simulator_job_running() else HOST_SLOTS)
    os.environ[HOST_SLOT_ENV] = label
    try:
        yield {'slot': index, 'waited_seconds': waited}
    finally:
        os.environ.pop(HOST_SLOT_ENV, None)
        release_handle(handle)


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
            lambda: second_slot_status()[1], SIMULATOR_DECISION)


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
