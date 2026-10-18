"""Host tests for the audio window server (#1790). No audio device: the recorder is a stand-in that writes a wav."""
import json
import math
import os
import tempfile
import threading
import unittest
from pathlib import Path
from unittest import mock

import loopback
import window
from test_loopback import RATE, speech

TONE = [0.5 * math.sin(2 * math.pi * 1000 * i / RATE) for i in range(int(0.3 * RATE))]


class FakeRecorder:
    """Writes `samples` to the wav when started, like `loopback record` would after its window."""

    def __init__(self, samples, status=0, starts=True):
        self.samples, self.status, self.starts = samples, status, starts
        self.lines, self.stopped = ['loopback: recording BlackHole 2ch'], False
        self.started = threading.Event()

    def __call__(self, wav, seconds):
        self.wav, self.seconds = wav, seconds
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
        options = dict(recorder_factory=recorder, pilot=lambda tone: None, lock=no_lock,
                       device_present=lambda: True, clock=lambda: 100.0)
        if check:
            options['check'] = check
        options.update(kwargs)
        result = window.run_window(self.folder, 'w1', {'seconds': 10, 'max_stall': 2.0} if raw is None else raw, **options)
        return result, recorder

    def test_pilot_then_speech_passes_and_the_pilot_is_cut_off(self):
        result, recorder = self.run_window(TONE + [0.0] * int(0.5 * RATE) + speech(1, 4.0) + [0.0] * RATE)
        self.assertEqual(result['verdict'], 'PASS', result)
        self.assertTrue((self.folder / 'w1.recording').exists(), 'the test was told the recorder runs')
        self.assertGreater(result['report']['first_sound'], 0.3, 'the app recording starts after the pilot')
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
        self.assertIn('microphone access', result['reason'])

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
                                       device_present=lambda: True)
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
