"""Mac-wide lane locks, shared by every checkout, stream session, the Test Desk and the runner.

- Build slots: at most two xcodebuild runs at once.
- Simulator boot: one simulator boots at a time. Two boots at once crash-flooded SpringBoard onto
  the owner's screen (2026-09-28, #184).

Each lock is an flock on a file in one per-user directory. The kernel releases a lock when its
holder exits, however it exits, so a crash never leaves one stuck.
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


def state_dir():
    return Path(os.environ.get('SM_LANE_STATE_DIR') or Path.home() / 'Library/Caches/SpokenMarginsLane')


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
    return _read_holders([f'xcodebuild-slot-{index}.lock' for index in range(SLOTS)], directory)


def _describe(holder):
    return f"pid {holder.get('pid')} in {holder.get('cwd')} ({holder.get('label')}, since {holder.get('started')})"


@contextlib.contextmanager
def _hold(names, what, label, out, max_wait):
    """Wait for any one of the named lock files, hold it for the with-block, then release it."""
    directory = state_dir()
    directory.mkdir(parents=True, exist_ok=True)
    started = time.monotonic()
    last_note = None
    while True:
        for index, name in enumerate(names):
            handle = open(directory / name, 'a+')
            try:
                fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                handle.close()
                continue
            try:
                handle.seek(0)
                handle.truncate()
                handle.write(json.dumps({'pid': os.getpid(), 'cwd': os.getcwd(), 'label': label,
                                         'started': datetime.datetime.now().isoformat(timespec='seconds')}))
                handle.flush()
                waited = round(time.monotonic() - started, 1)
                slot = f' {index + 1}/{len(names)}' if len(names) > 1 else ''
                print(f'[lane] {what}{slot} acquired after {waited:.0f}s: {label}', file=out, flush=True)
                yield {'slot': index, 'waited_seconds': waited}
            finally:
                handle.seek(0)
                handle.truncate()
                handle.close()
            return
        now = time.monotonic()
        busy = '; '.join(_describe(h) for h in _read_holders(names, directory)) or 'holders unknown'
        if max_wait is not None and now - started >= max_wait:
            raise TimeoutError(f'no {what} free within {max_wait:.0f}s: {busy}')
        if last_note is None or now - last_note >= NOTE_EVERY_SECONDS:
            print(f'[lane] waiting for a {what}, {len(names)}/{len(names)} busy ({now - started:.0f}s so far): {busy}',
                  file=out, flush=True)
            last_note = now
        time.sleep(POLL_SECONDS)


def build_slot(label, out=sys.stderr, max_wait=None):
    """Hold one of the two build slots for the with-block.

    Yields {'slot': index, 'waited_seconds': seconds}. By default waiting has no deadline, because
    queueing is the point; with max_wait (seconds) it raises TimeoutError instead of waiting longer.
    """
    return _hold([f'xcodebuild-slot-{index}.lock' for index in range(SLOTS)], 'build slot', label, out, max_wait)


def simulator_boot_lock(label, out=sys.stderr, max_wait=None):
    """Hold the one simulator-boot lock for the with-block: from `simctl boot` until the device is ready."""
    return _hold(['simulator-boot.lock'], 'simulator boot lock', label, out, max_wait)
