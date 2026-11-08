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
import unittest.mock

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
        patch = unittest.mock.patch.dict(os.environ)  # CI's hosted runners set RUNNER_ENVIRONMENT
        patch.start()
        self.addCleanup(patch.stop)
        os.environ.pop('RUNNER_ENVIRONMENT', None)

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
        patch = unittest.mock.patch.dict(os.environ)  # CI's hosted runners set RUNNER_ENVIRONMENT
        patch.start()
        self.addCleanup(patch.stop)
        os.environ.pop('RUNNER_ENVIRONMENT', None)

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


class HostedMacTests(unittest.TestCase):
    """#3604: a GitHub-hosted Mac has no BlackHole and no recorder app, so a request that names the audio test could
    only come back INCONCLUSIVE. There it is recorded as not run, and the report says the audio check is owed."""

    def setUp(self):
        self.output = Path(tempfile.mkdtemp())
        self.server = self.output / 'fake_window.py'
        self.server.write_text(FAKE_SERVER)
        self.expected = {AUDIO_TEST, 'SpokenMarginsAppTests/OtherTests/testA'}
        self.records = {AUDIO_TEST: {'status': 'skipped'}, 'SpokenMarginsAppTests/OtherTests/testA': {'status': 'passed'}}
        self.selectors = ['SpokenMarginsAppTests/AudioLoopbackPlaybackTests']

    def test_the_runner_environment_decides(self):
        self.assertTrue(lane_audio_window.hosted({'RUNNER_ENVIRONMENT': 'github-hosted'}))
        self.assertFalse(lane_audio_window.hosted({'RUNNER_ENVIRONMENT': 'self-hosted', 'GITHUB_ACTIONS': 'true'}))
        self.assertFalse(lane_audio_window.hosted({}))

    def test_a_named_audio_test_that_skips_on_a_hosted_mac_does_not_fail_the_step(self):
        allowed = lane_audio_window.unasked(self.expected, self.selectors, hosted_runner=True)
        self.assertEqual(allowed, {AUDIO_TEST})
        self.assertEqual(verification.reconcile(self.expected, self.records, allowed), [])

    def test_the_same_request_on_the_self_hosted_mac_still_fails_on_its_skip(self):
        allowed = lane_audio_window.unasked(self.expected, self.selectors, hosted_runner=False)
        self.assertEqual(verification.reconcile(self.expected, self.records, allowed), [f'Unexpected skip: {AUDIO_TEST}'])

    def test_another_skip_on_a_hosted_mac_still_fails(self):
        """The lane's other unexpected-skip check: only AudioLoopback tests are excused."""
        records = {**self.records, 'SpokenMarginsAppTests/OtherTests/testA': {'status': 'skipped'}}
        allowed = lane_audio_window.unasked(self.expected, self.selectors, hosted_runner=True)
        self.assertEqual(verification.reconcile(self.expected, records, allowed),
                         ['Unexpected skip: SpokenMarginsAppTests/OtherTests/testA'])

    def test_a_hosted_mac_starts_no_window_even_when_a_test_is_named(self):
        with lane_audio_window.serve(self.output, self.selectors, server=self.server, hosted_runner=True) as folder:
            self.assertIsNone(folder)
            self.assertNotIn(lane_audio_window.ENV, os.environ)
        self.assertFalse((self.output / 'audio-window').exists())

    def test_the_skip_is_recorded_as_not_run_and_the_report_says_the_check_is_owed(self):
        names, entries = lane_audio_window.not_run(self.records, hosted_runner=True)
        self.assertEqual(names, [AUDIO_TEST])
        text = '\n'.join(lane_xcresult_attachments.report_lines(entries))
        self.assertIn(f'Audio check for `{AUDIO_TEST}`: not run: the hosted Mac has no audio loopback', text)
        self.assertIn('still owed', text)

    def test_the_manifest_steps_carry_the_field_the_lane_runner_reads(self):
        """verify-tests.py writes `audio_not_run` through record_not_run; lane-runner.py's summarize_manifest reads it."""
        lane = importlib.util.module_from_spec(importlib.util.spec_from_file_location(
            'lane_runner_for_audio', SCRIPTS / 'lane-runner.py'))
        lane.__spec__.loader.exec_module(lane)
        steps = [{'name': 'build-for-testing'}, {'name': 'xcode-tests', 'tests': self.records}]
        self.assertTrue(lane_audio_window.record_not_run(steps, hosted_runner=True))
        self.assertNotIn('audio_not_run', steps[0])
        self.assertEqual(steps[1]['audio_not_run'], [AUDIO_TEST])
        self.assertEqual(steps[1]['attachments'][0]['audio']['verdict'], 'NOT RUN')
        self.assertEqual(lane.summarize_manifest({'steps': steps})['audio_not_run'], [AUDIO_TEST])
        self.assertFalse(lane_audio_window.record_not_run([{'name': 'xcode-tests', 'tests': self.records}],
                                                          hosted_runner=False))

    def test_nothing_is_recorded_as_not_run_on_the_self_hosted_mac_or_for_a_pass(self):
        self.assertEqual(lane_audio_window.not_run(self.records, hosted_runner=False), ([], []))
        passed = {AUDIO_TEST: {'status': 'passed'}}
        self.assertEqual(lane_audio_window.not_run(passed, hosted_runner=True), ([], []))


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
