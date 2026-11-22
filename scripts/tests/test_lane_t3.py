"""The T3 machinery in scripts/lane_t3.py: process limits, the shared build, the simulator claim and boot
rules, the verdict, fresh-clone and overload reruns, and the retry-pass tally. scripts/main_t3.py runs it
on main (#4573). Moved out of test_lane_runner.py with the code (#4769)."""
import os

os.environ.pop('SM_TRUNK', None)
os.environ.pop('GITHUB_EVENT_NAME', None)

import contextlib
import datetime
import importlib.util
import json
import shutil
import signal
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
sys.path.insert(0, str(SCRIPTS / 'tests'))

spec = importlib.util.spec_from_file_location('lane_t3', SCRIPTS / 'lane_t3.py')
lane = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lane)

HEAD = 'a' * 40


def comment(body, login='uncomposed', url='https://example.test/c'):
    return {'body': body, 'user': {'login': login}, 'html_url': url}


class FakeGitHub:
    def __init__(self, labels=('lane:queued',), head=HEAD, comments=(), fail_comment=False):
        self.labels, self.head, self._comments = set(labels), head, list(comments)
        self.posted, self.label_changes, self.fail_comment = [], [], fail_comment
        self.labeled = []  # GitHub's `labeled` events: none when the label was already there

    def pull(self):
        return {'head': {'sha': self.head}, 'labels': [{'name': n} for n in sorted(self.labels)]}

    def comments(self):
        return list(self._comments)

    def comment(self, body):
        if self.fail_comment and body.startswith('Lane report'):
            raise RuntimeError('GitHub API unavailable')
        self.posted.append(body)
        self._comments.append(comment(body, login='github-actions[bot]', url=f'https://example.test/{len(self.posted)}'))
        return self._comments[-1]['html_url']

    repo = 'o/r'

    def api(self, path):
        # No check runs on any head: the fast checks off the Mac (#2160) never stand, so the whole --plan fast runs.
        return json.dumps({'check_runs': []})

    def relabel(self, remove, add):
        self.label_changes.append((remove, add))
        self.labels.discard(remove)
        if add and add not in self.labels:
            self.labeled.append(add)
        if add:
            self.labels.add(add)


FAKE_VERIFY_TESTS = r"""
import json, os, sys, time
from pathlib import Path

# Stands in for scripts/verify-tests.py inside a temporary lane ROOT: records how it was launched, then does
# what scripts/fake-verify-behavior.json says (the test writes that file before each run).
here = Path(__file__).resolve().parent
behavior = json.loads((here / 'fake-verify-behavior.json').read_text())
with (here / 'fake-verify-launches.jsonl').open('a') as record:
    record.write(json.dumps({'argv': sys.argv[1:], 'cwd': os.getcwd()}) + '\n')
output = Path(sys.argv[sys.argv.index('--output') + 1])
output.mkdir(parents=True, exist_ok=True)
if behavior.get('manifest') is not None:
    (output / 'manifest.json').write_text(json.dumps(behavior['manifest']))
if behavior.get('sleep'):
    time.sleep(behavior['sleep'])
"""


def stalled_step(recovered=True, stalls=1, errors=(), tests=3):
    """An xcode-tests step as verify-tests.py records it after a startup stall."""
    step = {'name': 'xcode-tests', 'exit_code': 0, 'errors': list(errors), 'startup_attempts': stalls + 1,
            'startup_stalls': [{'attempt': n, 'after_seconds': 90.2, 'last_log_line': 'Writing result bundle at path:'}
                               for n in range(1, stalls + 1)],
            'tests': {f'T/A/test{n}': {'status': 'passed'} for n in range(tests)}}
    if recovered:
        step['startup_recovered'] = True
    return step


def stalled_out_manifest():
    """A verify-tests.py manifest whose xcode-tests step stalled at both launches (no test ran)."""
    return {'status': 'failed_or_incomplete', 'error': 'xcode-tests: Test runner printed no test output in 2 launch(es)',
            'steps': [{'name': 'xcode-tests', 'exit_code': 124, 'tests': {}, 'startup_attempts': 2,
                       'errors': ['Test runner printed no test output in 2 launch(es) of 90s'],
                       'startup_stalls': [{'attempt': n, 'after_seconds': 90.1, 'diagnosis': 'no host app process'}
                                          for n in (1, 2)]}]}


def passing_manifest(test='T/A'):
    return {'status': 'verified', 'steps': [{'name': 'xcode-tests', 'exit_code': 0, 'errors': [],
                                              'tests': {test: {'status': 'passed'}}}]}


def overloaded_manifest(load=293.6, tests=38):
    """#3374: pr3348-r41915797884, an xcode-tests step that ran out of its budget at load average 293.6."""
    return {'status': 'failed_or_incomplete', 'error': 'xcode-tests: Process exit 124',
            'steps': [{'name': 'xcode-tests', 'exit_code': 124, 'interrupted': True, 'timeout_seconds': 300,
                       'load_average_start': [120.0, 90.0, 60.0], 'load_average_end': [load, 200.0, 100.0],
                       'tests': {f'T/A/test{n}': {'status': 'passed'} for n in range(tests)},
                       'errors': ['Process exit 124', 'Could not reconcile xcresult individual tests: exit status 64']}]}


class ProcessTests(unittest.TestCase):
    """Timeouts stop the whole group, so no xcodebuild keeps running outside the build slots."""

    # The child needs time to start Python and install its signal handling before the timeout fires.
    # At a load average near 400 (two simulators, full swap) that took more than the 0.5 s these tests
    # once allowed, so the interrupt arrived first and the child died without a trace (#249). Children
    # start with -S (no site import) and report when they're ready; a child that still isn't ready
    # when the timeout fires means the Mac was too overloaded to test this, and the test says so.
    STARTUP = 5.0

    def ready_or_skip(self, text):
        if 'ready' not in text:
            self.skipTest(f'the child did not start within {self.STARTUP:.0f} s; the Mac is too overloaded to test this')

    def test_a_timeout_interrupts_the_group_so_the_child_can_record_it(self):
        with tempfile.TemporaryDirectory() as temporary, open(Path(temporary) / 'log', 'w+') as log:
            script = ('import signal, sys, time\n'
                      'def stop(*_):\n    print("interrupted, stopping xcodebuild", flush=True); sys.exit(130)\n'
                      'signal.signal(signal.SIGINT, stop)\nprint("ready", flush=True)\ntime.sleep(60)\n')
            self.assertIsNone(lane.run_bounded([sys.executable, '-S', '-c', script], log, timeout=self.STARTUP, grace=60))
            log.seek(0)
            text = log.read()
            self.ready_or_skip(text)
            # The handler's line proves the SIGINT path (a SIGKILL leaves no line). No time bound: on a Mac
            # with swap nearly full, the child can take many seconds to run its handler (#184).
            self.assertIn('interrupted, stopping xcodebuild', text)

    def test_the_interrupt_works_even_if_the_runner_was_started_ignoring_it(self):
        # Background jobs start with SIGINT ignored, and children inherit that. A child relying on
        # Python's default handling must still be interrupted, not survive until SIGKILL.
        with tempfile.TemporaryDirectory() as temporary, open(Path(temporary) / 'log', 'w+') as log:
            script = 'import time\nprint("ready", flush=True)\ntime.sleep(60)\n'
            previous = signal.signal(signal.SIGINT, signal.SIG_IGN)
            try:
                self.assertIsNone(lane.run_bounded([sys.executable, '-S', '-c', script], log, timeout=self.STARTUP,
                                                   grace=60))
            finally:
                signal.signal(signal.SIGINT, previous)
            log.seek(0)
            text = log.read()
            self.ready_or_skip(text)
            self.assertIn('KeyboardInterrupt', text)  # default handling reached the child; a SIGKILL leaves no trace

    def test_the_prs_code_cannot_set_the_jobs_verdict(self):
        # In a T3 job, the automerge run a T3 PASS releases runs --plan fast after the T3's verdict is
        # recorded. Its runner-tests call main() and appended their own verdicts to the inherited
        # GITHUB_OUTPUT, so lane jobs that passed and merged showed INCONCLUSIVE (#564, #573 on 10-04).
        with tempfile.TemporaryDirectory() as temporary:
            outputs = Path(temporary) / 'outputs'
            outputs.write_text('reported=true\nverdict=PASS\n')
            script = ('import os\npath = os.environ.get("GITHUB_OUTPUT")\n'
                      'if path: open(path, "a").write("verdict=INCONCLUSIVE\\n")\n')
            with mock.patch.dict('os.environ', {'GITHUB_OUTPUT': str(outputs), 'GITHUB_STEP_SUMMARY': str(outputs)}), \
                    open(Path(temporary) / 'log', 'w+') as log:
                self.assertEqual(lane.run_bounded([sys.executable, '-S', '-c', script], log, timeout=60), 0)
                self.assertNotIn('GITHUB_OUTPUT', lane.pr_code_env())
                self.assertNotIn('GITHUB_STEP_SUMMARY', lane.pr_code_env())
            self.assertEqual(outputs.read_text(), 'reported=true\nverdict=PASS\n')

    def test_a_group_that_ignores_the_interrupt_is_killed_with_its_children(self):
        with tempfile.TemporaryDirectory() as temporary, open(Path(temporary) / 'log', 'w+') as log:
            pid_file = Path(temporary) / 'child.pid'
            script = ('import signal, subprocess, sys, time\nsignal.signal(signal.SIGINT, signal.SIG_IGN)\n'
                      'child = subprocess.Popen([sys.executable, "-S", "-c", "import signal, time; '
                      'signal.signal(signal.SIGINT, signal.SIG_IGN); time.sleep(120)"])\n'
                      f'open({str(pid_file)!r}, "w").write(str(child.pid))\nprint("ready", flush=True)\ntime.sleep(120)\n')
            self.assertIsNone(lane.run_bounded([sys.executable, '-S', '-c', script], log, timeout=self.STARTUP, grace=0.5))
            log.seek(0)
            self.ready_or_skip(log.read())
            child = int(pid_file.read_text())
            for _ in range(100):
                try:
                    os.kill(child, 0)
                except ProcessLookupError:
                    break
                time.sleep(0.1)
            else:
                os.kill(child, signal.SIGKILL)
                self.fail('the grandchild outlived the timeout')


class T3Tests(unittest.TestCase):
    PLANS = {'app': {'SpokenMarginsAppTests/A/test1', 'SpokenMarginsAppTests/A/test2'},
             'adapters': {'SpokenMarginsAppTests/Audio/test1'}}

    def test_verdicts_separate_failures_from_lane_trouble(self):
        failing = lane.summarize_manifest({'status': 'failed_or_incomplete', 'steps': [
            {'name': 'xcode-tests', 'tests': {'A/test1': {'status': 'passed'}, 'A/test2': {'status': 'failed'}}}]})
        self.assertEqual((failing['passed'], failing['failed']), (1, ['A/test2']))
        self.assertEqual(lane.t3_verdict([failing], ['failed_or_incomplete']), 'FAIL')
        broken = lane.summarize_manifest({'steps': [{'name': 'build-for-testing', 'errors': ['Process exit 65']}]})
        self.assertEqual(lane.t3_verdict([broken], ['failed_or_incomplete']), 'FAIL')
        ran = lane.summarize_manifest({'steps': [{'name': 'xcode-tests', 'tests': {'A/test1': {'status': 'passed'}}}]})
        self.assertEqual(lane.t3_verdict([ran], ['verified']), 'PASS')

    def test_a_verified_plan_that_ran_no_requested_test_is_a_fail_not_a_pass(self):
        """#2596: SupertonicSpeechTests "ran" 0 tests in the adapters plan and a verified plan counted as a pass."""
        ran = {'status': 'verified', 'steps': [{'name': 'xcode-tests', 'tests': {'T/A/test1': {'status': 'passed'}}}]}
        nothing = {'status': 'verified', 'steps': [{'name': 'xcode-tests', 'tests': {}}]}
        for plans, verdict in (({'app': ran}, 'PASS'), ({'app': nothing}, 'FAIL'), ({'app': ran, 'adapters': nothing}, 'FAIL')):
            with self.subTest(plans=list(plans), verdict=verdict):
                grouped = {plan: ['T/A'] for plan in plans}
                summaries, statuses, _, details = lane.run_plans(grouped, lambda plan, *_: plans[plan], Path('/e'))
                self.assertEqual(lane.t3_verdict(summaries, statuses), verdict)
                self.assertEqual(any('ran 0 of the requested tests' in line for line in details), verdict == 'FAIL')
        # A plan that did not finish is the lane's trouble, not a verdict on the requested test.
        stopped = lane.summarize_manifest({'steps': []})
        self.assertEqual(lane.t3_verdict([stopped], ['failed_or_incomplete']), 'INCONCLUSIVE')

    def test_a_hosted_audio_loopback_class_that_could_not_listen_is_not_a_fail_or_an_inconclusive(self):
        """#3604: a hosted Mac has no BlackHole, so the AudioLoopback skip is recorded as not run; the rest decides."""
        ran = {'status': 'verified', 'steps': [{'name': 'xcode-tests', 'tests': {'T/A/test1': {'status': 'passed'}}}]}
        audio = 'T/AudioLoopbackPlaybackTests/testVoice'
        only_audio = {'status': 'verified', 'steps': [{'name': 'xcode-tests', 'audio_not_run': [audio],
                                                       'tests': {audio: {'status': 'skipped'}}}]}
        nothing = {'status': 'verified', 'steps': [{'name': 'xcode-tests', 'tests': {}}]}
        loopback, other = ['T/AudioLoopbackPlaybackTests'], ['T/A']
        # (plan: (manifest, the selectors it was asked for)), the verdict, whether the report says the audio check is owed
        for plans, verdict, owed in (
                ({'app': (ran, other), 'adapters': (only_audio, loopback)}, 'PASS', True),
                ({'adapters': (only_audio, loopback)}, 'INCONCLUSIVE', True),
                ({'app': (ran, other), 'adapters': (nothing, other)}, 'FAIL', False),
                # The audit on d223d47: another requested class in the same plan that ran nothing is still #2596's FAIL.
                ({'app': (ran, other), 'adapters': (only_audio, loopback + ['T/Foo'])}, 'FAIL', True),
                ({'adapters': (only_audio, loopback + ['T/Foo'])}, 'FAIL', True)):
            with self.subTest(plans=list(plans), verdict=verdict):
                grouped = {plan: selectors for plan, (_, selectors) in plans.items()}
                summaries, statuses, _, details = lane.run_plans(grouped, lambda plan, *_: plans[plan][0], Path('/e'))
                self.assertEqual(lane.t3_verdict(summaries, statuses), verdict)
                self.assertEqual(any('not run on the hosted Mac' in line and 'still owed' in line for line in details), owed)
                self.assertEqual(any('ran 0 of the requested tests' in line for line in details), verdict == 'FAIL')
                audio_only_plan = any(selectors == loopback for _, selectors in plans.values())
                self.assertEqual(any('only AudioLoopback tests were requested' in line for line in details), audio_only_plan)

    def test_an_interrupted_build_or_a_flood_is_inconclusive_not_a_failure(self):
        timed_out = lane.summarize_manifest({'steps': [{'name': 'build-for-testing', 'interrupted': True,
                                                        'errors': ['Process exit 124']}]})
        self.assertFalse(timed_out['build_failed'])
        self.assertEqual(lane.t3_verdict([timed_out], ['failed_or_incomplete']), 'INCONCLUSIVE')
        flood = lane.summarize_manifest({'steps': [{'name': 'xcode-tests', 'simulator_crash_report': 'x.ips',
                                                    'simulator_crash_reports': ['/r/x.ips'], 'interrupted': True}]})
        self.assertTrue(flood['flood'])
        self.assertEqual(lane.t3_verdict([flood], ['failed_or_incomplete']), 'INCONCLUSIVE')

    def test_a_report_names_the_budget_that_ran_out(self):
        manifest = {'status': 'failed_or_incomplete', 'steps': [
            {'name': 'simulator-ready', 'seconds': 0.2, 'timeout_seconds': 180},
            {'name': 'xcode-tests', 'seconds': 600.1, 'timeout_seconds': 600, 'interrupted': True,
             'tests': {f'T/A/test{n}': {'status': 'passed'} for n in range(7)}}]}
        summaries, statuses, _, details = lane.run_plans({'app': ['T/A']}, lambda *_: manifest, Path('/e'))
        self.assertEqual(summaries[0]['out_of_time'], ('xcode-tests', 600))
        self.assertIn('the test run ran out of its own 10m00s budget (verify-tests.py `xcode-tests`) after 7 passing '
                      'tests', details[0])
        self.assertIn("boot has a separate budget", details[0])
        self.assertEqual(lane.t3_verdict(summaries, statuses), 'INCONCLUSIVE')

    def test_a_python_traceback_puts_its_last_line_in_the_report(self):
        with tempfile.TemporaryDirectory() as folder:
            log = Path(folder) / 'verify-fast.log'
            log.write_text('Traceback (most recent call last):\n  File "verify-tests.py", line 425, in main\n'
                           '    run = Run(output.resolve(), args.plan)\n'
                           "FileExistsError: [Errno 17] File exists: '/e/pr5-r42/fast'\n")
            self.assertEqual(lane.first_errors(log), ["FileExistsError: [Errno 17] File exists: '/e/pr5-r42/fast'"])

    def test_a_step_that_stops_the_run_puts_its_first_errors_in_the_report(self):
        # #408 and #368: T3 reports said only "Process exit 70"; the log that says why stayed on the Mac.
        with tempfile.TemporaryDirectory() as folder:
            def run_plan(plan, selectors, output):
                output.mkdir(parents=True)
                (output / 'build-for-testing.log').write_text(
                    'Command line invocation: …\nxcodebuild: error: Unable to find a destination matching the '
                    'provided destination specifier:\n\t\t{ id:ABC }\n')
                return {'status': 'failed_or_incomplete', 'error': 'Process exit 70 (see build-for-testing.log)',
                        'steps': [{'name': 'generate', 'exit_code': 0, 'errors': []},
                                  {'name': 'build-for-testing', 'exit_code': 70, 'errors': ['Process exit 70']}]}

            _, _, _, details = lane.run_plans({'app': ['T/A']}, run_plan, Path(folder))
        self.assertIn('app: xcodebuild: error: Unable to find a destination matching the provided destination '
                      'specifier:', details)

    def test_the_reported_boot_time_is_the_boot_alone(self):
        # #248's reports said "first boot took 17m57s" while the boot took about 4.5 min: the clock was read
        # after the tests. Here the boot takes 65 s of fake time and the tests another 900.
        now = [0.0]
        fake_time = mock.Mock(monotonic=lambda: now[0])

        def boot(*_):
            now[0] += 65
            return None, {'pressure': 'warn', 'pressure_waited': 600}

        def tests(*_):
            now[0] += 900
            return [lane.summarize_manifest({'steps': [{'name': 'xcode-tests', 'tests': {'T/A/test1': {'status': 'passed'}}}]})], ['verified'], ['A (1 passed)'], []

        import lane_sim
        with mock.patch.object(lane, 'time', fake_time), \
                mock.patch.object(lane_sim, 'clone_temporary', return_value='U'), \
                mock.patch.object(lane_sim, 'start_watcher'), mock.patch.object(lane_sim, 'release'), \
                mock.patch.object(lane_sim, 'unsafe_devices', return_value={}), \
                mock.patch.object(lane, 'boot_t3_device', side_effect=boot), \
                mock.patch.object(lane, 'run_plans', side_effect=tests), \
                tempfile.TemporaryDirectory() as temporary:
            verdict, _, _, details, _, _ = lane._t3_on_fresh_device({'app': ['T/A']}, 'r', Path(temporary),
                                                                     'com.apple.CoreSimulator.SimRuntime.iOS-26-5')
        self.assertEqual((verdict, details[0]), ('PASS', 'boot of the cloned simulator took 1m05s (memory pressure '
                                                         'at boot: warn, after waiting 600s; one-simulator period)'))

    def test_a_tolerated_change_and_a_late_crash_report_are_reported_without_changing_the_verdict(self):
        import lane_sim
        with mock.patch.object(lane_sim, 'clone_temporary', return_value='U'), \
                mock.patch.object(lane_sim, 'start_watcher'), mock.patch.object(lane_sim, 'release'), \
                mock.patch.object(lane_sim, 'unsafe_devices', return_value={'U': {
                    'reason': 'late crash report for a crash during boot: SpringBoard-x.ips'}}), \
                mock.patch.object(lane, 'boot_t3_device', return_value=(None, {
                    'pressure': 'normal', 'pressure_waited': 0, 'tolerated': 'SpringBoard restarted (pid 1 -> 2)',
                    'boot_window': (0.0, 1.0)})), \
                mock.patch.object(lane, 'run_plans', return_value=([lane.summarize_manifest({'steps': [{'name': 'xcode-tests', 'tests': {'T/A/test1': {'status': 'passed'}}}]})], ['verified'],
                                                                   ['A (1 passed)'], [])), \
                tempfile.TemporaryDirectory() as temporary:
            verdict, _, _, details, crashes, cc = lane._t3_on_fresh_device(
                {'app': ['T/A']}, 'r', Path(temporary), 'com.apple.CoreSimulator.SimRuntime.iOS-26-5')
        self.assertEqual((verdict, cc), ('PASS', ''))
        self.assertIn("tolerated one SpringBoard change in the first 30 s of the first boot (owner's rule, #184)", details[1])
        self.assertTrue(any('marked unsafe and deleted' in line for line in details))
        self.assertEqual(crashes, 'none')

    def test_the_report_names_the_phone_and_runtime_the_clone_used(self):
        # Not a fixed "iPhone 17": the hosted image's runtime can take a different phone (#2557).
        import lane_sim
        with mock.patch.object(lane_sim, 'device_type', return_value='com.apple.CoreSimulator.SimDeviceType.iPhone-18'):
            _, where, *_ = self._t3_with((None, {'pressure': 'normal', 'pressure_waited': 0, 'boot_window': (0.0, 1.0)}),
                                         ([lane.summarize_manifest({'steps': []})], ['verified'], ['A (1 passed)'], []),
                                         mock.Mock(return_value=False))
        self.assertEqual(where, 'cloned iPhone 18, iOS 26.5')

    def _t3_with(self, boot, plans, back_to_one):
        import lane_sim
        with mock.patch.object(lane_sim, 'clone_temporary', return_value='U'), \
                mock.patch.object(lane_sim, 'start_watcher'), mock.patch.object(lane_sim, 'release'), \
                mock.patch.object(lane_sim, 'unsafe_devices', return_value={}), \
                mock.patch.object(lane_sim, 'back_to_one_simulator', back_to_one), \
                mock.patch.object(lane, 'boot_t3_device', return_value=boot), \
                mock.patch.object(lane, 'run_plans', return_value=plans), \
                tempfile.TemporaryDirectory() as temporary:
            return lane._t3_on_fresh_device({'app': ['T/A']}, 'r7', Path(temporary),
                                            'com.apple.CoreSimulator.SimRuntime.iOS-26-5')

    def test_a_two_simulator_run_that_times_out_puts_the_lane_back_to_one_simulator(self):
        # The lead's brake (#184): any two-simulator run INCONCLUSIVE from a timeout means back to one.
        out_of_time = lane.summarize_manifest({'steps': [{'name': 'xcode-tests', 'seconds': 600.1,
                                                          'timeout_seconds': 600, 'interrupted': True}]})
        for period, expected in (('two-simulator', 1), ('one-simulator', 0)):
            with self.subTest(period=period):
                back_to_one = mock.Mock(return_value=True)
                plans = ([out_of_time], ['failed_or_incomplete'], ['A (0 passed)'], [])
                verdict, _, _, details, _, _ = self._t3_with((None, {'pressure': 'normal', 'period': period}), plans,
                                                             back_to_one)
                self.assertEqual(verdict, 'INCONCLUSIVE')
                self.assertEqual(back_to_one.call_count, expected)
                self.assertIn(f'{period} period', details[0])
                self.assertEqual(any('back to one simulator' in line for line in details), bool(expected))
        passing = ([lane.summarize_manifest({'steps': [{'name': 'xcode-tests', 'tests': {'T/A/test1': {'status': 'passed'}}}]})], ['verified'], ['A (1 passed)'], [])
        back_to_one = mock.Mock(return_value=True)
        self.assertEqual(self._t3_with((None, {'period': 'two-simulator'}), passing, back_to_one)[0], 'PASS')
        back_to_one.assert_not_called()

    def test_a_two_simulator_boot_that_times_out_puts_the_lane_back_to_one_simulator(self):
        for problem, expected in (('not ready after 900s; shut down (not marked unsafe).', 1),
                                  ('SpringBoard restarted twice during boot', 0)):
            with self.subTest(problem=problem):
                back_to_one = mock.Mock(return_value=True)
                verdict = self._t3_with((problem, {'period': 'two-simulator'}), None, back_to_one)[0]
                self.assertEqual((verdict, back_to_one.call_count), ('INCONCLUSIVE', expected))

    def test_t3_failure_report_links_exported_manifest_and_media(self):
        manifest = {'status': 'failed_or_incomplete', 'steps': [{
            'tests': {'T/A/testBad': {'status': 'failed'}},
            'attachments': [{'test': 'T/A/testBad', 'manifest': '/mac/manifest.json',
                             'files': ['/mac/recording.mp4']}]}]}
        summaries, statuses, _, details = lane.run_plans(
            {'app': ['T/A']}, lambda *args: manifest, Path('/mac/run'))
        self.assertEqual(lane.t3_verdict(summaries, statuses), 'FAIL')
        self.assertIn('- [Attachment manifest](</mac/manifest.json>)', details)
        self.assertIn('- [recording.mp4](</mac/recording.mp4>)', details)

    def test_a_flood_stops_the_remaining_plans(self):
        calls = []

        def run_plan(plan, selectors, output):
            calls.append(plan)
            return {'status': 'failed_or_incomplete', 'steps': [
                {'name': 'xcode-tests', 'simulator_crash_report': 'x.ips', 'simulator_crash_reports': ['/r/x.ips']}]}

        summaries, statuses, _, details = lane.run_plans({'app': ['T/A'], 'adapters': ['T/B']}, run_plan, Path('/e'))
        self.assertEqual(calls, ['app'])
        self.assertIn('not run', statuses)
        self.assertTrue(any('not run: adapters' in line for line in details))
        self.assertEqual(lane.t3_verdict(summaries, statuses), 'INCONCLUSIVE')


class T3VerifyTestsLaunchTests(unittest.TestCase):
    """The command the T3 job runs on the simulator it claimed (`run_plan` in `_t3_on_claimed_device`), and what
    it makes of what comes back. Every other T3 test hands `run_plans` a fake `run_plan`, so the closure that
    decides which simulator, which tests and which verdict was never executed: the real child process runs here
    (a Python stand-in for verify-tests.py in a temporary ROOT); only the simulator calls are replaced."""

    UDID = 'CLAIMED-0000-UDID'
    RUNTIME = 'com.apple.CoreSimulator.SimRuntime.iOS-26-5'

    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name) / 'checkout'
        (self.root / 'scripts').mkdir(parents=True)
        (self.root / 'scripts/verify-tests.py').write_text(FAKE_VERIFY_TESTS)
        self.evidence = Path(temporary.name) / 'evidence'
        self.evidence.mkdir()
        patcher = mock.patch.dict(os.environ, {'SM_LANE_STATE_DIR': str(Path(temporary.name) / 'state')})
        patcher.start()
        self.addCleanup(patcher.stop)

    def behave(self, manifest=None, sleep=0):
        (self.root / 'scripts/fake-verify-behavior.json').write_text(json.dumps({'manifest': manifest, 'sleep': sleep}))

    def launches(self):
        log = self.root / 'scripts/fake-verify-launches.jsonl'
        return [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []

    def run_t3(self, grouped, timeout=None):
        import lane_sim
        patches = [mock.patch.object(lane, 'ROOT', self.root),
                   mock.patch.object(lane_sim, 'clone_temporary', return_value=self.UDID),
                   mock.patch.object(lane_sim, 'start_watcher'), mock.patch.object(lane_sim, 'release'),
                   mock.patch.object(lane_sim, 'unsafe_devices', return_value={}),
                   mock.patch.object(lane_sim, 'is_available', return_value=True),
                   mock.patch.object(lane_sim, 'back_to_one_simulator', return_value=False),
                   mock.patch.object(lane, 'boot_t3_device', return_value=(None, {'pressure': 'normal',
                                                                                'period': 'one-simulator'}))]
        if timeout is not None:
            patches.append(mock.patch.object(lane, 'T3_TIMEOUT', timeout))
        with contextlib.ExitStack() as stack:
            for patch in patches:
                stack.enter_context(patch)
            return lane._t3_on_fresh_device(grouped, 'r7', self.evidence, self.RUNTIME)

    def test_each_plan_runs_verify_tests_on_the_claimed_simulator_with_exactly_its_selectors(self):
        self.behave({'status': 'verified', 'steps': [{'name': 'xcode-tests', 'tests': {'T/A/test1': {'status': 'passed'}}}]})
        verdict, _, _, _, _, _ = self.run_t3({'app': ['AppTests/AlphaTests', 'AppTests/BetaTests/testOne'],
                                              'adapters': ['AudioTests/GammaTests']})
        self.assertEqual(verdict, 'PASS')
        self.assertEqual([launch['argv'] for launch in self.launches()], [
            ['--plan', 'app', '--device', self.UDID, '--require-build', '--output', str(self.evidence / 'verify-app'),
             '--only-testing', 'AppTests/AlphaTests', '--only-testing', 'AppTests/BetaTests/testOne'],
            ['--plan', 'adapters', '--device', self.UDID, '--require-build', '--output', str(self.evidence / 'verify-adapters'),
             '--only-testing', 'AudioTests/GammaTests']])
        # `scripts/verify-tests.py` is a relative path, so the child must start in the checkout
        self.assertEqual({launch['cwd'] for launch in self.launches()}, {str(self.root.resolve())})

    def test_a_run_that_wrote_no_manifest_is_not_a_pass(self):
        self.behave(manifest=None)
        verdict, _, _, details, _, _ = self.run_t3({'app': ['AppTests/AlphaTests']})
        self.assertEqual(len(self.launches()), 1)  # it did run: the verdict is about what it left behind
        self.assertEqual(verdict, 'INCONCLUSIVE')
        self.assertTrue(any(line.startswith('app: verify-tests.py wrote no manifest.') for line in details), details)

    def test_the_manifest_status_decides_the_verdict(self):
        failed = {'status': 'failed_or_incomplete', 'steps': [{'name': 'xcode-tests', 'exit_code': 65, 'tests': {
            'AppTests/AlphaTests/testBad': {'status': 'failed'}}}]}
        for manifest, expected in (({'status': 'verified', 'steps': [{'name': 'xcode-tests', 'tests': {'T/A/test1': {'status': 'passed'}}}]}, 'PASS'), (failed, 'FAIL')):
            with self.subTest(status=manifest['status']):
                self.behave(manifest)
                self.assertEqual(self.run_t3({'app': ['AppTests/AlphaTests']})[0], expected)

    def test_a_run_that_outlasts_the_budget_is_interrupted_and_reported_as_timed_out(self):
        self.behave(manifest=None, sleep=60)
        started = time.monotonic()
        verdict, _, _, details, _, _ = self.run_t3({'app': ['AppTests/AlphaTests']}, timeout=1)
        self.assertLess(time.monotonic() - started, 30)  # interrupted at the budget, not after the child's sleep
        self.assertEqual(verdict, 'INCONCLUSIVE')
        self.assertTrue(any("the runner's 1s budget for the whole verify-tests.py run" in line for line in details), details)
        self.assertFalse(any('wrote no manifest' in line for line in details), details)


class T3PreparationTests(unittest.TestCase):
    def test_build_finishes_before_the_simulator_slot_is_taken(self):
        import lane_sim
        import lane_slots
        events = []
        with tempfile.TemporaryDirectory() as temporary, \
                mock.patch.object(lane_sim, 'newest_runtime', return_value='runtime'), \
                mock.patch.object(lane, 'prepare_t3_build',
                                  side_effect=lambda *a: events.append('build') or ('PASS', ['prepared'])), \
                mock.patch.object(lane_slots, 'acquire_simulator_slot',
                                  side_effect=lambda *a, **kw: events.append('slot') or 'slot'), \
                mock.patch.object(lane_slots, 'release_handle', side_effect=lambda *a: events.append('release')), \
                mock.patch.object(lane, '_t3_on_fresh_device',
                                  side_effect=lambda *a: events.append('clone/boot/tests') or
                                  ('PASS', 'clone', 'ran', [], 'none', '')):
            result = lane._run_t3_grouped({'app': ['T/A'], 'adapters': ['T/B']}, 'r', Path(temporary))
        self.assertEqual(events, ['build', 'slot', 'clone/boot/tests', 'release'])
        self.assertEqual(result[3], ['prepared'])

    def test_a_failed_or_timed_out_build_does_not_take_a_simulator_slot(self):
        import lane_sim
        import lane_slots
        for verdict in ('FAIL', 'INCONCLUSIVE'):
            with self.subTest(verdict=verdict), tempfile.TemporaryDirectory() as temporary, \
                    mock.patch.object(lane_sim, 'newest_runtime', return_value='runtime'), \
                    mock.patch.object(lane, 'prepare_t3_build', return_value=(verdict, ['failed'])), \
                    mock.patch.object(lane_slots, 'acquire_simulator_slot') as slot, \
                    mock.patch.object(lane_sim, 'clone_temporary') as clone:
                self.assertEqual(lane._run_t3_grouped({'app': ['T/A']}, 'r', Path(temporary))[0], verdict)
                slot.assert_not_called()
                clone.assert_not_called()

    def test_both_plans_launch_one_shared_generic_build(self):
        with tempfile.TemporaryDirectory() as temporary:
            evidence = Path(temporary)
            commands = []

            def run(command, log, timeout):
                commands.append(command)
                output = evidence / 'verify-build'
                output.mkdir()
                (output / 'manifest.json').write_text(json.dumps({'status': 'verified', 'steps': [{'name': 'xcode-tests', 'tests': {'T/A/test1': {'status': 'passed'}}}]}))
                return 0

            with mock.patch.object(lane, 'run_bounded', side_effect=run):
                result = lane.prepare_t3_build({'app': ['T/A'], 'adapters': ['T/B']}, 'runtime', evidence)
            self.assertEqual(result[0], 'PASS')
            self.assertEqual(len(commands), 1)
            self.assertIn('--build-only', commands[0])
            self.assertIn('runtime', commands[0])
            self.assertNotIn('--device', commands[0])

    def test_a_clone_boot_gets_the_first_boot_tolerance_because_the_clone_never_booted(self):
        """#1359: with first_boot=False every cloned T3 boot stopped on SpringBoard's early change."""
        import lane_sim
        with mock.patch.object(lane_sim, 'boot') as boot:
            self.assertIsNone(lane.boot_t3_device('clone', None)[0])
        self.assertTrue(boot.call_args.kwargs['first_boot'])


class LostDeviceTests(unittest.TestCase):
    """#440: after the app plan's readiness step failed (exit 148), the adapters plan ran anyway and found no
    simulator. #411: a device gone mid-build made xcodebuild exit 70, which read as a build FAIL."""

    @staticmethod
    def plans(first):
        calls = []

        def run_plan(plan, selectors, output):
            calls.append(plan)
            return first if plan == 'app' else {'status': 'verified', 'steps': [{'name': 'xcode-tests', 'tests': {'T/A/test1': {'status': 'passed'}}}]}
        return calls, run_plan

    def test_a_failed_readiness_step_stops_the_remaining_plans_with_one_inconclusive(self):
        calls, run_plan = self.plans({'status': 'failed_or_incomplete', 'error': 'simulator-ready: Process exit 148',
                                      'steps': [{'name': 'build-for-testing', 'exit_code': 0},
                                                {'name': 'simulator-ready', 'exit_code': 148, 'errors': ['Process exit 148']}]})
        summaries, statuses, _, details = lane.run_plans({'app': ['T/A'], 'adapters': ['T/B']}, run_plan, Path('/e'))
        self.assertEqual(calls, ['app'])
        self.assertIn('not run', statuses)
        self.assertTrue(any('not ready (verify-tests.py `simulator-ready`)' in line and 'not run: adapters' in line
                            for line in details))
        self.assertEqual(lane.t3_verdict(summaries, statuses), 'INCONCLUSIVE')

    def test_a_readiness_step_that_runs_out_of_time_also_stops_the_remaining_plans(self):
        calls, run_plan = self.plans({'status': 'failed_or_incomplete', 'steps': [
            {'name': 'simulator-ready', 'exit_code': 124, 'interrupted': True, 'timeout_seconds': 180}]})
        summaries, statuses, _, _ = lane.run_plans({'app': ['T/A'], 'adapters': ['T/B']}, run_plan, Path('/e'))
        self.assertEqual((calls, lane.t3_verdict(summaries, statuses)), (['app'], 'INCONCLUSIVE'))

    def test_a_device_gone_mid_build_is_the_lane_s_fault_not_a_build_failure(self):
        calls, run_plan = self.plans({'status': 'failed_or_incomplete', 'error': 'Process exit 70',
                                      'steps': [{'name': 'build-for-testing', 'exit_code': 70, 'errors': ['Process exit 70']}]})
        summaries, statuses, _, details = lane.run_plans({'app': ['T/A'], 'adapters': ['T/B']}, run_plan, Path('/e'),
                                                          lambda: False)
        self.assertEqual(calls, ['app'])
        self.assertTrue(any('the fresh simulator is gone' in line for line in details))
        self.assertEqual(lane.t3_verdict(summaries, statuses), 'INCONCLUSIVE')

    def test_a_real_build_failure_with_the_device_still_there_stays_a_fail(self):
        calls, run_plan = self.plans({'status': 'failed_or_incomplete', 'error': 'Process exit 65',
                                      'steps': [{'name': 'build-for-testing', 'exit_code': 65, 'errors': ['Process exit 65']}]})
        summaries, statuses, _, _ = lane.run_plans({'app': ['T/A'], 'adapters': ['T/B']}, run_plan, Path('/e'),
                                                    lambda: True)
        self.assertEqual(calls, ['app', 'adapters'])
        self.assertEqual(lane.t3_verdict(summaries, statuses), 'FAIL')

    def test_simctl_s_reason_reaches_the_report(self):
        with tempfile.TemporaryDirectory() as folder:
            log = Path(folder) / 'simulator-ready.log'
            log.write_text('An error was encountered processing the command (domain=com.apple.CoreSimulator.SimError, '
                           'code=404):\nInvalid device: 1234\n')
            self.assertEqual(lane.first_errors(log), [
                'An error was encountered processing the command (domain=com.apple.CoreSimulator.SimError, code=404):',
                'Invalid device: 1234'])


class RecoveredStallTests(unittest.TestCase):
    """Owner's call 2026-10-11: one startup stall recovered on the first retry, every test then passing, is a PASS."""

    def plan(self, step, status='verified'):
        manifest = {'status': status, 'steps': [{'name': 'build-for-testing', 'exit_code': 0, 'errors': []}, step]}
        summaries, statuses, _, details = lane.run_plans({'app': ['T/A']}, lambda *_: manifest, Path('/e'))
        return lane.t3_verdict(summaries, statuses), details

    def test_one_stall_recovered_on_the_first_retry_is_a_pass_the_report_says_so(self):
        verdict, details = self.plan(stalled_step())
        self.assertEqual(verdict, 'PASS')
        self.assertEqual(len(details), 2)  # the stall note, then the always-present retry line (#2596)
        self.assertEqual(details[1], 'app: passed on retry: none')
        self.assertIn('app: recovered after 1 startup stall', details[0])
        self.assertIn('passed 3 test(s)', details[0])
        self.assertIn('Logged on #1802', details[0])

    def test_two_stalls_before_a_pass_keep_their_verdict(self):
        # verify-tests.py leaves the step in error (and its status not verified) for two or more stalls.
        step = stalled_step(recovered=False, stalls=2, errors=['Recovered after 2 startup stall(s) of 90s; … not a PASS'])
        verdict, details = self.plan(step, status='failed_or_incomplete')
        self.assertEqual(verdict, 'INCONCLUSIVE')
        self.assertFalse(any('recovered after 1 startup stall' in line for line in details))
        self.assertEqual(lane.recovered_startup_stalls({'steps': [step]}), [])

    def test_a_stall_that_does_not_recover_keeps_its_verdict(self):
        step = {'name': 'xcode-tests', 'exit_code': 124, 'tests': {}, 'startup_attempts': 2,
                'errors': ['Test runner printed no test output in 2 launch(es) of 90s'],
                'startup_stalls': stalled_step(stalls=2)['startup_stalls']}
        verdict, _ = self.plan(step, status='failed_or_incomplete')
        self.assertEqual(verdict, 'INCONCLUSIVE')
        self.assertEqual(lane.recovered_startup_stalls({'steps': [step]}), [])

    def test_a_recovered_stall_with_a_failing_test_is_still_a_fail(self):
        step = stalled_step(errors=['Failed: T/A/test0'])
        step['tests']['T/A/test0']['status'] = 'failed'
        verdict, _ = self.plan(step, status='failed_or_incomplete')
        self.assertEqual(verdict, 'FAIL')
        self.assertEqual(lane.recovered_startup_stalls({'steps': [step]}), [])


class BootStallRetryTests(unittest.TestCase):
    """A T3 clone whose boot stalls gets one fresh clone; every stall is logged on #705 (owner's call 2026-10-11)."""

    def run_t3(self, stalls):
        import lane_sim
        clones, released = iter(['U1', 'U2']), []

        def boot(udid, label, **kw):
            kw['info'].update(pressure='normal', pressure_waited=0, boot_window=(0.0, 1.0))
            if udid in stalls:
                raise lane_sim.BootError(f'SpringBoard restarted (pid 1 -> 2) while booting {udid}.', stall=True)
            return 40.0

        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        evidence = Path(temporary.name)
        with mock.patch.object(lane_sim, 'clone_temporary', side_effect=lambda *a, **k: next(clones)), \
                mock.patch.object(lane_sim, 'boot', side_effect=boot), \
                mock.patch.object(lane_sim, 'start_watcher'), \
                mock.patch.object(lane_sim, 'release', side_effect=lambda udid, *a, **k: released.append(udid)), \
                mock.patch.object(lane_sim, 'unsafe_devices', return_value={}), \
                mock.patch.object(lane_sim, 'post_stall') as posted, \
                mock.patch.object(lane_sim, 'LATE_REPORT_WAIT', 0), \
                mock.patch.object(lane_sim, 'late_report', return_value=None), \
                mock.patch.object(lane, 'run_plans', return_value=([lane.summarize_manifest({'steps': [{'name': 'xcode-tests', 'tests': {'T/A/test1': {'status': 'passed'}}}]})],
                                                                   ['verified'], ['A (1 passed)'], [])):
            result = lane._t3_on_claimed_device({'app': ['T/A']}, 'r9', evidence,
                                                'com.apple.CoreSimulator.SimRuntime.iOS-26-5')
        posted.assert_not_called()  # the runner logs its own, with the report's link, after reporting
        return result, released, evidence

    def test_one_stall_then_a_good_fresh_clone_runs_the_tests_and_releases_both(self):
        (verdict, _, _, details, _, _), released, evidence = self.run_t3({'U1'})
        self.assertEqual(verdict, 'PASS')
        self.assertEqual(released, ['U1', 'U2'])  # the stalled clone, then the fresh one after the run
        self.assertTrue(any('boot stall on the first clone (U1)' in line and '(U2)' in line for line in details))
        self.assertTrue(json.loads((evidence / lane.BOOT_STALLS).read_text())['outcome'].startswith('recovered'))

    def test_two_stalls_stay_inconclusive_and_release_the_fresh_clone(self):
        (verdict, _, ran, details, _, _), released, evidence = self.run_t3({'U1', 'U2'})
        self.assertEqual((verdict, ran), ('INCONCLUSIVE', 'nothing'))
        self.assertEqual(released, ['U1', 'U2'])
        self.assertIn('failed too', details[0])
        saved = json.loads((evidence / lane.BOOT_STALLS).read_text())
        self.assertEqual([s['udid'] for s in saved['stalls']], ['U1', 'U2'])


class FreshCloneRerunTests(unittest.TestCase):
    """#2176: a plan that ends on its second startup stall runs once more on a fresh clone in the same job, as evidence
    on the stalls' cause (12 of 32 T3 runs stalled on 2026-10-19). Owner, 2026-10-23: two stalls keep INCONCLUSIVE
    per his 2026-10-11 call, whatever the rerun shows; only a failing test in it makes a FAIL (Default taken)."""

    def run_t3(self, manifests, boots_fail=(), grouped=None, unsafe=lambda: {}):
        import lane_sim
        clones, released, commands = iter(['U1', 'U2', 'U3']), [], []
        manifests = iter(manifests)

        def boot(udid, label, **kw):
            kw['info'].update(pressure='normal', pressure_waited=0, boot_window=(0.0, 1.0))
            if udid in boots_fail:
                raise lane_sim.BootError(f'simctl boot {udid} failed', stall=False)
            return 40.0

        def run_bounded(command, log, timeout):
            commands.append(command)
            output = Path(command[command.index('--output') + 1])
            output.mkdir(parents=True)
            (output / 'manifest.json').write_text(json.dumps(next(manifests)))
            return 0

        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        evidence = Path(temporary.name)
        with mock.patch.object(lane_sim, 'clone_temporary', side_effect=lambda *a, **k: next(clones)), \
                mock.patch.object(lane_sim, 'boot', side_effect=boot), \
                mock.patch.object(lane_sim, 'start_watcher'), \
                mock.patch.object(lane_sim, 'release', side_effect=lambda udid, *a, **k: released.append(udid)), \
                mock.patch.object(lane_sim, 'unsafe_devices', side_effect=unsafe), \
                mock.patch.object(lane_sim, 'is_available', return_value=True), \
                mock.patch.object(lane_sim, 'post_stall'), \
                mock.patch.object(lane, 'run_bounded', side_effect=run_bounded):
            result = lane._t3_on_claimed_device(grouped or {'app': ['T/A']}, 'r9', evidence,
                                                'com.apple.CoreSimulator.SimRuntime.iOS-26-5')
        devices = [command[command.index('--device') + 1] for command in commands]
        outputs = [Path(command[command.index('--output') + 1]).name for command in commands]
        return result, released, devices, outputs, evidence

    def test_two_stalls_then_a_clean_run_on_a_fresh_clone_stays_inconclusive_with_the_rerun_as_evidence(self):
        # Owner, 2026-10-23: "Two stalls keep INCONCLUSIVE per my 2026-10-11 call; the fresh-clone rerun is
        # evidence only." Before this change the clean rerun stood in for the stalled run and reported PASS.
        (verdict, _, ran, details, _, _), released, devices, outputs, evidence = self.run_t3(
            [stalled_out_manifest(), passing_manifest()])
        self.assertEqual(verdict, 'INCONCLUSIVE')
        self.assertEqual((devices, outputs), (['U1', 'U2'], ['verify-app', 'verify-app-fresh']))
        self.assertEqual(released, ['U1', 'U2'])  # the stalled clone first, the fresh one after the run
        line = next(line for line in details if 'two startup stalls on clone U1' in line)
        self.assertIn('fresh clone (U2) in the same job as evidence', line)
        self.assertIn('no host app process', line)
        self.assertIn('fresh-clone rerun: passed 1 tests; verdict stays INCONCLUSIVE (two stalls, owner '
                      '2026-10-11/2026-10-23)', line)
        self.assertIn('0 passed', ran)  # the verdict rests on the stalled run, not the rerun
        saved = json.loads((evidence / lane.FRESH_RERUNS).read_text())
        self.assertEqual([(r['plan'], r['stalled'], r['fresh'], r['status'], r['passed']) for r in saved],
                         [('app', 'U1', 'U2', 'verified', 1)])

    def test_a_recovered_stall_in_the_rerun_is_still_inconclusive(self):
        fresh = passing_manifest()
        fresh['steps'][0].update(startup_recovered=True, startup_stalls=[{'attempt': 1}])
        (verdict, _, _, details, _, _), *_ = self.run_t3([stalled_out_manifest(), fresh])
        self.assertEqual(verdict, 'INCONCLUSIVE')
        self.assertTrue(any('passed 1 tests after 1 recovered startup stall; verdict stays INCONCLUSIVE' in line
                            for line in details))

    def test_a_failing_test_in_the_rerun_is_a_fail(self):
        # Lead's Default taken on PR #2179: a failing test is a real failure, not a startup stall.
        fresh = passing_manifest()
        fresh['status'] = 'failed_or_incomplete'
        fresh['steps'][0]['tests']['T/B'] = {'status': 'failed'}
        (verdict, _, _, details, _, _), _, devices, _, evidence = self.run_t3([stalled_out_manifest(), fresh])
        self.assertEqual((verdict, devices), ('FAIL', ['U1', 'U2']))
        self.assertTrue(any('fresh-clone rerun: 1 test(s) failed (T/B); verdict FAIL' in line for line in details))
        self.assertTrue(any(line.startswith('T/B — expected: passes') and 'verify-app-fresh/tests.xcresult' in line
                            for line in details))
        self.assertEqual(json.loads((evidence / lane.FRESH_RERUNS).read_text())[0]['verdict'], 'FAIL')

    def test_a_rerun_that_stalls_too_stays_inconclusive_and_is_not_rerun_again(self):
        (verdict, *_), released, devices, _, _ = self.run_t3([stalled_out_manifest(), stalled_out_manifest()])
        self.assertEqual(verdict, 'INCONCLUSIVE')
        self.assertEqual((devices, released), (['U1', 'U2'], ['U1', 'U2']))

    def test_only_one_rerun_per_job(self):
        # A Mac that stalls every launch costs one more plan, not one per plan.
        (verdict, *_), _, devices, outputs, _ = self.run_t3(
            [stalled_out_manifest(), passing_manifest(), stalled_out_manifest()],
            grouped={'app': ['T/A'], 'adapters': ['T/B']})
        self.assertEqual(verdict, 'INCONCLUSIVE')
        self.assertEqual(outputs, ['verify-app', 'verify-app-fresh', 'verify-adapters'])
        self.assertEqual(devices, ['U1', 'U2', 'U2'])

    def overload_run(self, manifests, **kw):
        waits = []
        with mock.patch.object(lane, 'overload_line', return_value=100), \
                mock.patch.object(lane, 'wait_for_quiet_runner',
                                  side_effect=lambda line: waits.append(line) or (30.0, 80.0)):
            result = self.run_t3(manifests, **kw)
        return result, waits

    def test_a_test_run_that_hits_its_budget_on_an_overloaded_runner_is_rerun_once_by_the_lane(self):
        # #3374: INCONCLUSIVE at load 293.6, with no request comment to run it again.
        ((verdict, _, ran, details, _, _), released, devices, outputs, evidence), waits = self.overload_run(
            [overloaded_manifest(), passing_manifest()])
        self.assertEqual((verdict, devices, outputs), ('PASS', ['U1', 'U1'], ['verify-app', 'verify-app-retry']))
        self.assertEqual(waits, [100])
        self.assertIn('1 passed', ran)  # the rerun is the plan's result
        note = next(line for line in details if 'first run of this plan ran out of its time budget' in line)
        self.assertIn('runner overloaded', note)
        self.assertIn('load average 293.6 is above the overload line of 100', note)
        self.assertIn('waited 30s (load average then 80.0)', note)
        saved = json.loads((evidence / lane.OVERLOAD_RERUNS).read_text())
        self.assertEqual([(r['plan'], r['status'], r['overloaded_again']) for r in saved], [('app', 'verified', False)])

    def test_a_rerun_that_is_overloaded_again_says_so_and_is_not_rerun_again(self):
        ((verdict, _, _, details, _, _), _, devices, _, _), _ = self.overload_run(
            [overloaded_manifest(), overloaded_manifest(250.0, 40)])
        self.assertEqual((verdict, devices), ('INCONCLUSIVE', ['U1', 'U1']))
        self.assertTrue(any('so this stays INCONCLUSIVE. Check the log for the test' in line for line in details))
        self.assertTrue(any(line.startswith('app: runner overloaded: the `xcode-tests` step stopped at its time budget '
                                            'while the load average 250') for line in details))

    def test_only_one_overload_rerun_per_job(self):
        outputs = self.overload_run(
            [overloaded_manifest(), overloaded_manifest(), overloaded_manifest()],
            grouped={'app': ['T/A'], 'adapters': ['T/B']})[0][3]
        self.assertEqual(outputs, ['verify-app', 'verify-app-retry', 'verify-adapters'])

    def test_a_budget_hit_below_the_line_is_not_overload_and_is_not_rerun(self):
        ((verdict, _, _, details, _, _), _, devices, _, _), waits = self.overload_run([overloaded_manifest(load=60.0)])
        self.assertEqual((verdict, devices, waits), ('INCONCLUSIVE', ['U1'], []))
        self.assertFalse(any('runner overloaded' in line for line in details))

    def test_the_report_does_not_blame_the_machine_for_a_hang_it_cannot_tell_apart(self):
        # The audit of #3387: a test that deadlocks stops at its budget at the same load.
        (_, _, _, details, _, _), *_ = self.overload_run([overloaded_manifest(), overloaded_manifest()])[0]
        text = ' '.join(details)
        self.assertIn('a fact, not a proven cause', text)
        self.assertNotIn('too loaded', text)
        self.assertNotIn('not a failure of this PR', text)

    def test_a_run_the_runner_killed_at_its_whole_run_limit_is_not_rerun(self):
        # The audit of #3387: a second hour would run past runner.yml's job limit and the report would be lost.
        manifest = overloaded_manifest()
        manifest['steps'][0]['signalled'] = True
        self.assertIsNone(lane.runner_overloaded(manifest, cpus=10))
        ((verdict, *_), _, devices, _, _), waits = self.overload_run([manifest])
        self.assertEqual((verdict, devices, waits), ('INCONCLUSIVE', ['U1'], []))
        timed_out = {'status': 'timed out', 'error': 'budget ran out; interrupted', 'steps': overloaded_manifest()['steps']}
        ((verdict, *_), _, devices, _, _), waits = self.overload_run([timed_out])
        self.assertEqual((verdict, devices, waits), ('INCONCLUSIVE', ['U1'], []))

    def test_a_plan_with_a_startup_stall_is_not_overload_rerun(self):
        # The audit of #3387: one stall in each run would add up to the two the owner's 2026-10-11 call stops at.
        manifest = overloaded_manifest()
        manifest['steps'][0]['startup_stalls'] = [{'attempt': 1}]
        ((verdict, *_), _, devices, _, _), waits = self.overload_run([manifest])
        self.assertEqual((verdict, devices, waits), ('INCONCLUSIVE', ['U1'], []))

    def test_a_failing_test_on_an_overloaded_runner_is_the_prs_fail_and_is_not_rerun(self):
        manifest = overloaded_manifest()
        manifest['steps'][0]['tests']['T/A/test0'] = {'status': 'failed'}
        ((verdict, *_), _, devices, _, _), waits = self.overload_run([manifest])
        self.assertEqual((verdict, devices, waits), ('FAIL', ['U1'], []))

    def test_a_crash_flood_on_an_overloaded_runner_is_not_rerun(self):
        manifest = overloaded_manifest()
        manifest['steps'][0]['simulator_crash_report'] = 'x.ips'
        ((verdict, *_), _, devices, _, _), waits = self.overload_run([manifest])
        self.assertEqual((verdict, devices, waits), ('INCONCLUSIVE', ['U1'], []))

    def test_the_overload_line_is_per_cpu_and_the_wait_is_bounded(self):
        self.assertEqual(lane.overload_line(10), 10 * lane.OVERLOAD_LOAD_PER_CPU)
        readings, naps = iter([300.0, 200.0, 150.0]), []
        waited, last = lane.wait_for_quiet_runner(100, max_wait=60, poll=30, load=lambda: next(readings),
                                                  sleep=naps.append)
        self.assertEqual((waited, last, naps), (60.0, 150.0, [30, 30]))  # gave up at the cap, still over the line
        readings = iter([300.0, 90.0])
        self.assertEqual(lane.wait_for_quiet_runner(100, max_wait=60, poll=30, load=lambda: next(readings),
                                                    sleep=lambda _: None), (30.0, 90.0))

    def test_an_unreadable_xcresult_is_named_in_the_report_and_the_log_count_can_pass(self):
        manifest = passing_manifest()
        manifest['steps'][0]['xcresult_unreadable'] = 'Could not reconcile xcresult individual tests: exit 64'
        (verdict, _, _, details, _, _), _, devices, _, _ = self.run_t3([manifest])
        self.assertEqual((verdict, devices), ('PASS', ['U1']))
        line = next(line for line in details if 'the xcresult could not be read' in line)
        self.assertIn('the pass count comes from the test log, where all 1 expected test(s) finished and passed', line)

    def test_a_failing_test_after_the_stalls_is_the_prs_fail_and_is_not_rerun(self):
        manifest = stalled_out_manifest()
        manifest['steps'][0]['tests'] = {'T/A': {'status': 'failed'}}
        (verdict, *_), _, devices, _, _ = self.run_t3([manifest])
        self.assertEqual((verdict, devices), ('FAIL', ['U1']))
        self.assertFalse(lane.startup_stalled_out(manifest))

    def test_one_recovered_stall_is_already_a_pass_and_is_not_rerun(self):
        manifest = passing_manifest()
        manifest['steps'][0].update(startup_recovered=True, startup_stalls=[{'attempt': 1}])
        (verdict, *_), _, devices, _, _ = self.run_t3([manifest])
        self.assertEqual((verdict, devices), ('PASS', ['U1']))

    def test_a_fresh_clone_that_does_not_boot_keeps_the_inconclusive_and_runs_nothing_more(self):
        (verdict, _, _, details, _, _), released, devices, _, evidence = self.run_t3(
            [stalled_out_manifest()], boots_fail={'U2'}, grouped={'app': ['T/A'], 'adapters': ['T/B']})
        self.assertEqual(verdict, 'INCONCLUSIVE')
        self.assertEqual(devices, ['U1'])  # neither the rerun nor the adapters plan ran on a device that isn't up
        self.assertEqual(released, ['U1', 'U2'])
        self.assertTrue(any('could not start' in line and 'simctl boot U2 failed' in line for line in details))
        self.assertTrue(any('not run: adapters' in line for line in details))
        self.assertIn('simctl boot U2 failed', json.loads((evidence / lane.FRESH_RERUNS).read_text())[0]['boot'])

    def test_a_fresh_clone_that_boots_but_fails_readiness_runs_nothing_more(self):
        # #2530 (audit of #2179 on 6933707): the stalled run's own steps passed readiness, so only the rerun's
        # manifest shows the fresh clone is not ready. The adapters plan must not start on it.
        not_ready = {'status': 'failed_or_incomplete', 'error': 'simulator-ready: Process exit 148',
                     'steps': [{'name': 'simulator-ready', 'exit_code': 148, 'errors': ['Process exit 148']}]}
        (verdict, _, ran, details, _, _), released, devices, outputs, evidence = self.run_t3(
            [stalled_out_manifest(), not_ready], grouped={'app': ['T/A'], 'adapters': ['T/B']})
        self.assertEqual(verdict, 'INCONCLUSIVE')
        self.assertEqual((devices, outputs), (['U1', 'U2'], ['verify-app', 'verify-app-fresh']))
        self.assertEqual(released, ['U1', 'U2'])
        self.assertTrue(any('booted but was not ready (verify-tests.py `simulator-ready`)' in line
                            and 'not run: adapters' in line for line in details), details)
        self.assertEqual(json.loads((evidence / lane.FRESH_RERUNS).read_text())[0]['not_ready'], 'simulator-ready')

    def test_a_fresh_clone_marked_unsafe_by_its_failed_boot_is_not_a_crash_flood(self):
        # Audit on 484c63b: the failed boot marks U2 unsafe ('simctl boot failed'). No watcher ever ran on U2, so
        # the report must not say the SpringBoard watcher stopped it or ping the owner about a crash.
        marks = {'U2': {'reason': 'simctl boot failed: x'}}
        (verdict, _, _, _, crashes, cc), _, devices, _, _ = self.run_t3(
            [stalled_out_manifest()], boots_fail={'U2'}, unsafe=lambda: marks)
        self.assertEqual((verdict, devices), ('INCONCLUSIVE', ['U1']))
        self.assertEqual(cc, '')
        self.assertFalse(crashes.startswith('crash flood'), crashes)
        self.assertNotIn('SpringBoard watcher', crashes)

    def test_a_watcher_stop_on_the_fresh_clone_is_still_a_crash_flood(self):
        calls = []

        def unsafe():
            calls.append(1)
            return {} if len(calls) == 1 else {'U2': {'reason': 'SpringBoard crashed: SpringBoard-f.ips'}}

        (verdict, _, _, _, crashes, cc), _, devices, _, _ = self.run_t3(
            [stalled_out_manifest(), passing_manifest()], unsafe=unsafe)
        self.assertEqual((verdict, devices), ('INCONCLUSIVE', ['U1', 'U2']))
        self.assertIn('the SpringBoard watcher stopped the device: SpringBoard crashed: SpringBoard-f.ips', crashes)
        self.assertTrue(cc)

    def test_the_fresh_rerun_keeps_the_stalled_runs_log(self):
        # Audit on 484c63b (minor): both runs wrote verify-app.log, so the rerun overwrote the stalled run's output.
        *_, evidence = self.run_t3([stalled_out_manifest(), passing_manifest()])
        self.assertTrue((evidence / 'verify-app.log').is_file())
        self.assertTrue((evidence / 'verify-app-fresh.log').is_file())

    def test_a_stalled_clone_the_watcher_stopped_is_not_swapped_for_a_fresh_one(self):
        # Audit on 041d4f4: a SpringBoard crash on U1 stops it and marks it unsafe, and the next launch then
        # "stalls" twice. Rerunning on U2 would switch devices to get around a crash and could report PASS.
        stopped = {'U1': {'reason': 'SpringBoard crashed: SpringBoard-x.ips'}}
        (verdict, _, _, _, crashes, cc), released, devices, _, evidence = self.run_t3(
            [stalled_out_manifest(), passing_manifest()], unsafe=lambda: stopped)
        self.assertEqual((verdict, devices, released), ('INCONCLUSIVE', ['U1'], ['U1']))
        self.assertIn('the SpringBoard watcher stopped the device: SpringBoard crashed', crashes)
        self.assertTrue(crashes.startswith('crash flood: '))
        self.assertTrue(cc)
        self.assertFalse((evidence / lane.FRESH_RERUNS).exists())

    def test_a_watcher_mark_on_the_stalled_clone_after_the_rerun_starts_still_reaches_the_verdict(self):
        # The mark can land after the check (the watcher's crash report arrives late): the final check reads every
        # clone a plan ran on, not only the last one.
        calls = []

        def unsafe():
            calls.append(1)
            return {} if len(calls) == 1 else {'U1': {'reason': 'SpringBoard crashed: SpringBoard-y.ips'}}

        (verdict, _, _, _, crashes, _), _, devices, _, _ = self.run_t3(
            [stalled_out_manifest(), passing_manifest()], unsafe=unsafe)
        self.assertEqual((verdict, devices), ('INCONCLUSIVE', ['U1', 'U2']))
        self.assertIn('the SpringBoard watcher stopped the device: SpringBoard crashed: SpringBoard-y.ips', crashes)

    def test_a_late_boot_crash_report_on_the_stalled_clone_is_noted_not_a_stop(self):
        late = {'U1': {'reason': 'late crash report for a crash during boot: SpringBoard-z.ips'}}
        calls = []

        def unsafe():
            calls.append(1)
            return {} if len(calls) == 1 else late

        (verdict, _, _, details, crashes, _), _, devices, _, _ = self.run_t3(
            [stalled_out_manifest(), passing_manifest()], unsafe=unsafe)
        self.assertEqual((verdict, devices, crashes), ('INCONCLUSIVE', ['U1', 'U2'], 'none'))  # two stalls
        self.assertTrue(any('SpringBoard-z.ips' in line and 'U1' in line for line in details))


class RetryPassTests(unittest.TestCase):
    """Owner's call 2026-10-24 (#2596, #2176): every T3 report says what passed on retry, and each retry-pass is tallied."""

    RETRIED = 'SpokenMarginsAppTests/FlakyTests/testSometimes()'
    NOW = datetime.datetime(2026, 10, 25, 1, 0, tzinfo=datetime.timezone.utc)

    def manifest(self, retried=()):
        step = {'name': 'xcode-tests', 'exit_code': 0, 'tests': {'T/A/test0': {'status': 'passed'}}}
        if retried:
            step['passed_on_retry'] = list(retried)
        return {'status': 'verified', 'steps': [{'name': 'build-for-testing', 'exit_code': 0, 'errors': []}, step]}

    class Tally:
        def __init__(self, comments=(), markers=(), fail=False):
            self.posted, self.issues, self._comments, self._markers, self.fail = [], [], list(comments), set(markers), fail

        def post(self, body):
            if self.fail:
                raise RuntimeError('gh is down')
            self.posted.append(body)
            self._comments.append({'user': {'login': 'github-actions[bot]'}, 'body': body})

        def comments(self):
            return self._comments

        def open_markers(self):
            return self._markers

        def open_issue(self, title, body):
            self.issues.append((title, body))
            return 'https://github.com/o/r/issues/9'

    def evidence(self, retried):
        folder = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, folder, True)
        (folder / 'verify-app').mkdir()
        (folder / 'verify-app' / 'manifest.json').write_text(json.dumps(self.manifest(retried)))
        return folder

    def test_a_report_with_no_retry_says_none_for_each_plan(self):
        _, _, _, details = lane.run_plans({'app': ['T/A'], 'adapters': ['T/B']}, lambda *_: self.manifest(), Path('/e'))
        self.assertEqual([d for d in details if 'passed on retry' in d],
                         ['app: passed on retry: none', 'adapters: passed on retry: none'])

    def test_a_report_with_a_retry_names_the_test(self):
        _, _, _, details = lane.run_plans({'app': ['T/A']}, lambda *_: self.manifest([self.RETRIED]), Path('/e'))
        self.assertIn(f'app: passed on retry: {self.RETRIED}', details)

    def test_a_retry_pass_is_tallied_once_in_the_integration_runs_format(self):
        tally = self.Tally()
        lane.log_retry_passes(self.evidence([self.RETRIED]), 'o/r', 'abcdef1234', '77', tally, self.NOW)
        self.assertEqual(len(tally.posted), 1)
        self.assertEqual(tally.posted[0].splitlines()[0], f'flake-tally: {self.RETRIED} abcdef1 77 2026-10-25T01:00:00Z')
        self.assertEqual(tally.issues, [])

    def test_no_retry_means_no_tally(self):
        tally = self.Tally()
        lane.log_retry_passes(self.evidence([]), 'o/r', 'abcdef1234', '77', tally)
        self.assertEqual(tally.posted, [])

    def test_a_third_retry_pass_in_seven_days_opens_one_issue(self):
        def earlier(run, days, login='github-actions[bot]'):
            when = (self.NOW - datetime.timedelta(days=days)).strftime('%Y-%m-%dT%H:%M:%SZ')
            return {'user': {'login': login}, 'body': f'flake-tally: {self.RETRIED} abcdef1 {run} {when}'}
        # Two in-window runs plus this one make three; a run 9 days back and a stranger's look-alike don't count.
        tally = self.Tally([earlier('1', 2), earlier('2', 6), earlier('3', 9), earlier('4', 1, 'mallory')])
        opened = lane.log_retry_passes(self.evidence([self.RETRIED]), 'o/r', 'abcdef1234', '77', tally, self.NOW)
        self.assertEqual(opened, ['https://github.com/o/r/issues/9'])
        self.assertIn(f'<!-- flake-test: {self.RETRIED} -->', tally.issues[0][1])

    def test_an_open_flake_issue_the_workflow_bot_opened_still_counts(self):
        # The lane opens flake issues as github-actions[bot], whose author_association is NONE; missing it opened a
        # duplicate `ready` issue on every later retry-pass (audit on 0102f32).
        issues = [{'body': f'<!-- flake-test: {self.RETRIED} -->', 'author_association': 'NONE',
                   'user': {'login': 'github-actions[bot]'}},
                  {'body': '<!-- flake-test: T/Owner/testA() -->', 'author_association': 'OWNER', 'user': {'login': 'o'}},
                  {'body': '<!-- flake-test: T/Stranger/testB() -->', 'author_association': 'NONE',
                   'user': {'login': 'mallory'}}]
        repo_tally = lane.RepoTally.__new__(lane.RepoTally)
        repo_tally.repo = 'o/r'
        repo_tally.client = mock.Mock()
        repo_tally.client.api.return_value = '\n'.join(json.dumps(i) for i in issues) + '\n'
        self.assertEqual(repo_tally.open_markers(), {self.RETRIED, 'T/Owner/testA()'})
        self.assertIn('user', repo_tally.client.api.call_args[0][2])

    def test_a_test_name_with_spaces_is_still_counted(self):
        spaced = 'SpokenMarginsAppTests/Playback/plays the next item()'
        def earlier(run, days):
            when = (self.NOW - datetime.timedelta(days=days)).strftime('%Y-%m-%dT%H:%M:%SZ')
            return {'user': {'login': 'github-actions[bot]'}, 'body': f'flake-tally: {spaced} abcdef1 {run} {when}'}
        tally = self.Tally([earlier('1', 2), earlier('2', 3)])
        opened = lane.log_retry_passes(self.evidence([spaced]), 'o/r', 'abcdef1234', '77', tally, self.NOW)
        self.assertEqual(len(opened), 1)
        self.assertIn(f'<!-- flake-test: {spaced} -->', tally.issues[0][1])

    def test_a_tally_error_warns_and_the_verdict_stays_pass(self):
        tally = self.Tally(fail=True)
        with mock.patch('builtins.print') as shown:
            lane.log_retry_passes(self.evidence([self.RETRIED]), 'o/r', 'abcdef1234', '77', tally)
        self.assertIn('Could not tally', shown.call_args[0][0])
        summaries, statuses, _, _ = lane.run_plans({'app': ['T/A']}, lambda *_: self.manifest([self.RETRIED]), Path('/e'))
        self.assertEqual(lane.t3_verdict(summaries, statuses), 'PASS')


class PlanDurationTests(unittest.TestCase):
    def test_each_plan_reports_how_long_it_took(self):
        now = [0.0]

        def run_plan(plan, selectors, output):
            now[0] += 912
            return {'status': 'verified', 'steps': [{'name': 'xcode-tests', 'tests': {'T/A/test1': {'status': 'passed'}}}]}

        with mock.patch.object(lane, 'time', mock.Mock(monotonic=lambda: now[0])):
            _, _, ran, _ = lane.run_plans({'app': ['T/A']}, run_plan, Path('/e'))
        self.assertEqual(ran, ['A (1 passed; app plan, build and tests, 15m12s)'])


class RepoGhCliTests(unittest.TestCase):
    """lane.Repo against a fake `gh` on PATH that records its argv and prints queued answers.

    No other test calls the real one, so the REST paths, the `labels[]` field and the `--paginate --jq`
    flags would otherwise never be produced. Moved here with Repo (#4769)."""

    FAKE_GH = "#!{python}\nimport json, os, sys\n" \
              "folder = os.environ['FAKE_GH_DIR']\n" \
              "with open(folder + '/calls.jsonl', 'a') as calls:\n" \
              "    calls.write(json.dumps(sys.argv[1:]) + '\\n')\n" \
              "answers = json.load(open(folder + '/answers.json'))\n" \
              "answer = answers.pop(0) if answers else {{'stdout': '', 'exit': 0}}\n" \
              "json.dump(answers, open(folder + '/answers.json', 'w'))\n" \
              "sys.stdout.write(answer['stdout'])\n" \
              "sys.exit(answer['exit'])\n"

    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.folder = Path(temporary.name)
        (self.folder / 'bin').mkdir()
        gh = self.folder / 'bin/gh'
        gh.write_text(self.FAKE_GH.format(python=sys.executable))
        gh.chmod(0o755)
        patcher = mock.patch.dict(os.environ, {'PATH': f'{self.folder / "bin"}:{os.environ["PATH"]}',
                                               'FAKE_GH_DIR': str(self.folder)})
        patcher.start()
        self.addCleanup(patcher.stop)
        self.answer()

    def answer(self, *answers):
        """What the next gh calls print: a string (exit 0) or (string, exit code); then silence, exit 0."""
        (self.folder / 'answers.json').write_text(json.dumps([
            {'stdout': a, 'exit': 0} if isinstance(a, str) else {'stdout': a[0], 'exit': a[1]} for a in answers]))

    def calls(self):
        log = self.folder / 'calls.jsonl'
        return [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []

    def test_repo_reads_comments_a_page_at_a_time_until_a_short_page(self):
        repo = lane.Repo('owner/repo')
        self.answer(json.dumps([{'n': n} for n in range(100)]), json.dumps([{'n': 100}]))
        self.assertEqual([c['n'] for c in repo.comments_since('2026-10-01T00:00:00Z')], list(range(101)))
        self.assertEqual(self.calls(), [
            ['api', 'repos/owner/repo/issues/comments?since=2026-10-01T00:00:00Z&sort=created&direction=asc'
                    f'&per_page=100&page={page}'] for page in (1, 2)])

    def test_repo_comments_title_and_new_issue_use_the_expected_paths_and_fields(self):
        repo = lane.Repo('owner/repo')
        self.answer(json.dumps({'body': 'x'}) + '\n', json.dumps({'html_url': 'https://example.test/c2'}),
                    json.dumps({'title': 'Change the lane'}), json.dumps({'html_url': 'https://example.test/i9'}))
        self.assertEqual([c['body'] for c in repo.issue_comments(337)], ['x'])
        self.assertEqual(repo.comment(337, 'Lane auto-revert: x'), 'https://example.test/c2')
        self.assertEqual(repo.title(441), 'Change the lane')
        self.assertEqual(repo.open_issue('Lane broke', 'details', ['lane-fault', 'urgent']), 'https://example.test/i9')
        self.assertEqual(self.calls(), [
            ['api', '--paginate', '--jq', '.[] | @json', 'repos/owner/repo/issues/337/comments'],
            ['api', 'repos/owner/repo/issues/337/comments', '-f', 'body=Lane auto-revert: x'],
            ['api', 'repos/owner/repo/pulls/441'],
            ['api', 'repos/owner/repo/issues', '-f', 'title=Lane broke', '-f', 'body=details',
             '-f', 'labels[]=lane-fault', '-f', 'labels[]=urgent']])


if __name__ == '__main__':
    unittest.main()
