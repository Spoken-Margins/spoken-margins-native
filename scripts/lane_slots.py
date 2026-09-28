"""Mac-wide build slots: at most two xcodebuild runs at once, across every checkout and session.

Each slot is an flock on a file in one per-user directory, so every worktree, stream session and
the lane share the same two slots. The kernel releases a lock when its holder exits, however it
exits, so a crashed build never leaves a slot stuck.
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


def holders(directory=None):
    """Who holds each slot right now, as recorded by the holder (best effort, for messages only)."""
    found = []
    for index in range(SLOTS):
        try:
            text = (Path(directory or state_dir()) / f'xcodebuild-slot-{index}.lock').read_text()
            found.append(json.loads(text))
        except (OSError, ValueError):
            continue
    return found


def _describe(holder):
    return f"pid {holder.get('pid')} in {holder.get('cwd')} ({holder.get('label')}, since {holder.get('started')})"


@contextlib.contextmanager
def build_slot(label, out=sys.stderr, max_wait=None):
    """Wait for a free slot, hold it for the body of the with-block, then release it.

    Yields {'slot': index, 'waited_seconds': seconds}. By default waiting has no deadline, because
    queueing is the point; with max_wait (seconds) it raises TimeoutError instead of waiting longer.
    """
    directory = state_dir()
    directory.mkdir(parents=True, exist_ok=True)
    started = time.monotonic()
    last_note = None
    while True:
        for index in range(SLOTS):
            handle = open(directory / f'xcodebuild-slot-{index}.lock', 'a+')
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
                print(f'[lane] build slot {index + 1}/{SLOTS} acquired after {waited:.0f}s: {label}',
                      file=out, flush=True)
                yield {'slot': index, 'waited_seconds': waited}
            finally:
                handle.seek(0)
                handle.truncate()
                handle.close()
            return
        now = time.monotonic()
        if max_wait is not None and now - started >= max_wait:
            busy = '; '.join(_describe(h) for h in holders(directory)) or 'holders unknown'
            raise TimeoutError(f'no build slot free within {max_wait:.0f}s: {busy}')
        if last_note is None or now - last_note >= NOTE_EVERY_SECONDS:
            busy = '; '.join(_describe(h) for h in holders(directory)) or 'holders unknown'
            print(f'[lane] waiting for a build slot, {SLOTS}/{SLOTS} busy ({now - started:.0f}s so far): {busy}',
                  file=out, flush=True)
            last_note = now
        time.sleep(POLL_SECONDS)
