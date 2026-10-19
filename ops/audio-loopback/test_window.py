"""Host tests for the audio window server (#1790). No audio device: the recorder is a stand-in that writes a wav."""
import json
import math
import os
import sys
import tempfile
import threading
import unittest
from pathlib import Path
from unittest import mock

import loopback
import window
from test_loopback import RATE, speech

TONE = [0.5 * math.sin(2 * math.pi * 1000 * i / RATE) for i in range(int(0.3 * RATE))]
FAKE_APP = Path('/nonexistent/SpokenMarginsLaneRecorder.app')


PREROLL = [0.0] * int(window.PREROLL_SECONDS * RATE)


class FakeRecorder:
    """Writes `before` (a quiet pre-roll unless given) and then `samples` to the wav when started, like
    `loopback record` would after its window."""

    def __init__(self, samples, status=0, starts=True, before=None):
        self.samples = None if samples is None else (PREROLL if before is None else before) + samples
        self.status, self.starts = status, starts
        self.lines, self.stopped = ['loopback: recording BlackHole 2ch'], False
        self.started = threading.Event()

    def __call__(self, wav, seconds, app=None):
        self.wav, self.seconds, self.app = wav, seconds, app
        return self

    def start(self):
        loopback.write_wav(self.wav, RATE, self.samples)
        if self.starts:
            self.started.set()
        return self

    def wait(self, timeout):
        return self.status

    def stop(self):
        self.stopped = True


class FakeTime:
    """A clock that the pre-roll's sleep and the pilot move on, as real time would."""

    def __init__(self):
        self.now = 100.0

    def clock(self):
        return self.now

    def sleep(self, seconds):
        self.now += seconds

    def pilot(self, tone):
        self.now += window.PILOT_SECONDS


def no_lock(owner, max_wait=0):
    import contextlib
    return contextlib.nullcontext()


class WindowTests(unittest.TestCase):
    def setUp(self):
        self.folder = Path(tempfile.mkdtemp())
        state = tempfile.mkdtemp()
        patcher = mock.patch.dict(os.environ, {'SM_LANE_STATE_DIR': state})
        patcher.start()
        self.addCleanup(patcher.stop)

    def run_window(self, samples, raw=None, check=None, **kwargs):
        recorder = kwargs.pop('recorder', FakeRecorder(samples))
        time = FakeTime()
        options = dict(recorder_factory=recorder, pilot=time.pilot, lock=no_lock, device_present=lambda: True,
                       clock=time.clock, sleep=time.sleep, recorder_app=lambda: FAKE_APP, other_jobs=lambda: 0)
        if check:
            options['check'] = check
        options.update(kwargs)
        result = window.run_window(self.folder, 'w1', {'seconds': 10, 'max_stall': 2.0} if raw is None else raw, **options)
        return result, recorder

    def test_pilot_then_speech_passes_and_the_pilot_is_cut_off(self):
        result, recorder = self.run_window(TONE + [0.0] * int(0.5 * RATE) + speech(1, 4.0) + [0.0] * RATE)
        self.assertEqual(result['verdict'], 'PASS', result)
        self.assertTrue((self.folder / 'w1.recording').exists(), 'the test was told the recorder runs')
        # Speech starts 0.5 s after the pilot, and the cut is 0.4 s after it: the pilot's tone is gone.
        self.assertAlmostEqual(result['report']['first_sound'], 0.1, delta=0.05)
        self.assertTrue(recorder.stopped)
        self.assertIn('PASS: ', window.summary_line(result))

    def test_a_stall_after_the_pilot_fails(self):
        audio = TONE + [0.0] * int(0.5 * RATE) + speech(2, 2.0) + [0.0] * (4 * RATE) + speech(3, 2.0)
        result, _ = self.run_window(audio)
        self.assertEqual(result['verdict'], 'FAIL')
        self.assertTrue(any('silence' in p for p in result['report']['problems']), result['report']['problems'])
        self.assertIn('Problems:', window.summary_line(result))

    def test_the_app_playing_nothing_fails(self):
        result, _ = self.run_window(TONE + [0.0] * (5 * RATE), {'seconds': 5, 'min_sound': 2})
        self.assertEqual(result['verdict'], 'FAIL', 'the recorder heard the pilot, so the silence is the app\'s')

    def test_digital_silence_without_the_pilot_is_unavailable(self):
        result, _ = self.run_window([0.0] * (5 * RATE), {'seconds': 5, 'min_sound': 2})
        self.assertEqual(result['verdict'], 'UNAVAILABLE')
        self.assertIn('microphone access', result['reason'].lower())

    def test_words_that_could_not_be_checked_are_unavailable_not_a_pass(self):
        def check(path, expected, **options):
            return {'verdict': 'FAIL', 'problems': ['could not check the words: no permission']}
        result, _ = self.run_window(TONE + speech(4, 2.0), {'seconds': 5, 'expected': 'hello'}, check=check)
        self.assertEqual(result['verdict'], 'UNAVAILABLE')
        self.assertIn('could not check the words', result['reason'])

    def test_wrong_words_fail(self):
        def check(path, expected, **options):
            return loopback.check_recording(path, expected, max_wer=0.2,
                                            run=lambda p, locale: {'text': 'something else entirely', 'words': []})
        result, _ = self.run_window(TONE + [0.0] * int(0.5 * RATE) + speech(5, 3.0),
                                    {'seconds': 5, 'expected': 'the quick brown fox'}, check=check)
        self.assertEqual(result['verdict'], 'FAIL')
        self.assertIn('word error rate', ' '.join(result['report']['problems']))

    def test_sound_before_the_pilot_is_unavailable_not_a_fail(self):
        # Audit on b3dc4be: another simulator or the Mac's player sends sound to BlackHole too. A second voice
        # under the app's pushes the word error rate up; the pre-roll hears it before the test plays anything.
        other = speech(8, 30.0)
        app = TONE + [0.0] * int(0.5 * RATE) + speech(9, 4.0)
        mixed = [a + b for a, b in zip(app, other[len(PREROLL):])]
        result, _ = self.run_window(mixed, {'seconds': 5, 'expected': 'the quick brown fox'},
                                    recorder=FakeRecorder(mixed, before=other[:len(PREROLL)]))
        self.assertEqual(result['verdict'], 'UNAVAILABLE', result.get('report', {}).get('problems'))
        self.assertIn('something else was already playing', result['reason'])

    def test_another_simulator_job_at_the_start_is_unavailable_and_records_nothing(self):
        recorder = FakeRecorder(TONE + speech(10, 2.0))
        result, _ = self.run_window(None, recorder=recorder, other_jobs=lambda: 1)
        self.assertEqual(result['verdict'], 'UNAVAILABLE')
        self.assertIn('another simulator job is running', result['reason'])
        self.assertFalse(hasattr(recorder, 'wav'), 'no recorder started, so the output was never switched')

    def test_another_simulator_job_that_joined_during_the_window_is_unavailable(self):
        counts = iter([0, 1])
        result, _ = self.run_window(TONE + [0.0] * int(0.5 * RATE) + speech(11, 3.0),
                                    other_jobs=lambda: next(counts))
        self.assertEqual(result['verdict'], 'UNAVAILABLE')
        self.assertIn('another simulator job is running (1 more lane simulator slot held)', result['reason'])

    def test_other_simulator_jobs_does_not_count_this_runs_own_slot(self):
        sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'scripts'))
        import lane_slots
        for held, others in ((0, 0), (1, 0), (2, 1)):
            with mock.patch.object(lane_slots, 'simulator_jobs_running', return_value=held):
                self.assertEqual(window.other_simulator_jobs(), others, held)

    def test_a_recorder_that_never_starts_is_unavailable(self):
        recorder = FakeRecorder([0.0] * RATE, starts=False)
        with mock.patch.object(window, 'START_TIMEOUT', 0.01):
            result, _ = self.run_window(None, recorder=recorder)
        self.assertEqual(result['verdict'], 'UNAVAILABLE')
        self.assertTrue(recorder.stopped)

    def test_a_failed_recorder_is_unavailable(self):
        result, _ = self.run_window(TONE + speech(6, 2.0), recorder=FakeRecorder(TONE, status=1))
        self.assertEqual(result['verdict'], 'UNAVAILABLE')
        self.assertIn('exited 1', result['reason'])

    def test_no_blackhole_is_unavailable(self):
        result, _ = self.run_window(TONE, device_present=lambda: False)
        self.assertEqual(result['verdict'], 'UNAVAILABLE')
        self.assertIn('not installed', result['reason'])

    def test_bad_requests_are_answered_not_raised(self):
        for raw in ({}, {'seconds': 0}, {'seconds': 999}, {'seconds': 5, 'expected': ''},
                    {'seconds': 5, 'max_wer': 'high'}, {'seconds': 5, 'lock_wait': -1}):
            result, _ = self.run_window(TONE, raw)
            self.assertEqual(result['verdict'], 'UNAVAILABLE', raw)
            self.assertIn('bad request', result['reason'])

    def test_the_lock_wait_is_the_requests_capped_by_the_servers(self):
        self.assertEqual(window.parse_request({'seconds': 5, 'lock_wait': 40})[2], 40)
        self.assertEqual(window.parse_request({'seconds': 5, 'lock_wait': 10 ** 6})[2], window.LOCK_WAIT)


class LockTests(unittest.TestCase):
    def setUp(self):
        patcher = mock.patch.dict(os.environ, {'SM_LANE_STATE_DIR': tempfile.mkdtemp()})
        patcher.start()
        self.addCleanup(patcher.stop)

    def test_one_window_at_a_time(self):
        with window.audio_lock('first'):
            ticks = iter(range(0, 100, 5))
            with self.assertRaises(TimeoutError) as raised:
                with window.audio_lock('second', max_wait=10, clock=lambda: next(ticks), sleep=lambda s: None):
                    pass
            self.assertIn('first', str(raised.exception), 'the timeout names who holds it')
        with window.audio_lock('third', max_wait=0):
            pass  # free again once the first ends

    def test_a_busy_lock_answers_unavailable(self):
        folder = Path(tempfile.mkdtemp())
        with window.audio_lock('another lane test'):
            result = window.run_window(folder, 'w', {'seconds': 5, 'lock_wait': 0},
                                       recorder_factory=FakeRecorder(TONE), pilot=lambda tone: None,
                                       device_present=lambda: True, recorder_app=lambda: FAKE_APP,
                                       other_jobs=lambda: 0)
        self.assertEqual(result['verdict'], 'UNAVAILABLE')
        self.assertIn('another audio window', result['reason'])

    def test_a_routing_capture_takes_the_same_lock(self):
        args = mock.Mock(no_route=False, device='BlackHole 2ch', seconds=1, out='x.wav', cmd=[])
        with window.audio_lock('a lane test'), mock.patch.object(loopback, 'tool', return_value='/usr/bin/true'), \
                mock.patch.object(window, 'LOCK_WAIT', 0), mock.patch('subprocess.Popen') as popen:
            with self.assertRaises(TimeoutError):
                loopback.capture_run(args)
        popen.assert_not_called()  # nothing routed while the lane test's window was open
        args.no_route = True
        with window.audio_lock('a lane test'), mock.patch.object(loopback, 'tool', return_value='/usr/bin/true'):
            self.assertEqual(loopback.capture_run(args), 0, 'a capture that does not route needs no lock')


class ServeTests(unittest.TestCase):
    def test_answers_each_request_once_and_cleans_up(self):
        folder = Path(tempfile.mkdtemp())
        (folder / 'a.request.json').write_text(json.dumps({'seconds': 3, 'test': '-[T test]'}))
        (folder / 'b.request.json').write_text('{not json')
        handled = []
        rounds = iter([True, True, False])

        def handle(where, request_id, raw):
            handled.append(request_id)
            return {'verdict': 'UNAVAILABLE', 'reason': 'test stand-in'}

        window.serve(folder, handle=handle, alive=lambda: next(rounds), poll=0)
        self.assertEqual(handled, ['a'], 'each request is answered once; b is unreadable')
        a = json.loads((folder / 'a.result.json').read_text())
        self.assertEqual(a['test'], '-[T test]')
        self.assertIn('UNAVAILABLE: test stand-in', a['summary'])
        self.assertIn('unreadable request', json.loads((folder / 'b.result.json').read_text())['reason'])
        self.assertFalse((folder / 'ready.json').exists(), 'ready goes away when the server stops')
        self.assertEqual([r['file'].endswith('.result.json') for r in window.results(folder)], [True, True])


if __name__ == '__main__':
    unittest.main()
