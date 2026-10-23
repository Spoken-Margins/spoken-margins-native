#!/usr/bin/env python3
"""Audio windows for unattended simulator tests (#1790): a test asks, this records and checks what played.

`verify-tests.py` starts `window.py serve --dir <folder>` next to an app test run that includes an
AudioLoopback test, and passes the folder to the test as SM_AUDIO_WINDOW. The test and this server talk
through files in that folder (the Simulator writes straight to the Mac's disk):

1. The server writes `ready.json` when it is listening.
2. The test writes `<id>.request.json`: how long to record, the text it expects, and the limits.
3. The server takes the Mac-wide audio lock (one window at a time, like the simulator slot), makes BlackHole
   the default output through `loopback route` (which always puts the old one back), starts recording, listens
   to a second of pre-roll, and plays a short pilot tone straight to BlackHole. When the recorder runs it
   writes `<id>.recording`.
   The recorder, and the transcriber, run as SpokenMarginsLaneRecorder.app, started through LaunchServices, so
   macOS charges Microphone and Speech Recognition to that app, which the owner allowed once, and not to the
   runner's node, which it refuses without asking (README, The recorder app).
4. The test plays its item. The Simulator's audio follows the Mac's default output, so it lands in BlackHole.
5. When the window ends the default output is restored and the lock released. The server cuts the pilot off,
   runs loopback.py's check on the rest, and writes `<id>.result.json`.

The verdict is PASS, FAIL (the audio broke an expectation: the app's fault) or UNAVAILABLE (the lane couldn't
listen: no BlackHole, the lock stayed busy, the recorder heard digital silence, so not even the pilot tone, or
the words couldn't be transcribed, or the recorder app isn't installed or allowed). A test skips on
UNAVAILABLE, which the lane reports as INCONCLUSIVE.

The lock keeps two windows apart, but not other sound: while BlackHole is the default output, a second
simulator job or the Mac's own player lands in the same recording. That would be a FAIL blamed on the app, so
the window answers UNAVAILABLE instead when another simulator job holds a lane slot at its start or end, or
when the pre-roll, before the pilot and before the test plays, already holds sound.
"""
import argparse
import contextlib
import datetime
import functools
import fcntl
import json
import math
import os
import signal
import subprocess
import sys
import threading
import time
from pathlib import Path

import loopback

LOCK_NAME = 'audio-window.lock'
LOCK_WAIT = 900          # a lane test waits this long for another window to finish (s)
READY = 'ready.json'
DEVICE = 'BlackHole 2ch'
PILOT_SECONDS = 0.3      # a 1 kHz tone, played straight to BlackHole, proves the recorder can hear
PILOT_GUARD = 0.4        # cut this much after the pilot's end, so its tail isn't counted as the app's
PREROLL_SECONDS = 1.0    # recorded before the pilot; sound here is not the app's, so the window can't judge it
SOUND_LEVEL = 0.01       # a sample above this (-40 dBFS) is sound; BlackHole with nothing playing is all zeros
START_TIMEOUT = 30       # the recorder must report that it runs within this (s)
MAX_SECONDS = 300
POLL = 0.2

LIMITS = ('max_stall', 'min_sound', 'max_wer')
FLAGS = ('allow_trailing', 'allow_repeats')


def lock_path():
    """Beside the lane's simulator and build slots (scripts/lane_slots.py), so every checkout shares it."""
    base = Path(os.environ.get('SM_LANE_STATE_DIR') or Path.home() / 'Library/Caches/SpokenMarginsLane')
    base.mkdir(parents=True, exist_ok=True)
    return base / LOCK_NAME


@contextlib.contextmanager
def audio_lock(owner, max_wait=LOCK_WAIT, poll=1.0, clock=time.monotonic, sleep=time.sleep):
    """The Mac-wide audio window: an flock, so a crash releases it. Raises TimeoutError after max_wait."""
    path = lock_path()
    handle = path.open('a+')
    deadline = clock() + max_wait
    try:
        while True:
            try:
                fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if clock() >= deadline:
                    handle.seek(0)
                    holder = handle.read().strip() or 'unknown holder'
                    raise TimeoutError(f'another audio window held {path} for {max_wait:.0f} s ({holder})')
                sleep(poll)
        handle.seek(0)
        handle.truncate()
        handle.write(json.dumps({'owner': owner, 'pid': os.getpid(),
                                 'since': datetime.datetime.now(datetime.timezone.utc).isoformat(timespec='seconds')}))
        handle.flush()
        yield
    finally:
        with contextlib.suppress(OSError):
            handle.seek(0)
            handle.truncate()
        handle.close()  # closing drops the flock


def write_json(path, value):
    """Write then rename, so the other side never reads half a file."""
    part = path.with_name(path.name + '.part')
    part.write_text(json.dumps(value, indent=2) + '\n')
    part.rename(path)


def pilot_tone(path, rate=16000):
    n = int(PILOT_SECONDS * rate)
    loopback.write_wav(path, rate, [0.5 * math.sin(2 * math.pi * 1000 * i / rate) * min(1, i / 160, (n - i) / 160)
                                    for i in range(n)])


def parse_request(raw):
    """(seconds, expected text or None, lock wait, check options) from a request, or ValueError."""
    seconds = raw.get('seconds')
    if not isinstance(seconds, (int, float)) or not 1 <= seconds <= MAX_SECONDS:
        raise ValueError(f'seconds must be between 1 and {MAX_SECONDS}, got {seconds!r}')
    expected = raw.get('expected')
    if expected is not None and (not isinstance(expected, str) or not expected.strip()):
        raise ValueError('expected must be non-empty text when given')
    options = {}
    for key in LIMITS:
        if raw.get(key) is not None:
            if not isinstance(raw[key], (int, float)):
                raise ValueError(f'{key} must be a number')
            options[key] = float(raw[key])
    for key in FLAGS:
        options[key] = bool(raw.get(key, False))
    lock_wait = raw.get('lock_wait', LOCK_WAIT)
    if not isinstance(lock_wait, (int, float)) or lock_wait < 0:
        raise ValueError('lock_wait must be a number of seconds')
    return float(seconds), expected, min(float(lock_wait), LOCK_WAIT), options


def recorder_command(binary, app, wav, seconds, device=DEVICE, python=sys.executable):
    """`loopback route --to BlackHole -- loopback.py app-run … -- record …`. route needs no permission, so it runs
    here; record runs as the recorder app. app-run waits for the app, passes its stderr through, and copies the
    recording and the app's own log (`<wav>.recorder.log`) back into the evidence folder."""
    wav = Path(wav)
    return [binary, 'route', '--to', device, '--', python, str(Path(loopback.__file__).resolve()), 'app-run',
            '--app', str(app), '--timeout', str(round(seconds * 2 + 20)),
            '--collect', f'recording.wav={wav}', '--collect', f'stderr={wav.with_suffix(".recorder.log")}',
            '--', 'record', '--device', device, '--seconds', str(seconds), '--out', '{job}/recording.wav']


class Recorder:
    """`loopback route --to BlackHole -- (the recorder app) record …`: route restores the old default output
    however record ends, and a route killed with -9 is undone by the next route or `loopback restore`."""

    def __init__(self, wav, seconds, app, device=DEVICE, binary=None):
        self.command = recorder_command(binary or loopback.tool(), app, wav, seconds, device)
        self.lines = []
        self.started = threading.Event()
        self.process = None

    def start(self):
        self.process = subprocess.Popen(self.command, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
        threading.Thread(target=self._read, daemon=True).start()
        return self

    def _read(self):
        for line in self.process.stderr:
            self.lines.append(line.rstrip())
            if line.startswith('loopback: recording '):
                self.started.set()
        # Ended without recording (the app wasn't allowed Microphone, say): let the caller read the exit status
        # now rather than wait out START_TIMEOUT.
        self.started.set()

    def wait(self, timeout):
        try:
            return self.process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            self.stop()
            return None

    def stop(self):
        """TERM first: route's handler stops record and restores the default output before exiting."""
        if self.process and self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait()


def play_pilot(path, device=DEVICE, binary=None):
    """Play the pilot tone to BlackHole itself; the default output is not involved."""
    subprocess.run([binary or loopback.tool(), 'play', '--device', device, str(path)],
                   capture_output=True, timeout=15)


def trim(wav, offset, out, preroll=0.0):
    """Writes the recording from `offset` seconds on to `out`. Returns (heard the pilot, heard sound in the
    pre-roll). The recording starts no later than the clock that timed the pre-roll, so its first `preroll`
    seconds always come before the pilot and before the test plays."""
    rate, samples = loopback.read_wav(wav)
    cut = int(offset * rate)
    head = samples[:cut]
    heard_pilot = bool(head) and max(abs(s) for s in head) > SOUND_LEVEL
    before = samples[:min(int(preroll * rate), cut)]
    heard_before = bool(before) and max(abs(s) for s in before) > SOUND_LEVEL
    loopback.write_wav(out, rate, samples[cut:])
    return heard_pilot, heard_before


def other_simulator_jobs():
    """How many lane simulator slots are held beyond the one this run's own job holds (scripts/lane_slots.py)."""
    scripts = Path(__file__).resolve().parents[2] / 'scripts'
    if str(scripts) not in sys.path:
        sys.path.insert(0, str(scripts))
    import lane_slots
    return max(0, lane_slots.simulator_jobs_running() - 1)


def another_job(count):
    return (f'another simulator job is running ({count} more lane simulator slot{"s" if count != 1 else ""} held), '
            'and its sound would land in the same recording')


def summary_line(result):
    """One line for the lane report."""
    if result['verdict'] == 'UNAVAILABLE':
        return f"UNAVAILABLE: {result['reason']}"
    report = result['report']
    gaps = sorted((g for g in report['stalls'] if g['where'] != 'leading'), key=lambda g: g['seconds'])
    parts = [f"{report['sound_seconds']} s of sound in {report['seconds']} s",
             f"peak {report['peak_dbfs']} dBFS, sound RMS {report['sound_rms_dbfs']} dBFS",
             f"longest gap {gaps[-1]['seconds']} s ({gaps[-1]['where']})" if gaps else 'no gap over ' + str(report['settings']['stall_seconds']) + ' s',
             f"{len(report['repeats'])} repeat{'s' if len(report['repeats']) != 1 else ''}"]
    if 'score' in report:
        s = report['score']
        parts.append(f"words: heard {s['heard_words']} of {s['reference_words']}, word error rate {s['wer']}")
    line = f"{result['verdict']}: " + '; '.join(parts)
    if report['problems']:
        line += '. Problems: ' + '; '.join(report['problems'][:5])
    return line


def unavailable(reason, **extra):
    return {'verdict': 'UNAVAILABLE', 'reason': reason, **extra}


def run_window(folder, request_id, raw, recorder_factory=Recorder, pilot=play_pilot, check=loopback.check_recording,
               lock=audio_lock, device_present=None, clock=time.monotonic, recorder_app=loopback.installed_app,
               sleep=time.sleep, other_jobs=other_simulator_jobs):
    """One window, start to verdict. Never raises for a bad request or a missing device: it answers instead."""
    folder = Path(folder)
    try:
        seconds, expected, lock_wait, options = parse_request(raw)
    except ValueError as error:
        return unavailable(f'bad request: {error}')
    present = device_present() if device_present else device_listed()
    if not present:
        return unavailable(f'{DEVICE} is not installed on this Mac (ops/audio-loopback/README.md, Installing)')
    app = recorder_app()
    if not app:
        return unavailable(f'the recorder app is not installed at {loopback.app_path()}: the owner runs '
                           'ops/audio-loopback/setup-recorder-app.sh once at the Mac (README, The recorder app)')
    result = listen(folder, request_id, seconds, expected, lock_wait, options, app, recorder_factory, pilot, check,
                    lock, clock, sleep, other_jobs)
    if result['verdict'] == 'UNAVAILABLE' and loopback.app_is_stale(app):
        result['reason'] += ('. The installed recorder app was built from an older loopback.swift: '
                             'rerun ops/audio-loopback/setup-recorder-app.sh')
    return result


def listen(folder, request_id, seconds, expected, lock_wait, options, app, recorder_factory, pilot, check, lock,
           clock, sleep, other_jobs):
    wav, app_wav, tone = (folder / f'{request_id}.wav', folder / f'{request_id}.app.wav', folder / 'pilot.wav')
    pilot_tone(tone)
    try:
        with lock(f'audio window {request_id} (pid {os.getpid()})', max_wait=lock_wait):
            busy = other_jobs()
            if busy:
                return unavailable(another_job(busy))
            # Pre-roll, pilot and the test's window, plus a margin for the request and the result to cross.
            recorder = recorder_factory(wav, seconds + PREROLL_SECONDS + PILOT_SECONDS + PILOT_GUARD + 1.0,
                                        app).start()
            try:
                if not recorder.started.wait(START_TIMEOUT):
                    recorder.stop()
                    return unavailable('the recorder did not start: ' + ' / '.join(recorder.lines[-3:]))
                began = clock()
                sleep(PREROLL_SECONDS)
                pilot(tone)
                offset = clock() - began + PILOT_GUARD
                write_json(folder / f'{request_id}.recording', {'pilot_seconds': round(offset, 3)})
                status = recorder.wait(timeout=(seconds + 5) * 2 + 30)
            finally:
                recorder.stop()
            if status is None:
                return unavailable('the recorder ran past its window and was stopped')
            if status:
                return unavailable(f'the recorder exited {status}: ' + ' / '.join(recorder.lines[-3:]))
            # A job that took a slot during the window still holds it now (a job lasts minutes, a window seconds).
            joined = other_jobs()
    except TimeoutError as error:
        return unavailable(str(error))
    if not wav.exists():
        return unavailable('the recorder app reported success but wrote no recording')
    heard_pilot, heard_before = trim(wav, offset, app_wav, PREROLL_SECONDS)
    if not heard_pilot:
        return unavailable('the recorder heard digital silence, not even the pilot tone played straight to '
                           f'{DEVICE}: the recorder app may lack Microphone access (README, The recorder app)',
                           wav=str(wav))
    if heard_before:
        return unavailable(f'something else was already playing to {DEVICE} in the {PREROLL_SECONDS:g} s before '
                           'the pilot tone, so the recording is not only the app\'s', wav=str(wav))
    if joined:
        return unavailable(another_job(joined), wav=str(wav))
    # The words are transcribed by the recorder app too: it holds the Speech Recognition permission.
    report = check(app_wav, expected, run=functools.partial(loopback.transcribe_file, app=app), **options)
    result = {'verdict': report['verdict'], 'report': report, 'wav': str(app_wav)}
    if report['problems'] and all(p.startswith('could not check the words') for p in report['problems']):
        result = unavailable(report['problems'][0], report=report, wav=str(app_wav))
    return result


def device_listed():
    try:
        listing = subprocess.run([loopback.tool(), 'devices', '--json'], capture_output=True, text=True, timeout=30)
        return DEVICE in listing.stdout
    except (OSError, subprocess.SubprocessError):
        return False


def serve(folder, parent_pid=None, poll=POLL, handle=run_window, alive=None):
    """Answer requests in `folder` until the parent exits or TERM arrives."""
    folder = Path(folder)
    folder.mkdir(parents=True, exist_ok=True)
    alive = alive or (lambda: parent_pid is None or _running(parent_pid))
    write_json(folder / READY, {'pid': os.getpid(), 'device': DEVICE})
    answered = set()
    try:
        while alive():
            for request in sorted(folder.glob('*.request.json')):
                request_id = request.name[:-len('.request.json')]
                if request_id in answered:
                    continue
                answered.add(request_id)
                try:
                    raw = json.loads(request.read_text())
                except (OSError, ValueError) as error:
                    result = unavailable(f'unreadable request: {error}')
                else:
                    result = handle(folder, request_id, raw)
                    result['test'] = raw.get('test')
                result['summary'] = summary_line(result)
                write_json(folder / f'{request_id}.result.json', result)
                print(f'audio window {request_id}: {result["summary"]}', flush=True)
            time.sleep(poll)
    finally:
        with contextlib.suppress(OSError):
            (folder / READY).unlink()


def _running(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except OSError:
        return True
    return True


def results(folder):
    """The answered windows in `folder`, oldest first."""
    found = []
    for path in sorted(Path(folder).glob('*.result.json'), key=lambda p: p.stat().st_mtime):
        with contextlib.suppress(OSError, ValueError):
            found.append({**json.loads(path.read_text()), 'file': str(path)})
    return found


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    sub = parser.add_subparsers(dest='command', required=True)
    s = sub.add_parser('serve', help='answer audio window requests in a folder')
    s.add_argument('--dir', required=True)
    s.add_argument('--parent-pid', type=int, help='stop when this process exits')
    args = parser.parse_args(argv)

    def stop(signum, _frame):
        raise SystemExit(128 + signum)  # unwinds through Recorder.stop, so route restores the output

    for signum in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT):
        signal.signal(signum, stop)
    serve(args.dir, args.parent_pid)
    return 0


if __name__ == '__main__':
    sys.exit(main())
