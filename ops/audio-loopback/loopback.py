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
import json
import math
import re
import shutil
import subprocess
import sys
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


def transcribe(path, locale='en-US'):
    result = subprocess.run([tool(), 'transcribe', str(path), '--locale', locale], capture_output=True, text=True)
    if result.returncode == -6 or result.returncode == 134:
        # macOS kills a process that asks for Speech Recognition when the app responsible for it (the
        # terminal or agent that started this) has no usage text for it. See README, Permissions.
        raise RuntimeError('macOS refused speech recognition for the app that started this command; '
                           'run it from Terminal and allow Speech Recognition (README, Permissions)')
    if result.returncode:
        raise RuntimeError(result.stderr.strip() or 'transcription failed')
    return json.loads(result.stdout)


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

    sc = sub.add_parser('score', help='score a transcript against expected text')
    sc.add_argument('transcript', help='text file, or the JSON `loopback transcribe` printed')
    sc.add_argument('expected')

    capture = sub.add_parser('capture', help='route output to BlackHole, record, and run a command meanwhile')
    capture.add_argument('--seconds', type=float, required=True)
    capture.add_argument('--out', required=True)
    capture.add_argument('--device', default='BlackHole 2ch')
    capture.add_argument('--no-route', action='store_true',
                         help="record only; leave the default output alone (the source plays to the device itself)")
    capture.add_argument('cmd', nargs=argparse.REMAINDER, help='-- command to run while recording')

    args = parser.parse_args(argv)
    if args.command == 'score':
        text = Path(args.transcript).read_text()
        if args.transcript.endswith('.json'):
            text = json.loads(text)['text']
        print(json.dumps(score(text, Path(args.expected).read_text()), indent=2))
        return 0
    if args.command == 'capture':
        return capture_run(args)
    report = analyse(args.wav, args.silence_db, args.stall)
    if args.transcribe or args.expected:
        try:
            report['transcript'] = transcribe(args.wav, args.locale)
        except (RuntimeError, OSError, subprocess.CalledProcessError) as error:
            report['transcript_error'] = str(error)
        if args.expected and 'transcript' in report:
            report['score'] = score(report['transcript']['text'], Path(args.expected).read_text())
    report['problems'] = verdict(report, args.max_stall, args.allow_repeats, args.max_wer, args.min_sound, args.allow_trailing)
    if args.expected and 'transcript_error' in report:
        # A check that couldn't run is not a pass.
        report['problems'].append('could not check the words: ' + report['transcript_error'])
    report['verdict'] = 'FAIL' if report['problems'] else 'PASS'
    print(json.dumps(report, indent=2))
    return 1 if report['problems'] else 0


def capture_run(args):
    """Records the device for --seconds while the command runs. With routing, the recorder runs inside
    `loopback route`, which puts the previous default output back when it ends, however it ends."""
    binary = tool()
    record = [binary, 'record', '--device', args.device, '--seconds', str(args.seconds), '--out', args.out]
    command = args.cmd[1:] if args.cmd[:1] == ['--'] else args.cmd
    recorder_cmd = record if args.no_route else [binary, 'route', '--to', args.device, '--', *record]
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
