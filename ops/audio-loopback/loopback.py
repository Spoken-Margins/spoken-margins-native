#!/usr/bin/env python3
"""Hear what the app played: analyse a loopback recording, and score its transcript (#1790).

The macOS side (`loopback` built from loopback.swift) routes output to BlackHole and records it. This file
reads that wav and answers the questions an audible bug asks:

- Did anything play, and for how long? (sound segments, total sound time, peak and RMS)
- Did it stop? (gaps longer than --stall seconds, and trailing silence: #1763 stops seconds after locking)
- Did it say something twice? (repeated audio: #1762 repeats the first words of each chunk)
- Did it say the right words? (on-device transcript against expected text: word error rate, repeated words)

Standard library only, so the analysis is host-tested in the fast plan and runs on any CI machine.
"""
import argparse
import array
import contextlib
import json
import math
import os
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import unicodedata
import wave
from pathlib import Path

HERE = Path(__file__).resolve().parent
ANALYSIS_RATE = 16000
HOP = 0.010          # one envelope frame per 10 ms
WINDOW = 0.030       # each frame measures 30 ms, so the envelope is smooth enough to compare
FLOOR_DB = -100.0


# --- Reading ----------------------------------------------------------------------------------------------

def read_wav(path):
    """(rate, mono samples in -1..1). 8, 16, 24 and 32-bit integer PCM; channels are averaged."""
    with wave.open(str(path), 'rb') as w:
        channels, width, rate, count = w.getnchannels(), w.getsampwidth(), w.getframerate(), w.getnframes()
        raw = w.readframes(count)
    if width == 1:
        values = [b - 128 for b in raw]
        scale = 128.0
    elif width == 2:
        values = array.array('h', raw)
        scale = 32768.0
    elif width == 3:
        values = [int.from_bytes(raw[i:i + 3], 'little', signed=True) for i in range(0, len(raw), 3)]
        scale = 8388608.0
    elif width == 4:
        values = array.array('i', raw)
        scale = 2147483648.0
    else:
        raise ValueError(f'{path}: {width * 8}-bit samples are not supported')
    if sys.byteorder == 'big' and isinstance(values, array.array):
        values.byteswap()
    if channels == 1:
        mono = [v / scale for v in values]
    else:
        mono = [sum(values[i:i + channels]) / (channels * scale) for i in range(0, len(values), channels)]
    return rate, mono


def downsample(rate, samples, target=ANALYSIS_RATE):
    """Average whole blocks down to about `target` Hz. Speech analysis needs nothing finer."""
    step = max(1, rate // target)
    if step == 1:
        return rate, samples
    return rate / step, [sum(samples[i:i + step]) / step for i in range(0, len(samples) - step + 1, step)]


def write_wav(path, rate, samples):
    """16-bit mono; the tests make their fixtures with it."""
    data = array.array('h', (max(-32768, min(32767, int(round(s * 32767)))) for s in samples))
    if sys.byteorder == 'big':
        data.byteswap()
    with wave.open(str(path), 'wb') as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(int(rate))
        w.writeframes(data.tobytes())


# --- Envelope and segments --------------------------------------------------------------------------------

def db(power):
    return 10 * math.log10(power) if power > 1e-10 else FLOOR_DB


def envelope(rate, samples):
    """Loudness in dBFS every 10 ms, each over a 30 ms window."""
    hop, window = int(rate * HOP), int(rate * WINDOW)
    squares = [s * s for s in samples]
    # Prefix sums make every window O(1).
    prefix = [0.0]
    for value in squares:
        prefix.append(prefix[-1] + value)
    frames = []
    for start in range(0, max(1, len(samples) - hop + 1), hop):
        end = min(len(samples), start + window)
        frames.append(db((prefix[end] - prefix[start]) / max(1, end - start)))
    return frames


def segments(env, silence_db, min_gap, min_sound):
    """[(start_frame, end_frame)] of sound, joining pauses shorter than min_gap and dropping blips."""
    found, start = [], None
    for index, level in enumerate(env):
        if level > silence_db and start is None:
            start = index
        elif level <= silence_db and start is not None:
            found.append([start, index])
            start = None
    if start is not None:
        found.append([start, len(env)])
    joined = []
    for seg in found:
        if joined and (seg[0] - joined[-1][1]) * HOP < min_gap:
            joined[-1][1] = seg[1]
        else:
            joined.append(seg)
    return [(a, b) for a, b in joined if (b - a) * HOP >= min_sound]


# --- Repeated audio ---------------------------------------------------------------------------------------

def peaks(env, floor_db, radius=4):
    """Frames that are the loudest within ±40 ms and well above the silence line: syllable nuclei."""
    found = []
    for t in range(radius, len(env) - radius):
        level = env[t]
        if level > floor_db and level == max(env[t - radius:t + radius + 1]) and level > env[t - 1]:
            found.append(t)
    return found


def similarity(env, a, b, length):
    """(correlation, mean absolute dB difference) of env[a:a+length] against env[b:b+length]."""
    x, y = env[a:a + length], env[b:b + length]
    n = min(len(x), len(y))
    if n < 10:
        return 0.0, 99.0
    x, y = x[:n], y[:n]
    mx, my = sum(x) / n, sum(y) / n
    sxy = sum((p - mx) * (q - my) for p, q in zip(x, y))
    sxx = sum((p - mx) ** 2 for p in x)
    syy = sum((q - my) ** 2 for q in y)
    corr = sxy / math.sqrt(sxx * syy) if sxx > 0 and syy > 0 else 0.0
    return corr, sum(abs(p - q) for p, q in zip(x, y)) / n


def matched_stretch(env, start, end, lag, silence_db, max_diff_db, smooth=10):
    """(a, b): the longest frames a..b in start..end where env[t] tracks env[t - lag] within max_diff_db,
    averaged over `smooth` frames. Frames silent in both count as matching. None when nothing matches."""
    if start - lag < 0:
        return None
    diffs = []
    for t in range(start, end):
        here, there = env[t], env[t - lag]
        diffs.append(0.0 if here <= silence_db and there <= silence_db else abs(max(here, silence_db) - max(there, silence_db)))
    best, run_start = None, None
    for i in range(len(diffs) + 1):
        window = diffs[max(0, i - smooth // 2):i + smooth // 2 + 1] if i < len(diffs) else None
        ok = window is not None and sum(window) / len(window) <= max_diff_db
        if ok and run_start is None:
            run_start = i
        elif not ok and run_start is not None:
            if best is None or i - run_start > best[1] - best[0]:
                best = (run_start, i)
            run_start = None
    if best is None:
        return None
    a, b = start + best[0], start + best[1]
    # Trim silence at both ends: the stretch is the replayed sound, not the quiet around it.
    while a < b and env[a] <= silence_db:
        a += 1
    while b > a and env[b - 1] <= silence_db:
        b -= 1
    return (a, b) if b > a else None


def repeats(env, silence_db, min_seconds=0.6, min_lag=0.3, max_lag=30.0, min_peaks=4,
            min_corr=0.9, max_diff_db=4.0):
    """Stretches of audio that replay an earlier stretch nearly exactly.

    Syllable peaks vote for the lag between them; a lag that many nearby peaks agree on is a candidate,
    and a candidate counts only if the two envelopes match closely over the whole stretch. A replay of
    the same rendered speech (the way #1762 restarts a chunk) matches to within a dB or two; different
    words, even the same word spoken in a new sentence, do not hold a match for 0.6 s.
    """
    marks = peaks(env, silence_db + 6)
    lo, hi = int(min_lag / HOP), int(max_lag / HOP)
    votes = {}
    for j_index, j in enumerate(marks):
        for i in reversed(marks[:j_index]):
            lag = j - i
            if lag > hi:
                break
            if lag >= lo:
                votes.setdefault(lag, []).append(j)
    candidates = []
    for lag in sorted(votes):
        near = sorted(set(votes.get(lag - 1, []) + votes[lag] + votes.get(lag + 1, [])))
        if len(near) < min_peaks:
            continue
        run = [near[0]]
        for j in near[1:] + [None]:
            if j is not None and j - run[-1] <= int(1.0 / HOP):
                run.append(j)
                continue
            if len(run) >= min_peaks and (run[-1] - run[0]) * HOP >= min_seconds * 0.6:
                candidates.append((lag, run[0], run[-1]))
            if j is not None:
                run = [j]
    found = []
    for lag, first, last in candidates:
        start, end = max(lag + 2, first - 30), min(len(env), last + 30)
        # The peaks vote to the nearest frame and a run can reach past the replay, so try the lags around
        # the vote and keep the longest stretch where the two envelopes stay together.
        best = None
        for k in range(lag - 2, lag + 3):
            stretch = matched_stretch(env, start, end, k, silence_db, max_diff_db)
            if stretch and (best is None or stretch[1] - stretch[0] > best[1] - best[0]):
                best = (*stretch, k)
        if not best:
            continue
        a, b, k = best
        corr, diff = similarity(env, a - k, a, b - a)
        if corr < min_corr or diff > max_diff_db or (b - a) * HOP < min_seconds:
            continue
        voiced = sum(1 for t in range(a, b) if env[t] > silence_db) / (b - a)
        if voiced < 0.5:
            continue
        found.append({'start': round(a * HOP, 2), 'end': round(b * HOP, 2),
                      'original_start': round((a - k) * HOP, 2), 'lag': round(k * HOP, 2),
                      'seconds': round((b - a) * HOP, 2), 'correlation': round(corr, 3),
                      'mean_db_difference': round(diff, 2)})
    # One report per replay: drop candidates that overlap a stronger one at about the same lag.
    found.sort(key=lambda r: (-r['correlation'], r['start']))
    kept = []
    for r in found:
        if not any(abs(r['lag'] - k['lag']) <= 0.05 and r['start'] < k['end'] and k['start'] < r['end'] for k in kept):
            kept.append(r)
    return sorted(kept, key=lambda r: r['start'])


# --- The report -------------------------------------------------------------------------------------------

def analyse(path, silence_db=-45.0, stall=2.0, min_gap=0.25, min_sound=0.05, window=None):
    rate, samples = read_wav(path)
    rate, samples = downsample(rate, samples)
    duration = len(samples) / rate if rate else 0.0
    env = envelope(rate, samples)
    found = segments(env, silence_db, min_gap, min_sound)
    sound = sum(b - a for a, b in found) * HOP
    loud = [s for a, b in found for s in samples[int(a * HOP * rate):int(b * HOP * rate)]]
    peak = max((abs(s) for s in samples), default=0.0)
    gaps = []
    if found:
        spans = [(0, found[0][0], 'leading')]
        spans += [(a[1], b[0], 'between') for a, b in zip(found, found[1:])]
        spans.append((found[-1][1], len(env), 'trailing'))
        for start, end, where in spans:
            if (end - start) * HOP > stall:
                gaps.append({'start': round(start * HOP, 2), 'seconds': round((end - start) * HOP, 2), 'where': where})
    report = {
        'file': str(path),
        'seconds': round(duration, 2),
        'sound_seconds': round(sound, 2),
        'segments': [{'start': round(a * HOP, 2), 'end': round(b * HOP, 2)} for a, b in found],
        'peak_dbfs': round(db(peak * peak), 1),
        'rms_dbfs': round(db(sum(s * s for s in samples) / max(1, len(samples))), 1),
        'sound_rms_dbfs': round(db(sum(s * s for s in loud) / max(1, len(loud))), 1),
        'first_sound': round(found[0][0] * HOP, 2) if found else None,
        'last_sound': round(found[-1][1] * HOP, 2) if found else None,
        'stalls': gaps,
        'repeats': repeats(env, silence_db),
        'settings': {'silence_db': silence_db, 'stall_seconds': stall, 'min_gap': min_gap},
    }
    if peak == 0.0:
        report['warning'] = ('the recording is digital silence; if audio was playing, the recorder may lack '
                             'microphone access (see README)')
    return report


# --- Transcripts ------------------------------------------------------------------------------------------

def words(text):
    """Lowercase words with punctuation and accents' combining marks dropped; digits kept."""
    text = unicodedata.normalize('NFKD', text)
    text = ''.join(c for c in text if not unicodedata.combining(c)).lower().replace('’', "'")
    return re.findall(r"[a-z0-9]+(?:'[a-z0-9]+)*", text)


def align(reference, hypothesis):
    """Levenshtein alignment: [(op, ref_word, hyp_word)] with op in ok/sub/del/ins."""
    n, m = len(reference), len(hypothesis)
    cost = [[0] * (m + 1) for _ in range(n + 1)]
    for i in range(n + 1):
        cost[i][0] = i
    for j in range(m + 1):
        cost[0][j] = j
    for i in range(1, n + 1):
        for j in range(1, m + 1):
            same = reference[i - 1] == hypothesis[j - 1]
            cost[i][j] = min(cost[i - 1][j - 1] + (0 if same else 1), cost[i - 1][j] + 1, cost[i][j - 1] + 1)
    ops, i, j = [], n, m
    while i or j:
        if i and j and cost[i][j] == cost[i - 1][j - 1] + (0 if reference[i - 1] == hypothesis[j - 1] else 1):
            ops.append(('ok' if reference[i - 1] == hypothesis[j - 1] else 'sub', reference[i - 1], hypothesis[j - 1]))
            i, j = i - 1, j - 1
        elif j and cost[i][j] == cost[i][j - 1] + 1:
            ops.append(('ins', None, hypothesis[j - 1]))
            j -= 1
        else:
            ops.append(('del', reference[i - 1], None))
            i -= 1
    return ops[::-1]


def repeated_phrases(hypothesis, reference=None, min_words=2):
    """Word runs said twice in a row ("the cat sat the cat sat on") that the expected text doesn't repeat."""
    expected = ' '.join(reference or [])
    found, index = [], 0
    while index < len(hypothesis):
        hit = None
        for size in range(min(8, (len(hypothesis) - index) // 2), min_words - 1, -1):
            first, second = hypothesis[index:index + size], hypothesis[index + size:index + 2 * size]
            if first == second and (reference is None or ' '.join(first + second) not in expected):
                hit = size
                break
        if hit:
            found.append({'words': ' '.join(hypothesis[index:index + hit]), 'at_word': index + hit})
            index += 2 * hit
        else:
            index += 1
    return found


def score(transcript, expected):
    reference, hypothesis = words(expected), words(transcript)
    ops = align(reference, hypothesis)
    counts = {op: sum(1 for o in ops if o[0] == op) for op in ('ok', 'sub', 'del', 'ins')}
    wer = (counts['sub'] + counts['del'] + counts['ins']) / len(reference) if reference else float(bool(hypothesis))
    return {'wer': round(wer, 3), 'reference_words': len(reference), 'heard_words': len(hypothesis),
            **{f'{k}_count': v for k, v in counts.items() if k != 'ok'},
            'repeated_phrases': repeated_phrases(hypothesis, reference),
            'missing': [r for op, r, _ in ops if op == 'del'][:50],
            'extra': [h for op, _, h in ops if op == 'ins'][:50]}


# --- The macOS tool ---------------------------------------------------------------------------------------

def tool():
    binary = HERE / '.build' / 'loopback'
    source = HERE / 'loopback.swift'
    if not binary.exists() or binary.stat().st_mtime < source.stat().st_mtime:
        subprocess.run([str(HERE / 'build.sh')], check=True, stdout=subprocess.DEVNULL)
    return str(binary)


# --- The recorder app (#1790) ---------------------------------------------------------------------------------
#
# macOS charges Microphone and Speech Recognition to the "responsible" process: the app that started the
# command. On the lane that is the GitHub runner's node, which is hardened, has no audio-input entitlement and
# no usage text, so macOS hands the recorder digital silence and never asks anyone. build-app.sh builds this
# same tool as SpokenMarginsLaneRecorder.app, and run_app() starts it through LaunchServices (`open`), which
# makes the app its own responsible process. The owner allows it once (setup-recorder-app.sh).
#
# The app never touches the run's evidence folder directly: the repo is under ~/Documents, which macOS
# protects with a third permission. It works in a job folder under ~/Library/Caches, and run_app() copies
# what it wrote back (`collect`).

APP_NAME = 'SpokenMarginsLaneRecorder'
APP_ENV = 'SM_LOOPBACK_APP'      # where the app is installed, when not ~/Applications
APP_TIMEOUT_STATUS = 124         # app-run's exit when the app never reported its own status
APP_LAUNCH_STATUS = 125          # app-run's exit when `open` could not start the app


def app_path():
    return Path(os.environ.get(APP_ENV) or Path.home() / 'Applications' / f'{APP_NAME}.app')


def installed_app():
    """The installed recorder app, or None."""
    app = app_path()
    return app if (app / 'Contents' / 'MacOS' / APP_NAME).exists() else None


def app_is_stale(app):
    """True when the app was built from a different loopback.swift than this checkout's."""
    import plistlib
    try:
        built = plistlib.loads((Path(app) / 'Contents' / 'Info.plist').read_bytes()).get('SMLoopbackSourceSHA256')
    except (OSError, ValueError):
        return True
    import hashlib
    return built != hashlib.sha256((HERE / 'loopback.swift').read_bytes()).hexdigest()


def jobs_folder():
    base = Path(os.environ.get('SM_LANE_STATE_DIR') or Path.home() / 'Library/Caches/SpokenMarginsLane')
    folder = base / 'recorder-jobs'
    folder.mkdir(parents=True, exist_ok=True)
    return folder


def launch_command(app, job, args):
    """`open` without -W: -W races a short-lived app (it can't find the pid and returns at once), so the
    caller waits for the job's `status` file instead. -n starts a fresh copy even if one is running."""
    return ['/usr/bin/open', '-n', '-g', '-a', os.path.abspath(app), '--args', '--job', str(job), *[str(a) for a in args]]


def run_app(app, args, timeout, inputs=None, collect=None, relay=None, stop=None, launch=subprocess.run,
            poll=0.1, clock=time.monotonic, sleep=time.sleep):
    """Runs one loopback command as the recorder app and waits for it. `{job}` in `args` is the job folder.
    `inputs` {name: path} are copied in first; `collect` {name: path} are copied out after (`stdout` and
    `stderr` are the app's own). `relay` gets each stderr line as it appears; `stop` (an Event) asks the app to
    stop. Returns (status, stdout, stderr); status is None when the app never reported one."""
    job = Path(tempfile.mkdtemp(prefix='job-', dir=jobs_folder()))
    try:
        for name, source in (inputs or {}).items():
            shutil.copyfile(source, job / name)
        opened = launch(launch_command(app, job, [str(a).replace('{job}', str(job)) for a in args]),
                        capture_output=True, text=True, timeout=60)
        if opened.returncode:
            return APP_LAUNCH_STATUS, '', f'could not start {app}: {(opened.stderr or opened.stdout).strip()}'
        deadline, shown, asked = clock() + timeout, 0, None

        def relay_new():
            nonlocal shown
            with contextlib.suppress(OSError):
                lines = (job / 'stderr').read_text(errors='replace').splitlines(keepends=True)
                for line in lines[shown:]:
                    if not line.endswith('\n'):
                        break  # half a line; read it next time
                    if relay:
                        relay(line.rstrip('\n'))
                    shown += 1

        while not (job / 'status').exists():
            relay_new()
            if asked is None and ((stop is not None and stop.is_set()) or clock() >= deadline):
                (job / 'stop').touch()
                asked = clock()
            if asked is not None and clock() - asked >= 10:
                break
            sleep(poll)
        relay_new()
        status = None
        with contextlib.suppress(OSError, ValueError):
            status = int((job / 'status').read_text().strip())
        for name, destination in (collect or {}).items():
            if (job / name).exists():
                Path(destination).parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(job / name, destination)
        read = lambda name: (job / name).read_text(errors='replace') if (job / name).exists() else ''
        return status, read('stdout'), read('stderr')
    finally:
        shutil.rmtree(job, ignore_errors=True)


def app_run(args):
    """`loopback.py app-run`: run_app() as a command, so `loopback route -- …` can wrap it. TERM asks the app to
    stop and waits for it, so route restores the default output only after the recorder has let go."""
    import signal
    stop = threading.Event()
    for signum in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT):
        signal.signal(signum, lambda *_: stop.set())
    command = args.cmd[1:] if args.cmd[:1] == ['--'] else args.cmd
    collect = dict(item.split('=', 1) for item in args.collect)
    status, out, err = run_app(args.app, command, args.timeout, collect=collect, stop=stop,
                               relay=lambda line: print(line, file=sys.stderr, flush=True))
    sys.stdout.write(out)
    if status is None:
        print(f'loopback.py: the recorder app did not report finishing within {args.timeout:.0f} s', file=sys.stderr)
        return APP_TIMEOUT_STATUS
    if status == APP_LAUNCH_STATUS:
        print('loopback.py: ' + err, file=sys.stderr)
    return status


def transcribe_file(path, locale='en-US', app=None):
    """One `loopback transcribe` run on one file. Use transcribe() for recordings: this one loses words at pauses.
    With `app`, it runs as the recorder app (above), so the app's Speech Recognition permission applies."""
    if app:
        status, out, err = run_app(app, ['transcribe', '{job}/input.wav', '--locale', locale], timeout=660,
                                   inputs={'input.wav': path})
        if status is None:
            raise RuntimeError('the recorder app did not report finishing its transcription')
        if status:
            raise RuntimeError(err.strip() or f'transcription in the recorder app exited {status}')
        return json.loads(out)
    result = subprocess.run([tool(), 'transcribe', str(path), '--locale', locale], capture_output=True, text=True)
    if result.returncode == -6 or result.returncode == 134:
        # macOS kills a process that asks for Speech Recognition when the app responsible for it (the
        # terminal or agent that started this) has no usage text for it. See README, Permissions.
        raise RuntimeError('macOS refused speech recognition for the app that started this command; '
                           'run it from Terminal and allow Speech Recognition (README, Permissions)')
    if result.returncode:
        raise RuntimeError(result.stderr.strip() or 'transcription failed')
    return json.loads(result.stdout)


# macOS's on-device recogniser forgets what it heard when a pause of more than about a second follows it:
# the final result keeps only the speech after the last long pause, or nothing when the file ends in silence
# (2026-10-17, #1790: clean `say` speech plus 1 s of trailing silence transcribed, plus 2 s came back empty,
# and a 2 s pause between two sentences dropped the first). So transcribe() cuts the recording at pauses
# longer than CHUNK_PAUSE and transcribes each stretch of speech on its own.
CHUNK_PAUSE = 0.8    # split at silences longer than this (s); pauses within a sentence stay in one chunk
CHUNK_PAD = 0.2      # silence kept around each chunk (s), well under the pause that resets the recogniser


def speech_chunks(found, frames, pause=CHUNK_PAUSE, pad=CHUNK_PAD):
    """[(start_s, end_s)] to transcribe: sound segments joined across pauses up to `pause`, padded, clamped."""
    chunks = []
    for a, b in found:
        if chunks and (a - chunks[-1][1]) * HOP <= pause:
            chunks[-1][1] = b
        else:
            chunks.append([a, b])
    end = frames * HOP
    return [(round(max(0.0, a * HOP - pad), 3), round(min(end, b * HOP + pad), 3)) for a, b in chunks]


def transcribe(path, locale='en-US', silence_db=-45.0, run=transcribe_file):
    """On-device transcript of a whole recording, one chunk of speech at a time, with word starts in the
    recording's own time. `empty_reason` says why when no words came back."""
    rate, samples = read_wav(path)
    small_rate, small = downsample(rate, samples)
    env = envelope(small_rate, small)
    chunks = speech_chunks(segments(env, silence_db, 0.25, 0.05), len(env))
    result = {'text': '', 'words': [], 'locale': locale, 'on_device': True, 'chunks': []}
    if not chunks:
        result['empty_reason'] = f'no sound above {silence_db} dBFS in the recording'
        return result
    texts, reasons = [], []
    with tempfile.TemporaryDirectory() as folder:
        for index, (start, end) in enumerate(chunks):
            piece = Path(folder) / f'chunk-{index}.wav'
            write_wav(piece, rate, samples[int(start * rate):int(end * rate)])
            heard = run(piece, locale)
            text = heard.get('text', '').strip()
            if text:
                texts.append(text)
            elif heard.get('empty_reason'):
                reasons.append(f"{start}–{end} s: {heard['empty_reason']}")
            result['words'] += [{**w, 'start': round(w['start'] + start, 3)} for w in heard.get('words', [])
                                if w.get('word')]
            result['chunks'].append({'start': start, 'end': end, 'words': len(words(text))})
    result['text'] = ' '.join(texts)
    if not texts:
        result['empty_reason'] = ('the recogniser heard no words in ' + str(round(sum(e - s for s, e in chunks), 2))
                                  + ' s of sound' + (' (' + '; '.join(reasons) + ')' if reasons else ''))
    return result


# --- Checks -----------------------------------------------------------------------------------------------

def verdict(report, max_stall=None, allow_repeats=False, max_wer=None, min_sound=None, allow_trailing=False):
    """[reason] for each failed expectation; empty means pass."""
    problems = []
    if min_sound is not None and report['sound_seconds'] < min_sound:
        problems.append(f"only {report['sound_seconds']} s of sound (wanted at least {min_sound} s)")
    if max_stall is not None:
        for gap in report['stalls']:
            if gap['seconds'] > max_stall and gap['where'] != 'leading' and not (allow_trailing and gap['where'] == 'trailing'):
                problems.append(f"{gap['seconds']} s of silence from {gap['start']} s ({gap['where']})")
    if not allow_repeats:
        for r in report['repeats']:
            problems.append(f"audio at {r['start']} s replays {r['original_start']} s for {r['seconds']} s")
        for r in report.get('score', {}).get('repeated_phrases', []):
            problems.append(f"heard \"{r['words']}\" twice in a row")
    if max_wer is not None and 'score' in report and report['score']['wer'] > max_wer:
        problems.append(f"word error rate {report['score']['wer']} is above {max_wer}")
    return problems


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    sub = parser.add_subparsers(dest='command', required=True)

    check = sub.add_parser('check', help='analyse a recording; exit 1 when an expectation fails')
    check.add_argument('wav')
    check.add_argument('--silence-db', type=float, default=-45.0)
    check.add_argument('--stall', type=float, default=2.0, help='report gaps longer than this (s)')
    check.add_argument('--max-stall', type=float, help='fail on a gap (not leading silence) longer than this (s)')
    check.add_argument('--allow-trailing', action='store_true',
                       help="don't fail on silence after the last sound (a fixed window longer than the audio)")
    check.add_argument('--allow-repeats', action='store_true', help="don't fail on repeated audio")
    check.add_argument('--min-sound', type=float, help='fail with less sound than this (s)')
    check.add_argument('--transcribe', action='store_true', help='transcribe on-device (macOS) and include it')
    check.add_argument('--expected', help='file with the text that should have been spoken (implies --transcribe)')
    check.add_argument('--max-wer', type=float, help='fail above this word error rate')
    check.add_argument('--locale', default='en-US')
    check.add_argument('--via-app', action='store_true',
                       help='transcribe as the installed recorder app, which holds Speech Recognition (README)')

    sc = sub.add_parser('score', help='score a transcript against expected text')
    sc.add_argument('transcript', help='text file, or the JSON `loopback transcribe` printed')
    sc.add_argument('expected')

    tr = sub.add_parser('transcribe', help='on-device transcript of a recording, split at pauses (JSON)')
    tr.add_argument('wav')
    tr.add_argument('--locale', default='en-US')
    tr.add_argument('--silence-db', type=float, default=-45.0)
    tr.add_argument('--via-app', action='store_true', help='transcribe as the installed recorder app')

    capture = sub.add_parser('capture', help='route output to BlackHole, record, and run a command meanwhile')
    capture.add_argument('--seconds', type=float, required=True)
    capture.add_argument('--out', required=True)
    capture.add_argument('--device', default='BlackHole 2ch')
    capture.add_argument('--no-route', action='store_true',
                         help="record only; leave the default output alone (the source plays to the device itself)")
    capture.add_argument('cmd', nargs=argparse.REMAINDER, help='-- command to run while recording')

    run = sub.add_parser('app-run', help='run one loopback command as the recorder app and wait for it')
    run.add_argument('--app', default=None, help='the app (default: the installed one)')
    run.add_argument('--timeout', type=float, default=600, help='ask the app to stop after this (s)')
    run.add_argument('--collect', action='append', default=[], metavar='NAME=PATH',
                     help='copy this file from the job folder out afterwards (stdout, stderr, or one it wrote)')
    run.add_argument('cmd', nargs=argparse.REMAINDER, help='-- the loopback command; {job} is the job folder')

    args = parser.parse_args(argv)
    if args.command == 'score':
        text = Path(args.transcript).read_text()
        if args.transcript.endswith('.json'):
            text = json.loads(text)['text']
        print(json.dumps(score(text, Path(args.expected).read_text()), indent=2))
        return 0
    if args.command == 'capture':
        return capture_run(args)
    if args.command == 'app-run':
        args.app = args.app or installed_app()
        if not args.app:
            print(f'loopback.py: no recorder app at {app_path()}; run ops/audio-loopback/setup-recorder-app.sh',
                  file=sys.stderr)
            return APP_LAUNCH_STATUS
        return app_run(args)
    if args.command == 'transcribe':
        heard = transcribe(args.wav, args.locale, args.silence_db, run=via_app(args))
        print(json.dumps(heard, indent=2))
        return 0 if heard['text'] else 1
    report = check_recording(args.wav, Path(args.expected).read_text() if args.expected else None,
                             transcribe_too=args.transcribe, locale=args.locale, silence_db=args.silence_db,
                             stall=args.stall, max_stall=args.max_stall, allow_repeats=args.allow_repeats,
                             max_wer=args.max_wer, min_sound=args.min_sound, allow_trailing=args.allow_trailing,
                             run=via_app(args))
    print(json.dumps(report, indent=2))
    return 1 if report['problems'] else 0


def check_recording(path, expected=None, transcribe_too=False, locale='en-US', silence_db=-45.0, stall=2.0,
                    max_stall=None, allow_repeats=False, max_wer=None, min_sound=None, allow_trailing=False,
                    run=transcribe_file):
    """The `check` report for one recording: the analysis, the transcript and score when `expected` text is
    given, `problems` and `verdict`. A words check that couldn't run is a problem, never a pass."""
    report = analyse(path, silence_db, stall)
    if transcribe_too or expected is not None:
        try:
            report['transcript'] = transcribe(path, locale, silence_db, run=run)
        except (RuntimeError, OSError, subprocess.CalledProcessError) as error:
            report['transcript_error'] = str(error)
        if expected is not None and 'transcript' in report and not report['transcript']['text'].strip():
            # An empty transcript of a recording with sound means the words weren't checked; say why.
            report['transcript_error'] = report['transcript'].get('empty_reason', 'the recogniser returned no words')
        elif expected is not None and 'transcript' in report:
            report['score'] = score(report['transcript']['text'], expected)
    report['problems'] = verdict(report, max_stall, allow_repeats, max_wer, min_sound, allow_trailing)
    if expected is not None and 'transcript_error' in report:
        report['problems'].append('could not check the words: ' + report['transcript_error'])
    report['verdict'] = 'FAIL' if report['problems'] else 'PASS'
    return report


def via_app(args):
    """The transcriber for --via-app: transcribe_file as the installed recorder app."""
    if not args.via_app:
        return transcribe_file
    app = installed_app()
    if not app:
        sys.exit(f'no recorder app at {app_path()}; run ops/audio-loopback/setup-recorder-app.sh')
    return lambda path, locale: transcribe_file(path, locale, app=app)


def capture_run(args):
    """Records the device for --seconds while the command runs. With routing, the recorder runs inside
    `loopback route`, which puts the previous default output back when it ends, however it ends."""
    binary = tool()
    record = [binary, 'record', '--device', args.device, '--seconds', str(args.seconds), '--out', args.out]
    command = args.cmd[1:] if args.cmd[:1] == ['--'] else args.cmd
    recorder_cmd = record if args.no_route else [binary, 'route', '--to', args.device, '--', *record]
    # A routing capture holds the Mac-wide audio window (window.py), so it never overlaps a lane test's window:
    # two routes at once would each save the other's BlackHole as "the device to put back".
    import window
    with contextlib.nullcontext() if args.no_route else window.audio_lock(f'loopback.py capture (pid {os.getpid()})',
                                                                          max_wait=window.LOCK_WAIT):
        recorder = subprocess.Popen(recorder_cmd)
        status = 0
        try:
            if command:
                status = subprocess.run(command).returncode
        finally:
            recorded = recorder.wait()
    return recorded or status


if __name__ == '__main__':
    if not shutil.which('swiftc') and len(sys.argv) > 1 and sys.argv[1] == 'capture':
        sys.exit('capture needs macOS with swiftc')
    sys.exit(main())
