"""The audio window beside an app test run (#1790): started only when a test wants it, stopped after, and its
verdicts reach the lane report."""
import importlib.util
import io
import json
import os
from pathlib import Path
import sys
import tempfile
import textwrap
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import lane_audio_window
import lane_xcresult_attachments

AUDIO_TEST = 'SpokenMarginsAppTests/AudioLoopbackPlaybackTests/testIOSVoiceSpeaksThePassageOnceWithoutGaps'
SCRIPTS = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('verification_for_audio', SCRIPTS / 'verify-tests.py')
verification = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verification)

# Stands in for window.py: says it is ready, then waits to be stopped, and notes how it ended.
FAKE_SERVER = textwrap.dedent('''
    import json, signal, sys, time
    from pathlib import Path
    folder = Path(sys.argv[sys.argv.index('--dir') + 1])
    def stop(*_):
        (folder / 'stopped').write_text('TERM')
        sys.exit(0)
    signal.signal(signal.SIGTERM, stop)
    (folder / 'ready.json').write_text(json.dumps({'pid': 1}))
    while True:
        time.sleep(0.05)
''')


class ServeTests(unittest.TestCase):
    def setUp(self):
        self.output = Path(tempfile.mkdtemp())
        self.server = self.output / 'fake_window.py'
        self.server.write_text(FAKE_SERVER)
        os.environ.pop(lane_audio_window.ENV, None)

    def test_a_run_without_an_audio_test_starts_nothing(self):
        with lane_audio_window.serve(self.output, ['SpokenMarginsAppTests/OtherTests/testA'], server=self.server) as folder:
            self.assertIsNone(folder)
            self.assertNotIn(lane_audio_window.ENV, os.environ)
        self.assertFalse((self.output / 'audio-window').exists())

    def test_an_audio_test_gets_a_running_server_that_stops_after(self):
        with lane_audio_window.serve(self.output, [AUDIO_TEST], server=self.server, out=io.StringIO()) as folder:
            self.assertTrue((folder / 'ready.json').exists())
            self.assertEqual(os.environ[lane_audio_window.ENV], str(folder), 'xcodebuild passes it to the test')
        self.assertNotIn(lane_audio_window.ENV, os.environ, 'later steps see no window')
        self.assertEqual((folder / 'stopped').read_text(), 'TERM', 'stopped with TERM, so route can restore')

    def test_a_server_that_does_not_start_is_warned_about(self):
        broken = self.output / 'broken.py'
        broken.write_text('import sys; sys.exit(3)\n')
        out = io.StringIO()
        with lane_audio_window.serve(self.output, [AUDIO_TEST], server=broken, out=out) as folder:
            self.assertIsNotNone(folder, 'the test still runs, and skips: the lane reports INCONCLUSIVE')
        self.assertIn('did not start', out.getvalue())


class WholePlanTests(unittest.TestCase):
    """Audit on b3dc4be: a Release or full AudioAdapters run names no test, so no window opens, the audio test
    skips, and that skip failed the run ('Unexpected skip') on every Mac."""

    def setUp(self):
        self.output = Path(tempfile.mkdtemp())
        self.server = self.output / 'fake_window.py'
        self.server.write_text(FAKE_SERVER)
        self.expected = {AUDIO_TEST, 'SpokenMarginsAppTests/OtherTests/testA'}
        self.records = {AUDIO_TEST: {'status': 'skipped'}, 'SpokenMarginsAppTests/OtherTests/testA': {'status': 'passed'}}

    def test_a_whole_plan_run_opens_no_window_and_its_audio_skip_passes(self):
        with lane_audio_window.serve(self.output, [], server=self.server) as folder:
            self.assertIsNone(folder, 'the Mac\'s output is not switched for a run that never asked')
        allowed = lane_audio_window.unasked(self.expected, [])
        self.assertEqual(verification.reconcile(self.expected, self.records, allowed), [])

    def test_a_request_that_names_the_audio_test_still_fails_on_its_skip(self):
        selectors = ['SpokenMarginsAppTests/AudioLoopbackPlaybackTests']
        allowed = lane_audio_window.unasked(self.expected, selectors)
        self.assertEqual(allowed, set())
        self.assertEqual(verification.reconcile(self.expected, self.records, allowed), [f'Unexpected skip: {AUDIO_TEST}'],
                         'the lane could not listen, so the T3 must not pass')

    def test_the_server_starts_on_the_selectors_not_the_plan(self):
        with lane_audio_window.serve(self.output, ['SpokenMarginsAppTests/OtherTests'], server=self.server) as folder:
            self.assertIsNone(folder)


class ReportTests(unittest.TestCase):
    def test_verdicts_become_report_lines(self):
        folder = Path(tempfile.mkdtemp())
        (folder / 'w1.result.json').write_text(json.dumps({
            'verdict': 'FAIL', 'test': '-[AudioLoopbackPlaybackTests testIOSVoice]', 'wav': str(folder / 'w1.app.wav'),
            'summary': 'FAIL: 2.1 s of sound in 25 s; Problems: 4.0 s of silence from 3.1 s (between)'}))
        (folder / 'w2.result.json').write_text('{half')
        entries = lane_audio_window.attachments(folder)
        self.assertEqual(entries[0]['audio']['verdict'], 'FAIL')
        self.assertIn(str(folder / 'w1.app.wav'), entries[0]['files'])
        self.assertIn('unreadable verdict', entries[1]['error'])
        text = '\n'.join(lane_xcresult_attachments.report_lines(entries))
        self.assertIn('Audio check for `-[AudioLoopbackPlaybackTests testIOSVoice]`: FAIL: 2.1 s of sound', text)
        self.assertIn('w1.app.wav', text, 'the recording is linked')
        self.assertEqual(lane_audio_window.attachments(None), [])


if __name__ == '__main__':
    unittest.main()
