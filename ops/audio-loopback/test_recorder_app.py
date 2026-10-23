"""Host tests for the recorder app (#1790): it builds with the keys macOS needs, the lane starts it through
LaunchServices and reads its results from files, and a recorder that can't hear never becomes a PASS or FAIL.
No permission prompt: nothing here records or transcribes, and the app is never opened."""
import hashlib
import json
import os
import plistlib
import shutil
import subprocess
import sys
import tempfile
import threading
import unittest
from pathlib import Path
from unittest import mock

import loopback
import window
from test_window import FAKE_APP, TONE, FakeRecorder, no_lock

HERE = Path(__file__).resolve().parent


class FakeLaunch:
    """Stands in for `open`: plays the app's part in another thread, writing what it would to the job folder."""

    def __init__(self, status=0, stdout='', stderr_lines=(), writes=None, report=True, returncode=0):
        self.status, self.stdout, self.stderr_lines = status, stdout, list(stderr_lines)
        self.writes, self.report, self.returncode = writes or {}, report, returncode
        self.commands = []

    def __call__(self, command, **_):
        self.commands.append(command)
        job = Path(command[command.index('--job') + 1])
        self.job, self.args = job, command[command.index('--job') + 2:]
        if self.returncode == 0:
            threading.Thread(target=self.app, args=(job,), daemon=True).start()
        return subprocess.CompletedProcess(command, self.returncode, '', 'LSOpenURLsWithRole() failed')

    def app(self, job):
        self.inputs = sorted(p.name for p in job.iterdir())
        (job / 'stderr').write_text(''.join(line + '\n' for line in self.stderr_lines))
        (job / 'stdout').write_text(self.stdout)
        for name, text in self.writes.items():
            (job / name).write_text(text)
        if self.report:
            (job / 'status').write_text(f'{self.status}\n')


class Isolated(unittest.TestCase):
    def setUp(self):
        self.state = Path(tempfile.mkdtemp())
        patcher = mock.patch.dict(os.environ, {'SM_LANE_STATE_DIR': str(self.state)})
        patcher.start()
        self.addCleanup(patcher.stop)


class LaunchTests(Isolated):
    def test_the_app_is_started_through_launchservices_without_blocking_on_it(self):
        command = loopback.launch_command('/A/SpokenMarginsLaneRecorder.app', '/jobs/j1', ['record', '--seconds', 5])
        self.assertEqual(command[:5], ['/usr/bin/open', '-n', '-g', '-a', '/A/SpokenMarginsLaneRecorder.app'])
        self.assertEqual(command[5:], ['--args', '--job', '/jobs/j1', 'record', '--seconds', '5'])
        self.assertNotIn('-W', command, 'open -W returns at once for a short job; the status file is the wait')

    def test_results_come_back_through_the_job_folder(self):
        source = self.state / 'chunk.wav'
        source.write_text('wav bytes')
        out = self.state / 'evidence' / 'kept.txt'
        lines = []
        launch = FakeLaunch(stdout='{"text": "hi"}', stderr_lines=['loopback: recording BlackHole 2ch'],
                            writes={'made.txt': 'made by the app'})
        status, stdout, stderr = loopback.run_app('/A.app', ['transcribe', '{job}/input.wav'], timeout=30,
                                                  inputs={'input.wav': source}, collect={'made.txt': out},
                                                  relay=lines.append, launch=launch, poll=0.01)
        self.assertEqual((status, stdout), (0, '{"text": "hi"}'))
        self.assertIn('loopback: recording', stderr)
        self.assertEqual(lines, ['loopback: recording BlackHole 2ch'])
        self.assertEqual(launch.args, ['transcribe', f'{launch.job}/input.wav'], '{job} is the job folder')
        self.assertIn('input.wav', launch.inputs, 'inputs are copied in before the app starts')
        self.assertEqual(out.read_text(), 'made by the app')
        self.assertTrue(str(launch.job).startswith(str(self.state / 'recorder-jobs')),
                        'the app works under Library/Caches, never in the repo under ~/Documents')
        self.assertFalse(launch.job.exists(), 'the job folder is removed afterwards')

    def test_an_app_that_never_reports_is_asked_to_stop_and_answers_none(self):
        ticks = iter(range(0, 1000))
        launch = FakeLaunch(report=False)
        status, _, _ = loopback.run_app('/A.app', ['record'], timeout=5, launch=launch, poll=0,
                                        clock=lambda: next(ticks), sleep=lambda s: None)
        self.assertIsNone(status)

    def test_a_stop_request_reaches_the_app_as_a_file(self):
        stop = threading.Event()
        stop.set()
        seen = []
        launch = FakeLaunch(report=False)
        ticks = iter(range(0, 1000))

        def sleep(_):
            if (launch.job / 'stop').exists():
                seen.append('stop')
                (launch.job / 'status').write_text('143\n')

        status, _, _ = loopback.run_app('/A.app', ['record'], timeout=600, stop=stop, launch=launch, poll=0,
                                        clock=lambda: next(ticks), sleep=sleep)
        self.assertEqual((status, seen[:1]), (143, ['stop']))

    def test_open_failing_is_its_own_status(self):
        status, _, stderr = loopback.run_app('/A.app', ['record'], timeout=5, launch=FakeLaunch(returncode=1))
        self.assertEqual(status, loopback.APP_LAUNCH_STATUS)
        self.assertIn('could not start', stderr)

    def test_app_run_without_an_installed_app_exits_with_the_setup_hint(self):
        with mock.patch.dict(os.environ, {loopback.APP_ENV: str(self.state / 'none/SpokenMarginsLaneRecorder.app')}):
            self.assertIsNone(loopback.installed_app())
            self.assertEqual(loopback.main(['app-run', '--', 'record']), loopback.APP_LAUNCH_STATUS)


class TranscribeTests(Isolated):
    def test_transcription_runs_as_the_app(self):
        source = self.state / 'chunk.wav'
        source.write_text('x')
        with mock.patch.object(loopback, 'run_app', return_value=(0, '{"text": "hello", "words": []}', '')) as run:
            self.assertEqual(loopback.transcribe_file(source, app='/A.app')['text'], 'hello')
        self.assertEqual(run.call_args.args[1][:2], ['transcribe', '{job}/input.wav'])

    def test_a_refused_or_silent_app_raises_so_the_words_count_as_unchecked(self):
        for answer in ((1, '', 'loopback: speech recognition is not authorised (not asked yet)'), (None, '', '')):
            with mock.patch.object(loopback, 'run_app', return_value=answer), self.assertRaises(RuntimeError):
                loopback.transcribe_file('x.wav', app='/A.app')


class WindowAppTests(Isolated):
    def window(self, recorder_app, recorder=None, **kwargs):
        return window.run_window(Path(tempfile.mkdtemp()), 'w1', {'seconds': 5},
                                 recorder_factory=recorder or FakeRecorder(TONE), pilot=lambda tone: None,
                                 lock=no_lock, device_present=lambda: True, recorder_app=recorder_app, **kwargs)

    def test_no_recorder_app_is_unavailable_with_the_setup_step(self):
        result = self.window(lambda: None)
        self.assertEqual(result['verdict'], 'UNAVAILABLE')
        self.assertIn('setup-recorder-app.sh', result['reason'])

    def test_the_recorder_is_given_the_app(self):
        recorder = FakeRecorder([0.0] * 16000)
        self.window(lambda: FAKE_APP, recorder=recorder)
        self.assertEqual(recorder.app, FAKE_APP)

    def test_silence_through_the_app_is_still_unavailable_and_says_why(self):
        result = self.window(lambda: FAKE_APP, recorder=FakeRecorder([0.0] * 16000 * 5))
        self.assertEqual(result['verdict'], 'UNAVAILABLE', 'no pilot heard: never PASS or FAIL')
        self.assertIn('Microphone access', result['reason'])

    def test_a_refused_microphone_is_unavailable(self):
        recorder = FakeRecorder(TONE, status=1)
        recorder.lines = ['loopback: Microphone access for this app is denied: run setup-recorder-app.sh']
        result = self.window(lambda: FAKE_APP, recorder=recorder)
        self.assertEqual(result['verdict'], 'UNAVAILABLE')
        self.assertIn('Microphone access for this app is denied', result['reason'])

    def test_a_stale_app_is_named_when_it_couldnt_listen(self):
        result = self.window(lambda: FAKE_APP, recorder=FakeRecorder([0.0] * 16000 * 5))
        self.assertIn('older loopback.swift', result['reason'], 'FAKE_APP has no build hash, so it counts as stale')

    def test_the_route_wraps_the_app_and_brings_the_recording_back(self):
        wav = Path('/evidence/w1.wav')
        command = window.recorder_command('/bin/loopback', FAKE_APP, wav, 6.7, python='/py')
        self.assertEqual(command[:5], ['/bin/loopback', 'route', '--to', 'BlackHole 2ch', '--'])
        rest = command[5:]
        self.assertEqual(rest[:3], ['/py', str(HERE / 'loopback.py'), 'app-run'])
        self.assertEqual(rest[rest.index('--app') + 1], str(FAKE_APP))
        self.assertIn('recording.wav=/evidence/w1.wav', rest)
        self.assertIn('stderr=/evidence/w1.recorder.log', rest)
        record = rest[rest.index('--', 3) + 1:]
        self.assertEqual(record, ['record', '--device', 'BlackHole 2ch', '--seconds', '6.7', '--out',
                                  '{job}/recording.wav'])

    def test_a_recorder_that_ends_without_recording_is_read_at_once(self):
        recorder = window.Recorder(Path('/tmp/x.wav'), 5, FAKE_APP, binary='/bin/loopback')
        recorder.command = [sys.executable, '-c', 'import sys; print("loopback: Microphone denied", file=sys.stderr);'
                            ' sys.exit(1)']
        recorder.start()
        self.assertTrue(recorder.started.wait(10), 'EOF ends the wait, not START_TIMEOUT')
        self.assertEqual(recorder.wait(10), 1)
        recorder.process.stderr.close()


@unittest.skipUnless(sys.platform == 'darwin' and shutil.which('swiftc') and shutil.which('codesign'),
                     'builds a macOS app')
class BuildTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.folder = Path(tempfile.mkdtemp())
        cls.app = cls.folder / 'SpokenMarginsLaneRecorder.app'
        subprocess.run([str(HERE / 'build-app.sh'), str(cls.app)], check=True, capture_output=True, timeout=600)
        cls.info = plistlib.loads((cls.app / 'Contents/Info.plist').read_bytes())

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.folder, ignore_errors=True)

    def test_the_bundle_has_its_executable_and_stable_identity(self):
        self.assertTrue((self.app / 'Contents/MacOS' / loopback.APP_NAME).exists())
        self.assertEqual(self.info['CFBundleExecutable'], loopback.APP_NAME)
        self.assertEqual(self.info['CFBundleIdentifier'], 'com.spokenmargins.ops.lane-recorder')
        self.assertEqual(self.info['CFBundlePackageType'], 'APPL')
        self.assertTrue(self.info['LSUIElement'], 'no Dock icon while the lane uses it')

    def test_both_usage_texts_are_there_in_plain_words(self):
        for key in ('NSMicrophoneUsageDescription', 'NSSpeechRecognitionUsageDescription'):
            self.assertGreater(len(self.info.get(key, '')), 40, key)
        self.assertIn('BlackHole', self.info['NSMicrophoneUsageDescription'])

    def test_it_is_signed_with_the_audio_input_entitlement(self):
        shown = subprocess.run(['codesign', '-d', '--entitlements', '-', '--xml', str(self.app)],
                               capture_output=True, timeout=60)
        self.assertIn(b'com.apple.security.device.audio-input', shown.stdout + shown.stderr)
        details = subprocess.run(['codesign', '-dv', str(self.app)], capture_output=True, text=True, timeout=60)
        self.assertIn('Identifier=com.spokenmargins.ops.lane-recorder', details.stderr)

    def test_it_records_the_source_it_was_built_from(self):
        self.assertEqual(self.info['SMLoopbackSourceSHA256'],
                         hashlib.sha256((HERE / 'loopback.swift').read_bytes()).hexdigest())
        self.assertFalse(loopback.app_is_stale(self.app))

    def test_job_mode_puts_output_and_exit_status_in_files(self):
        """Run directly, not through open: the job files are the same, and nothing asks for a permission."""
        job = Path(tempfile.mkdtemp())
        executable = self.app / 'Contents/MacOS' / loopback.APP_NAME
        done = subprocess.run([str(executable), '-psn_0_12345', '--job', str(job), 'devices', '--json'],
                              capture_output=True, text=True, timeout=60)
        self.assertEqual((done.returncode, done.stdout), (0, ''), 'nothing on the real stdout in job mode')
        self.assertIsInstance(json.loads((job / 'stdout').read_text()), list)
        self.assertEqual((job / 'status').read_text().strip(), '0')
        bad = subprocess.run([str(executable), '--job', str(job), 'no-such-command'], capture_output=True, timeout=60)
        self.assertEqual(bad.returncode, 2)
        self.assertEqual((job / 'status').read_text().strip(), '2')
        self.assertIn('usage', (job / 'stderr').read_text())


if __name__ == '__main__':
    unittest.main()
