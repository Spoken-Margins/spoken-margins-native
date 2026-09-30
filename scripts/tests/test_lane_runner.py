import importlib.util
import json
import os
import re
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
spec = importlib.util.spec_from_file_location('lane_runner', SCRIPTS / 'lane-runner.py')
lane = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lane)
verify_spec = importlib.util.spec_from_file_location('verification_for_lane', SCRIPTS / 'verify-tests.py')
verification = importlib.util.module_from_spec(verify_spec)
verify_spec.loader.exec_module(verification)

HEAD = 'a' * 40
MERGE = 'b' * 40
NEWER = 'c' * 40


def comment(body, login='uncomposed', url='https://example.test/c'):
    return {'body': body, 'user': {'login': login}, 'html_url': url}


def runner_report(verdict, wanted, url='https://example.test/r'):
    return comment(lane.report('pr1-r1', verdict, wanted['commit'], wanted['next'], wanted['tier'], 'x', 1, 'x', [],
                               'none', '/e', 'owner', wanted), login='github-actions[bot]', url=url)


class FakeGitHub:
    def __init__(self, labels=('lane:queued',), head=HEAD, comments=(), fail_comment=False):
        self.labels, self.head, self._comments = set(labels), head, list(comments)
        self.posted, self.label_changes, self.fail_comment = [], [], fail_comment

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

    def relabel(self, remove, add):
        self.label_changes.append((remove, add))
        self.labels.discard(remove)
        if add:
            self.labels.add(add)


class RequestTests(unittest.TestCase):
    def test_request_fields_follow_the_test_lane_format(self):
        request = lane.parse_request(
            '/lane T3\ncommit: abc1234\nchanged: share sheet\ntests: SourceLinkImportTests/testA, Gate1AppModelWorkflowTests'
            '   # or run: J1\nwatch for: chunk flips\n')
        self.assertEqual(request['tier'], 'T3')
        self.assertEqual(request['commit'], 'abc1234')
        self.assertEqual(request['tests'], ['SourceLinkImportTests/testA', 'Gate1AppModelWorkflowTests'])
        self.assertEqual(request['watch for'], 'chunk flips')
        self.assertIsNone(lane.parse_request('Looks good. We could /lane T2 later.'))

    def test_tests_on_a_run_line_are_accepted_as_the_contract_example_wrote_them(self):
        request = lane.parse_request('/lane T3\ncommit: abc1234\nrun: tests: AppNavigationStateTests, B/testC\n')
        self.assertEqual(request['tests'], ['AppNavigationStateTests', 'B/testC'])
        request = lane.parse_request('/lane T3\nrun: tests: Ignored\ntests: Wins\n')
        self.assertEqual(request['tests'], ['Wins'])
        request = lane.parse_request('/lane T4\nrun: J1, J7\n')
        self.assertEqual((request['run'], request['tests']), ('J1, J7', []))

    def test_the_newest_unanswered_runner_request_wins(self):
        request, desk = lane.pending_requests([comment('/lane T2\ncommit: 1111111'),
                                               comment('/lane T3\ncommit: 2222222\ntests: X')])
        self.assertEqual((request['tier'], desk), ('T3', False))

    def test_answered_requests_are_not_run_again(self):
        wanted = lane.identity('T2', HEAD, MERGE, [])
        request, _ = lane.pending_requests([comment('/lane T2'), runner_report('PASS', wanted)])
        self.assertIsNone(request)
        request, _ = lane.pending_requests([comment('/lane T2'), comment(f'Lane: identical …\n{lane.NOTE}')])
        self.assertIsNone(request)

    def test_an_automerge_report_or_note_does_not_answer_a_lane_request(self):
        # #368: a /lane T3 waited behind a simulator job, the automerge run reported first, and the T3 never ran.
        auto = lane.identity('auto', HEAD, MERGE, [])
        for answer in (runner_report('INCONCLUSIVE', auto),
                       comment(f'Lane: the automerge run stopped before reporting (u). Push again.\n{lane.NOTE}')):
            with self.subTest(answer=answer['body'][:30]):
                request, _ = lane.pending_requests([comment('/lane T3\ntests: X'), answer])
                self.assertEqual((request or {}).get('tier'), 'T3')

    def test_a_t4_after_a_t2_leaves_the_t2_to_the_runner_and_the_t4_waiting(self):
        request, desk = lane.pending_requests([comment('/lane T2'), comment('/lane T4\nrun: J1')])
        self.assertEqual((request['tier'], desk), ('T2', True))

    def test_a_test_desk_report_answers_the_t4(self):
        request, desk = lane.pending_requests([comment('/lane T4\nrun: J1'),
                                               comment('Lane report pr1-desk — PASS\ncommit abc · tier T4'),
                                               comment('/lane T2')])
        self.assertEqual((request['tier'], desk), ('T2', False))

    def test_only_pass_or_fail_reports_make_a_request_identical(self):
        wanted = lane.identity('T3', HEAD, MERGE, ['B', 'A'])
        same = lane.identity('T3', HEAD, MERGE, ['A', 'B'])
        self.assertEqual(lane.earlier_report([runner_report('PASS', wanted, url='u1')], same), ('u1', 'PASS'))
        self.assertEqual(lane.earlier_report([runner_report('FAIL', wanted, url='u2')], same), ('u2', 'FAIL'))
        self.assertIsNone(lane.earlier_report([runner_report('INCONCLUSIVE', wanted)], same))
        self.assertIsNone(lane.earlier_report([runner_report('PASS', wanted)], lane.identity('T3', NEWER, MERGE, ['A', 'B'])))
        # Same head, but next moved: it runs again.
        self.assertIsNone(lane.earlier_report([runner_report('PASS', wanted)], lane.identity('T3', HEAD, NEWER, ['A', 'B'])))


class ReportTests(unittest.TestCase):
    def test_report_matches_the_contract_header_and_lines(self):
        body = lane.report('pr7-r9', 'FAIL', HEAD, MERGE, 'T2', 'no simulator (compile only)', 75,
                           'simulator build (pass), device build (fail)', ['device build — expected: …'],
                           'none', '/ev/pr7-r9', 'journeys (T4)', lane.identity('T2', HEAD, MERGE, []))
        lines = body.splitlines()
        self.assertEqual(lines[0], 'Lane report pr7-r9 — FAIL')
        self.assertEqual(lines[1], f'commit {HEAD[:7]} (tested merged with next at {MERGE[:7]}) · tier T2 · '
                                   'no simulator (compile only) · 1m15s')
        self.assertTrue(lines[2].startswith('ran: '))
        self.assertIn('crashes: none', lines)
        self.assertIn('not verified: journeys (T4)', lines)

    def test_t2_passes_only_when_both_builds_pass_and_names_the_failure(self):
        with tempfile.TemporaryDirectory() as temporary:
            evidence = Path(temporary)

            def fake(command, log, timeout):
                if 'generic/platform=iOS' in command:
                    self.assertIn('CODE_SIGNING_ALLOWED=NO', command)  # the runner can't reach the keychain
                    log.write('Foo.swift:3:1: error: cannot find Bar in scope\n** BUILD FAILED **\n\n'
                              'The following build commands failed:\n\tCompileSwift Foo.swift\n(1 failure)\n\n')
                    return 65
                return 0

            verdict, ran, details = lane.run_t2(evidence, runner=fake)
            self.assertEqual(verdict, 'FAIL')
            self.assertEqual(ran, 'simulator build (pass), device build (fail)')
            self.assertTrue(any('cannot find Bar' in line for line in details))
            self.assertTrue(any('failed: CompileSwift Foo.swift' in line for line in details))
            self.assertEqual(lane.run_t2(evidence, runner=lambda *_: 0)[0], 'PASS')
            self.assertEqual(lane.run_t2(evidence, runner=lambda *_: None)[0], 'INCONCLUSIVE')

    def test_the_simulator_and_device_builds_never_share_a_derived_data_folder(self):
        # #405: with one warm DerivedData, the simulator build after a device build failed on a missing
        # all-product-headers.yaml in the extension targets; cold builds, and every device build, passed.
        folders = []
        def fake(command, log, timeout):
            folders.append(command[command.index('-derivedDataPath') + 1] if '-derivedDataPath' in command else None)
            return 0
        with tempfile.TemporaryDirectory() as folder:
            lane.run_t2(Path(folder), runner=fake)
        self.assertEqual(len(folders), 2)
        self.assertNotIn(None, folders, 'xcodebuild-lane would give both builds .build/dd')
        self.assertNotEqual(folders[0], folders[1])
        self.assertTrue(all(Path(f).parent == lane.ROOT / '.build' for f in folders), folders)


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

    def test_a_class_goes_to_every_plan_that_runs_part_of_it(self):
        plans = {'app': {'SpokenMarginsAppTests/A/test1'}, 'adapters': {'SpokenMarginsAppTests/A/test2'}}
        self.assertEqual(lane.plan_for_tests(['A', 'A/test2'], plans),
                         ({'app': ['SpokenMarginsAppTests/A'],
                           'adapters': ['SpokenMarginsAppTests/A', 'SpokenMarginsAppTests/A/test2']}, []))

    def test_tests_are_grouped_by_plan_and_unknown_ones_are_reported(self):
        grouped, unknown = lane.plan_for_tests(['A', 'SpokenMarginsAppTests/Audio/test1', 'Missing', 'A/test9'],
                                               self.PLANS)
        self.assertEqual(grouped, {'app': ['SpokenMarginsAppTests/A'], 'adapters': ['SpokenMarginsAppTests/Audio/test1']})
        self.assertEqual(unknown, ['Missing', 'A/test9'])

    def test_verdicts_separate_failures_from_lane_trouble(self):
        failing = lane.summarize_manifest({'status': 'failed_or_incomplete', 'steps': [
            {'name': 'xcode-tests', 'tests': {'A/test1': {'status': 'passed'}, 'A/test2': {'status': 'failed'}}}]})
        self.assertEqual((failing['passed'], failing['failed']), (1, ['A/test2']))
        self.assertEqual(lane.t3_verdict([failing], ['failed_or_incomplete']), 'FAIL')
        broken = lane.summarize_manifest({'steps': [{'name': 'build-for-testing', 'errors': ['Process exit 65']}]})
        self.assertEqual(lane.t3_verdict([broken], ['failed_or_incomplete']), 'FAIL')
        self.assertEqual(lane.t3_verdict([lane.summarize_manifest({'steps': []})], ['verified']), 'PASS')

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
            return [lane.summarize_manifest({'steps': []})], ['verified'], ['A (1 passed)'], []

        import lane_sim
        with mock.patch.object(lane, 'time', fake_time), \
                mock.patch.object(lane_sim, 'create_temporary', return_value='U'), \
                mock.patch.object(lane_sim, 'start_watcher'), mock.patch.object(lane_sim, 'release'), \
                mock.patch.object(lane_sim, 'unsafe_devices', return_value={}), \
                mock.patch.object(lane, 'first_boot', side_effect=boot), \
                mock.patch.object(lane, 'run_plans', side_effect=tests), \
                tempfile.TemporaryDirectory() as temporary:
            verdict, _, _, details, _, _ = lane._t3_on_fresh_device({'app': ['T/A']}, 'r', Path(temporary),
                                                                     'com.apple.CoreSimulator.SimRuntime.iOS-26-5')
        self.assertEqual((verdict, details[0]), ('PASS', 'first boot of the fresh simulator took 1m05s (memory pressure '
                                                         'at boot: warn, after waiting 600s; one-simulator period)'))

    def test_a_tolerated_change_and_a_late_crash_report_are_reported_without_changing_the_verdict(self):
        import lane_sim
        with mock.patch.object(lane_sim, 'create_temporary', return_value='U'), \
                mock.patch.object(lane_sim, 'start_watcher'), mock.patch.object(lane_sim, 'release'), \
                mock.patch.object(lane_sim, 'unsafe_devices', return_value={'U': {
                    'reason': 'late crash report for a crash during boot: SpringBoard-x.ips'}}), \
                mock.patch.object(lane, 'first_boot', return_value=(None, {
                    'pressure': 'normal', 'pressure_waited': 0, 'tolerated': 'SpringBoard restarted (pid 1 -> 2)',
                    'boot_window': (0.0, 1.0)})), \
                mock.patch.object(lane, 'run_plans', return_value=([lane.summarize_manifest({'steps': []})], ['verified'],
                                                                   ['A (1 passed)'], [])), \
                tempfile.TemporaryDirectory() as temporary:
            verdict, _, _, details, crashes, cc = lane._t3_on_fresh_device(
                {'app': ['T/A']}, 'r', Path(temporary), 'com.apple.CoreSimulator.SimRuntime.iOS-26-5')
        self.assertEqual((verdict, cc), ('PASS', ''))
        self.assertIn("tolerated one SpringBoard change in the first 30 s of the first boot (owner's rule, #184)", details[1])
        self.assertTrue(any('marked unsafe and deleted' in line for line in details))
        self.assertEqual(crashes, 'none')

    def _t3_with(self, boot, plans, back_to_one):
        import lane_sim
        with mock.patch.object(lane_sim, 'create_temporary', return_value='U'), \
                mock.patch.object(lane_sim, 'start_watcher'), mock.patch.object(lane_sim, 'release'), \
                mock.patch.object(lane_sim, 'unsafe_devices', return_value={}), \
                mock.patch.object(lane_sim, 'back_to_one_simulator', back_to_one), \
                mock.patch.object(lane, 'first_boot', return_value=boot), \
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
        passing = ([lane.summarize_manifest({'steps': []})], ['verified'], ['A (1 passed)'], [])
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

    def test_a_t3_request_without_tests_or_with_unknown_tests_does_not_boot_anything(self):
        import lane_sim
        with mock.patch.object(lane_sim, 'newest_runtime', side_effect=AssertionError('no simulator should be made')), \
                mock.patch.object(lane_sim, 'create_temporary', side_effect=AssertionError('no simulator should be made')):
            self.assertEqual(lane.run_t3([], 'r', Path('/tmp'))[0], 'INCONCLUSIVE')
            self.assertEqual(lane.run_t3(['NoSuchTestClassAnywhere'], 'r', Path('/tmp'))[0], 'FAIL')


class RunnerDeviceTests(unittest.TestCase):
    """#440 and #411: every lane job swept "SM Lane Runner" simulators when it started, and an automerge job on
    the second runner (sm-lane-mac-2) deleted a T3's live device on the main runner mid-run, four times on
    2026-09-30 (e.g. 14:12:43 "Deleted leftover simulator SM Lane Runner pr432-r36724477838")."""

    def setUp(self):
        self.state = tempfile.TemporaryDirectory()
        self.addCleanup(self.state.cleanup)
        patcher = mock.patch.dict(os.environ, {'SM_LANE_STATE_DIR': self.state.name})
        patcher.start()
        self.addCleanup(patcher.stop)

    def sweep(self, names):
        listing = {'devices': {'com.apple.CoreSimulator.SimRuntime.iOS-26-5': [
            {'name': name, 'udid': f'U{index}'} for index, name in enumerate(names)]}}
        commands = []

        def run(command, **_):
            commands.append(command)
            return subprocess.CompletedProcess(command, 0)

        with mock.patch.object(lane.subprocess, 'check_output', return_value=json.dumps(listing)), \
                mock.patch.object(lane.subprocess, 'run', side_effect=run):
            lane.sweep_runner_simulators()
        return [c[-1] for c in commands if c[:3] == ['xcrun', 'simctl', 'delete']]

    def test_a_sweep_leaves_a_running_t3_s_device_alone_and_deletes_leftovers(self):
        claim = lane.claim_runner_device('SM Lane Runner pr432-r36724477838')
        try:
            deleted = self.sweep(['SM Lane Runner pr432-r36724477838', 'SM Lane Runner pr9-r1', 'SpokenMargins Test Runner'])
        finally:
            lane.release_runner_device(claim)
        self.assertEqual(deleted, ['U1'])

    def test_a_device_whose_job_has_ended_is_swept(self):
        lane.release_runner_device(lane.claim_runner_device('SM Lane Runner pr1-r1'))
        self.assertEqual(self.sweep(['SM Lane Runner pr1-r1']), ['U0'])

    def test_a_crashed_job_s_claim_ends_with_its_process(self):
        name = 'SM Lane Runner pr2-r2'
        code = (f'import importlib.util, sys, time; spec = importlib.util.spec_from_file_location("l", {str(SCRIPTS / "lane-runner.py")!r}); '
                f'l = importlib.util.module_from_spec(spec); spec.loader.exec_module(l); held = l.claim_runner_device({name!r}); '
                'print("held", flush=True); time.sleep(60)')
        child = subprocess.Popen([sys.executable, '-c', code], stdout=subprocess.PIPE, text=True,
                                 env=dict(os.environ, SM_LANE_STATE_DIR=self.state.name))
        try:
            self.assertEqual(child.stdout.readline().strip(), 'held')
            self.assertTrue(lane.runner_device_claimed(name))
        finally:
            child.kill()
            child.wait()
            child.stdout.close()
        self.assertFalse(lane.runner_device_claimed(name))

    def test_the_t3_job_holds_its_device_s_claim_from_before_it_exists_until_it_is_deleted(self):
        import lane_sim
        seen = {}
        name = lane.RUNNER_SIMULATOR_PREFIX + 'pr7-r7'

        def create(created):
            seen['at create'] = lane.runner_device_claimed(created)
            return 'U'

        def release(udid):
            seen['at delete'] = lane.runner_device_claimed(name)

        with mock.patch.object(lane_sim, 'create_temporary', side_effect=create), \
                mock.patch.object(lane_sim, 'start_watcher'), mock.patch.object(lane_sim, 'release', side_effect=release), \
                mock.patch.object(lane_sim, 'unsafe_devices', return_value={}), \
                mock.patch.object(lane, 'first_boot', return_value=(None, {})), \
                mock.patch.object(lane, 'run_plans', return_value=([lane.summarize_manifest({'steps': []})], ['verified'],
                                                                   ['A (1 passed)'], [])), \
                tempfile.TemporaryDirectory() as temporary:
            lane._t3_on_fresh_device({'app': ['T/A']}, 'pr7-r7', Path(temporary),
                                     'com.apple.CoreSimulator.SimRuntime.iOS-26-5')
        self.assertEqual(seen, {'at create': True, 'at delete': True})
        self.assertFalse(lane.runner_device_claimed(name))
        self.assertEqual(list(Path(self.state.name).glob('runner-device-*')), [])


class LostDeviceTests(unittest.TestCase):
    """#440: after the app plan's readiness step failed (exit 148), the adapters plan ran anyway and found no
    simulator. #411: a device gone mid-build made xcodebuild exit 70, which read as a build FAIL."""

    @staticmethod
    def plans(first):
        calls = []

        def run_plan(plan, selectors, output):
            calls.append(plan)
            return first if plan == 'app' else {'status': 'verified', 'steps': []}
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


class ScopeClassTests(unittest.TestCase):
    """#351: a T3 request runs at least the app test classes test-scope.py names for the diff."""

    def test_the_diff_s_classes_join_the_request_and_absorb_its_methods(self):
        selectors, added = lane.with_scope_classes(
            ['Gate1AppModelWorkflowTests/testPDFOne', 'SourceLinkImportTests/testSubstack', 'PKMWorkflowTests'],
            ['Gate1AppModelWorkflowTests', 'SpokenMarginsAppTests/PKMWorkflowTests'])
        self.assertEqual(selectors, ['SourceLinkImportTests/testSubstack', 'PKMWorkflowTests', 'Gate1AppModelWorkflowTests'])
        self.assertEqual(added, ['Gate1AppModelWorkflowTests'])
        self.assertEqual(lane.with_scope_classes(['A/test1'], []), (['A/test1'], []))
        self.assertEqual(lane.with_scope_classes([], ['A']), (['A'], ['A']))
        self.assertEqual(lane.with_scope_classes(['AB/test1'], ['A']), (['AB/test1', 'A'], ['A']))

    def test_the_classes_come_from_test_scope_old_or_new(self):
        self.assertEqual(lane.scope_classes({'app_tests': ['A', 'B'], 'lane_request': '/lane T3\ntests: C'}), ['A', 'B'])
        # next's test-scope.py from before #351 names them only in its suggested request.
        self.assertEqual(lane.scope_classes({'lane_request': '/lane T3\ntests: SpokenMarginsAppTests/A, '
                                                             'SpokenMarginsAppTests/B'}), ['A', 'B'])
        self.assertEqual(lane.scope_classes({'lane_request': None}), [])

    def run_t3(self, tests, classes):
        """run_t3 against the real test plans, stopping where it would take the simulator slot."""
        with mock.patch.object(lane, '_run_t3_grouped',
                               return_value=('PASS', 'sim', 'ran', ['boot line'], 'none', '')) as run:
            result = lane.run_t3(tests, 'r', Path('/tmp'), classes)
        return result, (run.call_args[0][0] if run.called else None)

    def test_a_request_naming_one_method_runs_the_whole_class_the_diff_touches(self):
        # #220: eleven requests named a few PDF methods of Gate1AppModelWorkflowTests; the class's
        # testPDFOutlineDestinations…MoreThanTwelveChapters failed on every head and never ran.
        (verdict, _, _, details, _, _), grouped = self.run_t3(
            ['Gate1AppModelWorkflowTests/testPDFOutlineDestinationsBypassContentsEntriesAndPreserveMoreThanTwelveChapters'],
            ['Gate1AppModelWorkflowTests'])
        self.assertEqual(grouped, {'app': ['SpokenMarginsAppTests/Gate1AppModelWorkflowTests']})
        self.assertRegex(details[0], r'^test-scope added for this diff: Gate1AppModelWorkflowTests \((\d+)\); \1 tests '
                                     r'beyond the request$')
        self.assertGreater(int(re.search(r'\((\d+)\)', details[0]).group(1)), 100)
        self.assertEqual((verdict, details[1:]), ('PASS', ['boot line']))

    def test_a_class_split_across_plans_runs_in_each_so_a_named_adapter_method_still_runs(self):
        # Review of #370: SupertonicSpeechTests is in AppBehavior except one method, which only AudioAdapters
        # runs. Naming that method on a branch touching the class dropped it into the class, and the class
        # went to the app plan alone, so the named test never ran and the run could still pass.
        method = 'SupertonicSpeechTests/testBundledRendererSynthesizesJamesAndLilyAndReusesSessions'
        (_, _, _, details, _, _), grouped = self.run_t3([method], ['SupertonicSpeechTests'])
        self.assertEqual(grouped, {'app': ['SpokenMarginsAppTests/SupertonicSpeechTests'],
                                   'adapters': ['SpokenMarginsAppTests/SupertonicSpeechTests']})
        from test_inventory import plan_tests
        planned = [plan_tests(lane.ROOT, name) for name in lane.PLANS.values()]
        runs = sum(1 for tests in planned for t in tests if t.startswith('SpokenMarginsAppTests/SupertonicSpeechTests/'))
        self.assertIn(f'SupertonicSpeechTests ({runs})', details[0])  # the count is what the plans will run

    def test_a_misspelled_method_still_fails_even_when_its_class_is_added(self):
        (verdict, _, _, details, _, _), grouped = self.run_t3(['Gate1AppModelWorkflowTests/testNope'],
                                                              ['Gate1AppModelWorkflowTests'])
        self.assertEqual((verdict, grouped), ('FAIL', None))
        self.assertIn('Gate1AppModelWorkflowTests/testNope', details[0])

    def test_a_suggested_class_no_plan_runs_is_reported_not_failed(self):
        (verdict, _, _, details, _, _), grouped = self.run_t3(['PKMWorkflowTests'], ['NotARealTestClass'])
        self.assertEqual((verdict, grouped), ('PASS', {'app': ['SpokenMarginsAppTests/PKMWorkflowTests']}))
        self.assertEqual(details[0], 'test-scope suggested, but no app test plan runs: NotARealTestClass')
        (verdict, _, _, details, _, _), grouped = self.run_t3([], ['NotARealTestClass'])
        self.assertEqual((verdict, grouped, details[-1]), ('INCONCLUSIVE', None, 'Nothing to run.'))

    def test_an_empty_request_runs_the_diff_s_classes(self):
        (verdict, _, _, details, _, _), grouped = self.run_t3([], ['PKMWorkflowTests'])
        self.assertEqual(grouped, {'app': ['SpokenMarginsAppTests/PKMWorkflowTests']})
        self.assertTrue(details[0].startswith('test-scope added for this diff: PKMWorkflowTests ('))

    def test_each_plan_reports_how_long_it_took(self):
        now = [0.0]

        def run_plan(plan, selectors, output):
            now[0] += 912
            return {'status': 'verified', 'steps': [{'name': 'xcode-tests', 'tests': {'T/A/test1': {'status': 'passed'}}}]}

        with mock.patch.object(lane, 'time', mock.Mock(monotonic=lambda: now[0])):
            _, _, ran, _ = lane.run_plans({'app': ['T/A']}, run_plan, Path('/e'))
        self.assertEqual(ran, ['A (1 passed; app plan, build and tests, 15m12s)'])


class AutomergeTests(unittest.TestCase):
    """The automerge label runs what the PR's diff needs (test-scope.py's tier)."""

    def run_checks(self, tier, fast='PASS', t2='PASS', too_big=()):
        calls = []

        def fake_fast(evidence):
            calls.append('fast')
            return fast, [] if fast == 'PASS' else [f'host tests {fast}']

        def fake_t2(evidence):
            calls.append('t2')
            return t2, f'simulator build ({t2.lower()})', []

        result = lane.run_automerge({'tier': tier, 'why': ['x']}, Path('/e'), fast=fake_fast, t2=fake_t2,
                                    ratchet=lambda: list(too_big))
        return result, calls

    def test_a_hot_file_above_its_ceiling_fails_before_any_build(self):
        (verdict, where, ran, details), calls = self.run_checks('T2', too_big=['Gate1AppModel.swift would be 9 lines'])
        self.assertEqual((verdict, where, calls), ('FAIL', 'no build', []))
        self.assertIn('hot-file ratchet — Gate1AppModel.swift would be 9 lines', details[-1])

    def test_docs_research_and_server_only_diffs_build_nothing(self):
        (verdict, where, ran, details), calls = self.run_checks('T0')
        self.assertEqual((verdict, where, calls), ('PASS', 'no build', []))
        self.assertIn('test-scope: T0', details[0])

    def test_a_host_only_diff_runs_the_host_tests_and_no_app_build(self):
        (verdict, _, ran, details), calls = self.run_checks('T1')
        self.assertEqual((verdict, calls), ('PASS', ['fast']))
        self.assertIn('no app build', details[-1])

    def test_a_diff_that_reaches_the_app_runs_the_host_tests_then_both_builds(self):
        for tier in ('T2', 'T3'):
            with self.subTest(tier=tier):
                (verdict, _, ran, _), calls = self.run_checks(tier, t2='FAIL')
                self.assertEqual((verdict, calls), ('FAIL', ['fast', 't2']))
                self.assertIn('host tests (--plan fast): passed; simulator build (fail)', ran)

    def test_failing_host_tests_stop_before_the_builds(self):
        for fast in ('FAIL', 'INCONCLUSIVE'):
            with self.subTest(fast=fast):
                (verdict, _, _, _), calls = self.run_checks('T2', fast=fast)
                self.assertEqual((verdict, calls), (fast, ['fast']))

    def test_the_host_tests_pass_only_when_verify_tests_says_verified(self):
        def runner_writing(status, code):
            def run(command, log, timeout):
                output = Path(command[command.index('--output') + 1])
                output.mkdir(parents=True, exist_ok=True)
                (output / 'manifest.json').write_text(f'{{"status": "{status}"}}')
                log.write('failed: SharingTests\n')
                return code
            return run

        for status, code, expected in (('verified', 0, 'PASS'), ('failed_or_incomplete', 1, 'FAIL'),
                                       ('failed_or_incomplete', 0, 'FAIL'), ('verified', None, 'INCONCLUSIVE')):
            with self.subTest(status=status, code=code), tempfile.TemporaryDirectory() as folder:
                verdict, details = lane.run_fast(Path(folder), runner=runner_writing(status, code))
                self.assertEqual(verdict, expected)


class MergeTests_Runner(unittest.TestCase):
    """The runner merges what it passes (decision 3): blockers, order, retries. Git is faked here;
    PushTests below uses real git."""

    SCOPE = {'tier': 'T2', 'why': ['app UI'], 'files': [{'path': 'App/X.swift', 'category': 'app-ui'}]}

    def run_auto(self, github, verdicts=('PASS',), pushes=(True,), scope=None, comments=(), moved=False,
                 automerge=None):
        events = []
        pushes = list(pushes)

        def build(tree, base, head, pr, title):
            events.append('build')
            return f'm{len([e for e in events if e == "build"])}' + '0' * 39, []

        def push(tree, sha, base):
            events.append(f'push {sha[:2]}')
            ok = pushes.pop(0)
            return ok, '' if ok else '! [rejected] (fetch first)'

        original_comment = github.comment

        def comment(body):
            events.append('comment')
            return original_comment(body)

        github.comment = comment
        if moved:
            github.head = NEWER
        verdicts = list(verdicts)
        with tempfile.TemporaryDirectory() as folder, \
                mock.patch.object(lane, 'build_merge_commit', side_effect=build), \
                mock.patch.object(lane, 'push_merge', side_effect=push), \
                mock.patch.object(lane, 'fetch_base', side_effect=lambda tree, base: NEWER), \
                mock.patch.object(lane, 'sweep_merge_audit', side_effect=lambda tree, base: events.append('sweep')), \
                mock.patch.object(lane, 'warm_build_folders', return_value='build folders: warm (SessionKit test)'), \
                mock.patch.object(lane, 'diff_scope', return_value=scope or self.SCOPE), \
                mock.patch.object(lane, 'run_automerge', side_effect=automerge or (
                    lambda scope, evidence, **_: (verdicts.pop(0), 'x', 'host tests; builds', []))):
            result = lane.run_auto(github, {'title': 'T'}, 5, 'next', HEAD, MERGE, Path(folder), list(comments))
        return result, events

    def test_a_pass_posts_the_merge_check_then_pushes_the_tested_commit(self):
        github = FakeGitHub(labels=('automerge',))
        (verdict, _, _, details), events = self.run_auto(github)
        self.assertEqual(verdict, 'PASS')
        self.assertEqual(events, ['build', 'comment', 'push m1', 'sweep'])  # the check is on the PR before the merge
        self.assertTrue(github.posted[0].startswith(f'**Merge check (triage desk) on `{HEAD[:7]}`: PASS.**'))
        import merge_audit  # the comment satisfies the merge audit's rule
        self.assertTrue(merge_audit.has_merge_check([dict(body=github.posted[0], created_at='2026-09-29T20:00:00Z')],
                                                    HEAD, '2026-09-29T20:00:01Z'))
        self.assertIn('merged into next as m100000', details[-1])

    def test_a_fail_or_inconclusive_never_merges(self):
        for verdict in ('FAIL', 'INCONCLUSIVE'):
            with self.subTest(verdict=verdict):
                github = FakeGitHub(labels=('automerge',))
                (got, _, _, _), events = self.run_auto(github, verdicts=(verdict,))
                self.assertEqual((got, events, github.posted), (verdict, ['build'], []))

    def test_workflow_and_lane_changes_and_unaudited_risky_changes_go_to_the_desk(self):
        cases = {
            '.github/workflows/lane.yml': 'docs',
            'scripts/lane-runner.py': 'scripts',
            'scripts/lane_sim.py': 'scripts',
        }
        for path, category in cases.items():
            with self.subTest(path=path):
                scope = {'tier': 'T1', 'why': [], 'files': [{'path': path, 'category': category}]}
                github = FakeGitHub(labels=('automerge',))
                (verdict, _, _, details), events = self.run_auto(github, scope=scope)
                self.assertEqual((verdict, events), ('PASS', ['build']))
                self.assertIn('not merged by the runner: it changes the lane or its workflows', details[-1])
        risky = {'tier': 'T2', 'why': [], 'files': [{'path': 'Packages/SessionKit/Sources/SessionKitSharing/A.swift',
                                                        'category': 'packet'}]}
        (_, _, _, details), events = self.run_auto(FakeGitHub(labels=('automerge',)), scope=risky)
        self.assertEqual(events, ['build'])
        self.assertIn('it touches packets and has no "Codex audit (Astra)" comment yet', details[-1])
        for audit in ('**Codex audit (Astra) on `aaaaaaa`**\n\nNo blocking findings.',
                      '## Codex audit (gpt-6-astra, high)\n\nAudited `aaaaaaaa`.\n\nNo findings.'):
            with self.subTest(audit=audit[:20]):
                (_, _, _, details), events = self.run_auto(
                    FakeGitHub(labels=('automerge',), comments=[comment(audit)]), scope=risky)
                self.assertEqual(events, ['build', 'comment', 'push m1', 'sweep'])
        mention = [comment('Waiting on the Codex audit (Astra) for this one.')]  # not an audit: not its first line
        (_, _, _, _), events = self.run_auto(FakeGitHub(labels=('automerge',), comments=mention), scope=risky)
        self.assertEqual(events, ['build'])

    RISKY = {'tier': 'T2', 'why': [], 'files': [{'path': 'Packages/SessionKit/Sources/SessionKitSharing/A.swift',
                                                   'category': 'packet'}]}

    def audited(self, *audits):
        return self.run_auto(FakeGitHub(labels=('automerge',), comments=[comment(a) for a in audits]), scope=self.RISKY)

    def test_an_audit_of_an_older_commit_does_not_clear_the_head(self):
        # #441: a clean audit on commit A cleared a later push of commit B that nobody audited.
        (verdict, _, _, details), events = self.audited('**Codex audit (Astra) on `1234567`**\n\nNo blocking findings.')
        self.assertEqual((verdict, events), ('PASS', ['build']))
        self.assertIn('the audit is on `1234567`, the head is `aaaaaaa`', details[-1])

    def test_an_audit_of_the_head_with_blocking_findings_holds_it(self):
        # #441: an audit that found problems cleared the PR as soon as automerge was re-added.
        (_, _, _, details), events = self.audited(
            '**Codex audit (Astra) on `aaaaaaa`**\n\n### Blocking findings\n1. The packet drops the anchor.')
        self.assertEqual(events, ['build'])
        self.assertIn('the Codex audit on the head `aaaaaaa` has blocking findings', details[-1])

    def test_findings_that_only_mention_no_findings_elsewhere_still_hold(self):
        # The #414 audit's form: numbered findings, then "Nothing else found …" and "No packet or database changes."
        audit = ('**Codex audit (Astra) on `aaaaaaa`**\n\n1. **Plausible: one stop reason is shared by every item.** '
                 '`A.swift:626`\n   - Smallest fix: keep it per target; no findings elsewhere.\n\nNothing else found. '
                 'No packet or database changes.\n\nChecked by the SM Codex audit task; Codex ran read-only.')
        self.assertEqual(self.audited(audit)[1], ['build'])
        clean = ('**Codex audit (Astra) on `aaaaaaa`**\n\nNo blocking findings on correctness, owner data, or Build 29 '
                 'compatibility. One plausible gap against "Done when":\n1. **Plausible: …**')
        self.assertEqual(self.audited(clean)[1], ['build', 'comment', 'push m1', 'sweep'])

    def test_the_newest_audit_of_the_head_decides(self):
        blocked = '**Codex audit (Astra) on `aaaaaaa`**\n\n### Blocking findings\n1. Wrong.'
        clean = '**Codex audit (Astra) on `aaaaaaa`**\n\nNo blocking findings.'
        self.assertEqual(self.audited(clean, blocked)[1], ['build'])
        self.assertEqual(self.audited(blocked, clean)[1], ['build', 'comment', 'push m1', 'sweep'])

    def test_a_manual_audit_counts_only_if_it_names_the_head(self):
        (_, _, _, details), events = self.audited('## Codex audit (gpt-6-astra, high)\n\nAudited the PR. No findings.')
        self.assertEqual(events, ['build'])
        self.assertIn('has no Codex audit naming its head `aaaaaaa`', details[-1])

    def test_an_audit_landing_while_the_run_tested_counts(self):
        github = FakeGitHub(labels=('automerge',))

        def automerge(scope, evidence, **_):
            github._comments.append(comment('**Codex audit (Astra) on `aaaaaaa`**\n\nNo blocking findings.'))
            return 'PASS', 'x', 'host tests; builds', []

        self.assertEqual(self.run_auto(github, scope=self.RISKY, automerge=automerge)[1],
                         ['build', 'comment', 'push m1', 'sweep'])

    def t3_report(self, verdict, commit=HEAD, url='https://example.test/t3'):
        return runner_report(verdict, lane.identity('T3', commit, MERGE, ['SupertonicSpeechTests']), url=url)

    T3_REQUEST = comment('/lane T3\ncommit: aaaaaaa\ntests: SupertonicSpeechTests')

    def test_a_t3_fail_or_inconclusive_on_the_pr_holds_the_merge(self):
        # #408: the T3 report said FAIL (build-for-testing exit 70, no test ran) and the automerge run
        # merged minutes later on host tests and builds alone.
        for verdict in ('FAIL', 'INCONCLUSIVE'):
            with self.subTest(verdict=verdict):
                github = FakeGitHub(labels=('automerge',), comments=[self.T3_REQUEST, self.t3_report(verdict)])
                (got, _, _, details), events = self.run_auto(github)
                self.assertEqual((got, events, github.posted), (verdict, ['build'], []))
                self.assertIn(f'not merged: the newest T3 lane report on this PR is {verdict} (on {HEAD[:7]}: '
                              'https://example.test/t3)', details[-1])

    def test_a_t3_request_still_waiting_for_its_report_holds_the_merge(self):
        old_pass = self.t3_report('PASS', commit=NEWER)
        for comments in ([self.T3_REQUEST], [old_pass, self.T3_REQUEST],
                         [self.T3_REQUEST, runner_report('PASS', lane.identity('auto', HEAD, MERGE, []))]):
            with self.subTest(comments=len(comments)):
                github = FakeGitHub(labels=('automerge',), comments=comments)
                (got, _, _, details), events = self.run_auto(github)
                self.assertEqual((got, events), ('INCONCLUSIVE', ['build']))
                self.assertIn('newest /lane T3 request has no lane report yet', details[-1])

    def test_a_t3_report_read_at_merge_time_counts_not_the_one_read_at_the_start(self):
        github = FakeGitHub(labels=('automerge',), comments=[self.T3_REQUEST])
        github._comments.append(self.t3_report('FAIL'))  # landed while the automerge checks ran
        (got, _, _, _), events = self.run_auto(github, comments=[self.T3_REQUEST])
        self.assertEqual((got, events), ('FAIL', ['build']))

    def test_a_fail_on_an_earlier_head_holds_until_a_newer_t3_passes(self):
        failed = [self.T3_REQUEST, self.t3_report('FAIL', commit=NEWER)]
        (got, _, _, _), events = self.run_auto(FakeGitHub(labels=('automerge',), comments=failed))
        self.assertEqual((got, events), ('FAIL', ['build']))
        passed = failed + [self.T3_REQUEST, self.t3_report('PASS')]
        (got, _, _, _), events = self.run_auto(FakeGitHub(labels=('automerge',), comments=passed))
        self.assertEqual((got, events), ('PASS', ['build', 'comment', 'push m1', 'sweep']))

    def test_a_t3_pass_or_an_identical_request_already_passed_lets_it_merge(self):
        passed = [self.T3_REQUEST, self.t3_report('PASS')]
        identical = passed + [self.T3_REQUEST, comment(
            f'Lane: identical T3 request for {HEAD[:7]} already reported (PASS): https://example.test/t3\n{lane.NOTE}',
            login='github-actions[bot]')]
        for comments in (passed, identical, [comment('/lane T2'), runner_report('FAIL', lane.identity('T2', HEAD, MERGE, []))]):
            with self.subTest(comments=len(comments)):
                (got, _, _, _), events = self.run_auto(FakeGitHub(labels=('automerge',), comments=comments))
                self.assertEqual((got, events), ('PASS', ['build', 'comment', 'push m1', 'sweep']))

    def test_lane_tests_themselves_are_not_desk_only(self):
        scope = {'tier': 'T1', 'why': [], 'files': [{'path': 'scripts/tests/test_lane_runner.py', 'category': 'scripts'}]}
        self.assertEqual(lane.merge_blockers(scope, [], HEAD), [])

    def test_a_pr_that_moved_or_lost_its_label_while_tested_is_not_merged(self):
        (_, _, _, details), events = self.run_auto(FakeGitHub(labels=('automerge',)), moved=True)
        self.assertEqual(events, ['build'])
        (_, _, _, details), events = self.run_auto(FakeGitHub(labels=()))
        self.assertEqual(events, ['build'])
        self.assertIn('lost the automerge label', details[-1])

    def test_a_refused_push_means_next_moved_so_it_tests_again_on_the_newest_next(self):
        github = FakeGitHub(labels=('automerge',))
        (verdict, _, _, details), events = self.run_auto(github, verdicts=('PASS', 'PASS'), pushes=(False, True))
        self.assertEqual(events, ['build', 'comment', 'push m1', 'build', 'comment', 'push m2', 'sweep'])
        self.assertIn('attempt 1: the push to next was refused', ' '.join(details))
        self.assertIn('merged into next as m200000', details[-1])

    def test_the_retry_after_a_refused_push_runs_the_host_tests_in_a_folder_of_its_own(self):
        # #404: the retry handed verify-tests.py the first attempt's --output folder, which it refuses
        # to reuse, so a PR whose first attempt passed was reported FAIL (#379, #363, #399).
        outputs = []

        def verify_tests(command, log, timeout):  # verify-tests.py's own start: a crash there is exit 1
            output = Path(command[command.index('--output') + 1])
            outputs.append(output)
            try:
                run = verification.Run(output, 'fast')
            except FileExistsError as error:
                log.write(f'FileExistsError: {error}\n')
                return 1
            run.manifest['status'] = 'verified'
            run.save()
            return 0

        real_automerge = lane.run_automerge

        def automerge(scope, evidence, **kwargs):
            return real_automerge(scope, evidence, fast=lambda e: lane.run_fast(e, runner=verify_tests), **kwargs)

        host_only = {'tier': 'T1', 'why': ['scripts'], 'files': [{'path': 'scripts/x.py', 'category': 'scripts'}]}
        with mock.patch.object(verification, 'input_identity', return_value='x'):
            (verdict, _, _, details), events = self.run_auto(FakeGitHub(labels=('automerge',)), scope=host_only,
                                                             pushes=(False, True), automerge=automerge)
        self.assertEqual((verdict, details[-1]), ('PASS', 'merged into next as m200000'), details)
        self.assertEqual(events, ['build', 'comment', 'push m1', 'build', 'comment', 'push m2', 'sweep'])
        first, retry = outputs
        self.assertEqual(first.name, 'fast')  # the first attempt's evidence stays where it always was
        self.assertEqual(retry, first.parent / 'attempt-2' / 'fast')

    def test_a_push_refused_for_another_reason_stops_at_once(self):
        # A queued job with a lane.yml from before #382 has a read-only token: re-testing can't help.
        github = FakeGitHub(labels=('automerge',))
        with mock.patch.object(lane, 'next_moved', return_value=False):
            (verdict, _, _, details), events = self.run_auto(github, pushes=(False,))
        self.assertEqual(events, ['build', 'comment', 'push m1'])
        self.assertIn('not merged: the push to next failed', details[-1])
        self.assertTrue(lane.next_moved(' ! [rejected]        abc -> next (fetch first)'))
        self.assertTrue(lane.next_moved(' ! [rejected]        abc -> next (non-fast-forward)'))
        self.assertFalse(lane.next_moved('remote: Permission to uncomposed/x.git denied to github-actions[bot].'))
        self.assertFalse(lane.next_moved('fatal: unable to access \'https://github.com/x.git/\': The requested URL returned error: 403'))

    def test_it_gives_up_after_three_refused_pushes(self):
        github = FakeGitHub(labels=('automerge',))
        (verdict, _, _, details), events = self.run_auto(github, verdicts=('PASS',) * 3, pushes=(False,) * 3)
        self.assertEqual(events.count('build'), 3)
        self.assertIn('not merged: next kept moving (3 attempts)', details[-1])

    def test_pr_code_never_sees_the_token_but_the_runner_git_does(self):
        with mock.patch.dict('os.environ', {'GH_TOKEN': 'secret-token', 'GITHUB_TOKEN': 'other'}), \
                tempfile.TemporaryDirectory() as folder:
            log_path = Path(folder) / 'log'
            with log_path.open('w') as log:
                code = lane.run_bounded([sys.executable, '-c', 'import os; print(os.environ.get("GH_TOKEN"), '
                                         'os.environ.get("GITHUB_TOKEN"))'], log, 30)
            self.assertEqual((code, log_path.read_text().strip()), (0, 'None None'))
            command = ' '.join(lane.git_with_token(Path(folder)))
            self.assertIn('extraheader=AUTHORIZATION: basic ', command)
            self.assertNotIn('secret-token', command)


class WarmBuildTests(unittest.TestCase):
    """Build folders kept warm between runner jobs, keyed by the SessionKit tree, with real git."""

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        root = Path(self.temporary.name)
        self.tree, self.cache = root / 'tree', root / 'cache'
        self.git = ['git', '-c', 'user.name=t', '-c', 'user.email=t@example.com', '-C', str(self.tree)]
        (self.tree / 'Packages/SessionKit/Sources').mkdir(parents=True)
        subprocess.run(['git', 'init', '-q', str(self.tree)], check=True)
        (self.tree / '.gitignore').write_text((SCRIPTS.parent / '.gitignore').read_text())  # the repo's own rules
        self.commit('Packages/SessionKit/Sources/A.swift', 'struct A {}\n')
        self.addCleanup(lane._WARM_LOCKS.clear)

    def commit(self, path, text):
        (self.tree / path).parent.mkdir(parents=True, exist_ok=True)
        (self.tree / path).write_text(text)
        subprocess.run(self.git + ['add', '.'], check=True)
        subprocess.run(self.git + ['commit', '-q', '-m', path], check=True)

    def warm(self, free=10**12):
        line = lane.warm_build_folders(self.tree, root=self.cache, free=lambda path: free)
        for held in lane._WARM_LOCKS.values():
            held.close()
        lane._WARM_LOCKS.clear()  # as if the job ended
        return line

    def test_the_build_folders_link_to_a_cache_that_survives_the_checkout(self):
        self.assertIn('cold, new cache', self.warm())
        for link in (self.tree / '.build', self.tree / 'Packages/SessionKit/.build'):
            self.assertTrue(link.is_symlink(), link)
        (self.tree / '.build' / 'dd-simulator').mkdir()
        (self.tree / '.build' / 'dd-simulator' / 'product').write_text('built')
        subprocess.run(self.git + ['clean', '-ffdxq'], check=True)  # what actions/checkout does
        self.assertFalse((self.tree / '.build').exists())
        self.assertIn('warm', self.warm())
        self.assertEqual((self.tree / '.build' / 'dd-simulator' / 'product').read_text(), 'built')

    def test_an_app_only_change_stays_warm_and_a_sessionkit_change_starts_a_new_cache(self):
        first = self.warm()
        self.commit('App/View.swift', 'struct V {}\n')
        self.assertTrue(self.warm().startswith('build folders: warm'), 'app-only change')
        self.commit('Packages/SessionKit/Sources/A.swift', 'struct A { var b = 1 }\n')
        second = self.warm()
        self.assertIn('cold, new cache', second)
        self.assertNotEqual(first.split('SessionKit ')[1], second.split('SessionKit ')[1])

    def caches(self):
        return sorted(self.cache.glob('*/sk-*'))

    def test_it_keeps_at_most_two_caches_and_never_goes_below_the_disk_floor(self):
        for n in range(3):
            self.commit('Packages/SessionKit/Sources/A.swift', f'struct A{n} {{}}\n')
            self.warm()
            time.sleep(0.01)
        self.assertEqual(len(self.caches()), lane.WARM_KEEP)
        self.assertIn('cold (less than 15 GB free)', self.warm(free=10**9))
        self.assertEqual(len(self.caches()), 1)  # this key's

    def test_a_cache_in_use_by_another_runner_job_is_left_alone(self):
        import fcntl
        self.warm()
        cache = self.caches()[0]
        with open(cache / '.lock', 'a+') as other:
            fcntl.flock(other, fcntl.LOCK_EX | fcntl.LOCK_NB)
            (self.tree / '.build').unlink()
            self.assertIn('in use by another runner job', self.warm())
            self.assertFalse((self.tree / '.build').exists())  # the job builds cold in its own tree


    # #405: the two runners share this cache folder but check out to different paths, and DerivedData and
    # SwiftPM's state record absolute paths. A cache one runner built, reused by the other, lost Xcode's VFS
    # overlay (exit 65 on T2) and the onnxruntime binary artifact (host tests ran nothing).
    def test_each_checkout_gets_its_own_caches(self):
        other = Path(self.temporary.name) / 'runner-2' / 'tree'
        subprocess.run(['git', 'clone', '-q', str(self.tree), str(other)], check=True)
        self.warm()
        line = lane.warm_build_folders(other, root=self.cache, free=lambda path: 10**12)
        self.assertIn('cold, new cache', line, 'the same SessionKit tree in another checkout')
        self.assertNotEqual((self.tree / '.build').resolve(), (other / '.build').resolve())

    def test_a_project_change_starts_a_new_cache(self):
        self.commit('SpokenMarginsNative.xcodeproj/project.pbxproj', '// one layout\n')
        self.warm()
        self.commit('SpokenMarginsNative.xcodeproj/project.pbxproj', '// synchronized folders\n')
        self.assertIn('cold, new cache', self.warm())

    def swiftpm_state(self, folder):
        artifact = self.tree / 'Packages/SessionKit/.build/artifacts/onnxruntime-swift-package-manager' \
            / 'onnxruntime/onnxruntime.xcframework'
        state = {'object': {'artifacts': [{'path': str(artifact), 'targetName': 'onnxruntime'}]}, 'version': 6}
        (folder / 'workspace-state.json').write_text(json.dumps(state))
        return artifact

    def test_a_cache_missing_a_binary_artifact_starts_again_cold(self):
        self.warm()
        build = self.tree / 'Packages/SessionKit/.build'
        self.swiftpm_state(build)
        (build / 'debug').mkdir()
        line = self.warm()
        self.assertTrue(line.startswith('build folders: cold'), line)
        self.assertIn('onnxruntime.xcframework', line)
        self.assertFalse((build / 'debug').exists())
        self.assertFalse((build / 'workspace-state.json').exists())

    def test_a_cache_whose_binary_artifacts_are_all_there_stays_warm(self):
        self.warm()
        build = self.tree / 'Packages/SessionKit/.build'
        self.swiftpm_state(build).mkdir(parents=True)
        self.assertTrue(self.warm().startswith('build folders: warm'))

    def test_the_app_builds_package_state_is_checked_too(self):
        self.warm()
        packages = self.tree / '.build/dd-simulator/SourcePackages'
        packages.mkdir(parents=True)
        self.swiftpm_state(packages)
        self.assertIn('onnxruntime.xcframework', self.warm())
        self.assertFalse(packages.exists())

    def test_the_derived_data_both_builds_shared_is_removed_from_a_warm_cache(self):
        self.warm()
        (self.tree / '.build/dd/Build').mkdir(parents=True)
        (self.tree / '.build/dd-simulator/Build').mkdir(parents=True)
        self.assertTrue(self.warm().startswith('build folders: warm'))
        self.assertFalse((self.tree / '.build/dd').exists())
        self.assertTrue((self.tree / '.build/dd-simulator/Build').is_dir())

    def test_the_old_shared_caches_are_removed_when_idle(self):
        import fcntl
        idle, busy = self.cache / 'sk-1a29b9c8d31d', self.cache / 'sk-1ad43f80e405'
        for old in (idle, busy):
            (old / 'root/dd').mkdir(parents=True)
        with open(busy / '.lock', 'a+') as other:
            fcntl.flock(other, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.warm()
        self.assertFalse(idle.exists())
        self.assertTrue(busy.exists())  # a job from before this change still uses it
        self.warm()
        self.assertFalse(busy.exists())


class BuildRunnerRoomTests(unittest.TestCase):
    """The second runner builds only while the Mac has room (item 5)."""

    def wait(self, jobs, pressures, frees, max_wait=100):
        now = [0.0]
        states = {'jobs': list(jobs), 'pressure': list(pressures), 'free': list(frees)}
        take = lambda key: (states[key].pop(0) if len(states[key]) > 1 else states[key][0])
        with open(os.devnull, 'w') as quiet:
            return lane.wait_for_room_to_build(
                out=quiet, max_wait=max_wait, poll=10, clock=lambda: now[0],
                sleep=lambda seconds: now.__setitem__(0, now[0] + seconds),
                simulator_jobs=lambda: take('jobs'), pressure=lambda: take('pressure'), free=lambda: take('free')), now[0]

    def test_it_starts_at_once_when_the_mac_has_room(self):
        self.assertEqual(self.wait([0], [1], [10**12]), (None, 0.0))

    def test_it_waits_for_the_simulator_job_pressure_and_disk_to_clear(self):
        result, waited = self.wait([1, 1, 0], [2, 2, 2, 1], [10**9, 10**12])
        self.assertIsNone(result)
        self.assertEqual(waited, 30.0)

    def test_it_gives_up_after_its_limit_and_says_why(self):
        result, _ = self.wait([1], [2], [10**9], max_wait=60)
        self.assertIn('waited 1m00s for room', result)
        for reason in ('a simulator job is running', 'memory pressure is above normal', 'less than 20 GB of disk is free'):
            self.assertIn(reason, result)


class PushTests(unittest.TestCase):
    """Building and pushing the merge commit, with real git and a bare origin."""

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        root = Path(self.temporary.name)
        self.origin, self.tree, self.other = root / 'origin.git', root / 'tree', root / 'other'
        self.git = ['git', '-c', 'user.name=t', '-c', 'user.email=t@example.com', '-c', 'init.defaultBranch=next']
        subprocess.run(self.git + ['init', '-q', '--bare', str(self.origin)], check=True)
        subprocess.run(self.git + ['clone', '-q', str(self.origin), str(self.other)], check=True, capture_output=True)
        self.commit(self.other, 'shared.txt', 'one\n')
        subprocess.run(self.git + ['-C', str(self.other), 'push', '-q', 'origin', 'HEAD:next'], check=True)
        subprocess.run(self.git + ['clone', '-q', '-b', 'next', str(self.origin), str(self.tree)], check=True)
        subprocess.run(self.git + ['-C', str(self.tree), 'checkout', '-q', '-b', 'pr'], check=True)

    def commit(self, where, name, text):
        (where / name).write_text(text)
        subprocess.run(self.git + ['-C', str(where), 'add', '.'], check=True)
        subprocess.run(self.git + ['-C', str(where), 'commit', '-q', '-m', name], check=True)

    def rev(self, where, ref):
        return subprocess.check_output(['git', '-C', str(where), 'rev-parse', ref], text=True).strip()

    def test_the_merge_commit_has_next_first_and_lands_by_a_plain_push(self):
        self.commit(self.tree, 'pr.txt', 'pr\n')
        head = self.rev(self.tree, 'HEAD')
        lane.fetch_base(self.tree, 'next')
        sha, conflicts = lane.build_merge_commit(self.tree, 'next', head, 5, 'A change')
        self.assertEqual(conflicts, [])
        parents = subprocess.check_output(['git', '-C', str(self.tree), 'rev-list', '--parents', '-n', '1', sha],
                                          text=True).split()[1:]
        self.assertEqual(parents, [self.rev(self.tree, 'origin/next'), head])
        self.assertIn('Merge pull request #5: A change',
                      subprocess.check_output(['git', '-C', str(self.tree), 'log', '-1', '--format=%B', sha], text=True))
        self.assertTrue(lane.push_merge(self.tree, sha, 'next')[0])
        self.assertEqual(self.rev(self.origin, 'next'), sha)

    def test_the_push_is_refused_when_next_moved_after_the_test(self):
        self.commit(self.tree, 'pr.txt', 'pr\n')
        head = self.rev(self.tree, 'HEAD')
        lane.fetch_base(self.tree, 'next')
        sha, _ = lane.build_merge_commit(self.tree, 'next', head, 5, 'A change')
        self.commit(self.other, 'other.txt', 'someone else merged\n')
        subprocess.run(self.git + ['-C', str(self.other), 'push', '-q', 'origin', 'HEAD:next'], check=True)
        moved = self.rev(self.origin, 'next')
        pushed, message = lane.push_merge(self.tree, sha, 'next')
        self.assertFalse(pushed)
        self.assertIn('rejected', message)
        self.assertTrue(lane.next_moved(message), message)  # so the runner tests again
        self.assertEqual(self.rev(self.origin, 'next'), moved)  # nothing untested landed

    def test_a_conflict_names_the_files_and_leaves_the_tree_clean(self):
        self.commit(self.tree, 'shared.txt', 'pr side\n')
        head = self.rev(self.tree, 'HEAD')
        self.commit(self.other, 'shared.txt', 'next side\n')
        subprocess.run(self.git + ['-C', str(self.other), 'push', '-q', 'origin', 'HEAD:next'], check=True)
        lane.fetch_base(self.tree, 'next')
        self.assertEqual(lane.build_merge_commit(self.tree, 'next', head, 5, 'x'), (None, ['shared.txt']))
        self.assertEqual(subprocess.check_output(['git', '-C', str(self.tree), 'status', '--porcelain'], text=True), '')


class MainFlowTests(unittest.TestCase):
    def run_main(self, github, event_head=HEAD, verdict='PASS', *extra, evidence=None, t2=None):
        with tempfile.TemporaryDirectory() as temporary, \
                mock.patch.object(lane, 'GitHub', return_value=github), \
                mock.patch.dict('os.environ', {'GH_REPO': 'o/r', 'SM_LANE_EVIDENCE_DIR': evidence or temporary,
                                               # set, not inherited: runner two's own .env has role=build,
                                               # and these tests run inside a lane job, maybe a re-run
                                               'SM_LANE_RUNNER_ROLE': self.role, 'GITHUB_RUN_ATTEMPT': self.attempt}), \
                mock.patch.object(lane, 'run_t2', side_effect=t2,
                                  return_value=(verdict, 'simulator build (pass), device build (pass)', [])), \
                mock.patch.object(lane, 'sweep_runner_simulators'), \
                mock.patch.object(lane, 'fetch_base', return_value=MERGE), \
                mock.patch.object(lane, 'merge_base_branch', return_value=self.conflicts), \
                mock.patch.object(lane, 'link_tools'), mock.patch('builtins.print'), \
                mock.patch.object(lane, 'warm_build_folders', return_value='build folders: warm (SessionKit test)'):
            return lane.main(['--pr', '5', '--event-head', event_head, '--run-id', '42', *extra])

    conflicts = []
    role = ''  # the main runner, unless a test says otherwise
    attempt = '1'

    def test_a_rerun_of_a_job_gets_its_own_report_name_and_evidence_folder(self):
        # After #419 merged, re-runs of runs 36711256675 and 36710023344 kept their run ids, so
        # verify-tests.py found the first attempt's --output folder and stopped within seconds: exit 1,
        # and no error line in the report.
        def t2(evidence):
            (evidence / 'fast').mkdir()  # verify-tests.py refuses an --output folder that exists
            return 'PASS', 'simulator build (pass), device build (pass)', []
        with tempfile.TemporaryDirectory() as evidence:
            reports = []
            for self.attempt in ('1', '2'):
                github = FakeGitHub(comments=[comment('/lane T2')])
                self.run_main(github, evidence=evidence, t2=t2)
                reports.append(github.posted[0])
        self.assertTrue(reports[0].startswith('Lane report pr5-r42 — PASS'), reports[0])
        self.assertTrue(reports[1].startswith('Lane report pr5-r42-a2 — PASS'), reports[1])

    def test_a_queued_t2_request_is_run_reported_and_relabelled(self):
        github = FakeGitHub(comments=[comment(f'/lane T2\ncommit: {HEAD[:7]}')])
        self.run_main(github)
        self.assertEqual(len(github.posted), 1)
        self.assertTrue(github.posted[0].startswith('Lane report pr5-r42 — PASS'))
        self.assertEqual(github.label_changes, [('lane:queued', 'lane:running'), ('lane:running', 'lane:done')])

    def test_an_older_queued_run_defers_to_the_newest_commit(self):
        github = FakeGitHub(head=NEWER, comments=[comment('/lane T2')])
        self.run_main(github, event_head=HEAD)
        self.assertEqual((github.posted, github.label_changes), ([], []))

    def test_a_request_on_a_commit_that_moved_says_what_was_tested(self):
        github = FakeGitHub(comments=[comment('/lane T2\ncommit: 1234567')])
        self.run_main(github)
        self.assertIn(f'requested 1234567, tested the newest commit {HEAD[:7]}', github.posted[0])

    def test_identical_requests_run_once_but_inconclusive_ones_run_again(self):
        github = FakeGitHub(comments=[comment('/lane T2')])
        self.run_main(github)
        github.labels.add('lane:queued')
        github._comments.append(comment('/lane T2'))
        self.run_main(github)
        self.assertTrue(github.posted[1].startswith('Lane: identical T2 request'))
        retry = FakeGitHub(comments=[comment('/lane T2')])
        self.run_main(retry, HEAD, 'INCONCLUSIVE')
        retry.labels.add('lane:queued')
        retry._comments.append(comment('/lane T2'))
        self.run_main(retry)
        self.assertTrue(retry.posted[1].startswith('Lane report pr5-r42 — PASS'))

    def outcome(self, github, verdict='PASS'):
        """What the runner handed the workflow (GITHUB_OUTPUT) for one run."""
        with tempfile.TemporaryDirectory() as folder:
            outputs = Path(folder) / 'outputs'
            outputs.write_text('')
            with mock.patch.dict('os.environ', {'GITHUB_OUTPUT': str(outputs)}):
                self.run_main(github, HEAD, verdict)
            return dict(line.split('=', 1) for line in outputs.read_text().splitlines())

    def test_the_workflow_gets_the_verdict_so_the_check_is_green_only_on_pass(self):
        # lane.yml's Verdict step fails unless verdict=PASS; reported=true keeps the tidy step quiet.
        for verdict in ('PASS', 'FAIL', 'INCONCLUSIVE'):
            with self.subTest(verdict=verdict):
                github = FakeGitHub(comments=[comment('/lane T2')])
                self.assertEqual(self.outcome(github, verdict), {'reported': 'true', 'verdict': verdict})
                self.assertTrue(github.posted[0].startswith(f'Lane report pr5-r42 — {verdict}'))

    def test_a_repeated_request_carries_the_earlier_verdict_so_a_fail_stays_red(self):
        github = FakeGitHub(comments=[comment('/lane T2')])
        self.run_main(github, HEAD, 'FAIL')
        github.labels.add('lane:queued')
        github._comments.append(comment('/lane T2'))
        self.assertEqual(self.outcome(github, 'PASS'), {'reported': 'true', 'verdict': 'FAIL'})
        self.assertIn('already reported (FAIL)', github.posted[-1])

    def test_nothing_is_handed_over_when_nothing_ran(self):
        self.assertEqual(self.outcome(FakeGitHub(comments=[])), {})
        self.assertEqual(self.outcome(FakeGitHub(head=NEWER, comments=[comment('/lane T2')])), {})

    def test_the_workflow_fails_its_verdict_step_and_tidies_only_when_nothing_was_reported(self):
        workflow = (Path(__file__).resolve().parents[2] / '.github/workflows/lane.yml').read_text()
        # Both jobs check out the Git LFS models: --plan fast's contracts check reads them (#301).
        self.assertEqual(workflow.count('lfs: true'), 2)
        self.assertEqual(workflow.count('persist-credentials: false'), 2)
        self.assertIn("if: steps.run.outputs.reported == 'true'", workflow)
        self.assertIn('if [ "$VERDICT" != PASS ]; then', workflow)
        self.assertIn("if: (failure() || cancelled()) && steps.run.outputs.reported != 'true'", workflow)

    def run_automerge_main(self, github, verdict='PASS'):
        # run_auto does real git in the runner's tree; here it is faked, so the tree is never touched.
        with mock.patch.object(lane, 'run_auto', return_value=(verdict, 'x', 'host tests; builds', [])) as run:
            self.run_main(github)
        return None, run

    def test_the_automerge_label_is_a_request_by_itself(self):
        github = FakeGitHub(labels=('automerge',))
        _, run = self.run_automerge_main(github)
        run.assert_called_once()
        self.assertTrue(github.posted[0].startswith('Lane report pr5-r42 — PASS'), github.posted)
        self.assertIn('tier auto', github.posted[0])
        self.assertEqual(github.label_changes, [])  # the lane:* labels belong to explicit requests

    def test_an_explicit_request_goes_before_the_automerge_checks(self):
        github = FakeGitHub(labels=('automerge', 'lane:queued'), comments=[comment('/lane T2')])
        _, run = self.run_automerge_main(github)
        run.assert_not_called()
        self.assertIn('tier T2', github.posted[0])

    def test_an_automerge_run_runs_again_even_for_the_same_head_and_next(self):
        # Re-adding the label is how to retry a PASS that didn't merge (no audit yet, next moved).
        github = FakeGitHub(labels=('automerge',))
        self.run_automerge_main(github, 'PASS')
        _, run = self.run_automerge_main(github)
        run.assert_called_once()
        self.assertEqual(len([b for b in github.posted if b.startswith('Lane report')]), 2)
        self.assertEqual(github.label_changes, [])

    def test_a_run_without_lane_queued_or_automerge_posts_nothing(self):
        github = FakeGitHub(labels=())
        self.run_main(github)
        self.assertEqual((github.posted, github.label_changes), ([], []))

    def run_mode(self, github, mode, role='', no_room=None):
        self.role = role
        self.addCleanup(setattr, self, 'role', '')
        with mock.patch.object(lane, 'run_auto', return_value=('PASS', 'x', 'host tests; builds', [])) as auto, \
                mock.patch.object(lane, 'run_t3', return_value=('PASS', 'x', 'T/A', [], 'none', '')) as t3, \
                mock.patch.object(lane, 'wait_for_room_to_build', return_value=no_room) as wait:
            self.run_main(github, HEAD, 'PASS', '--mode', mode)
        self.role = ''
        return auto, t3, wait

    def test_the_automerge_job_never_answers_a_lane_request(self):
        github = FakeGitHub(labels=('automerge', 'lane:queued'), comments=[comment('/lane T3\ntests: T/A')])
        auto, t3, _ = self.run_mode(github, 'auto')
        auto.assert_called_once()
        t3.assert_not_called()
        self.assertIn('tier auto', github.posted[0])
        self.assertEqual(github.label_changes, [])  # lane:queued stays for the lane job
        idle = FakeGitHub(labels=('lane:queued',), comments=[comment('/lane T3\ntests: T/A')])
        auto, t3, _ = self.run_mode(idle, 'auto')
        auto.assert_not_called()
        t3.assert_not_called()
        self.assertEqual((idle.posted, idle.label_changes), ([], []))

    def test_the_lane_job_never_runs_automerge(self):
        github = FakeGitHub(labels=('automerge',))
        auto, _, _ = self.run_mode(github, 'explicit')
        auto.assert_not_called()
        self.assertEqual(github.posted, [])

    def test_the_build_runner_waits_for_room_and_says_so_if_it_gives_up(self):
        github = FakeGitHub(labels=('automerge',))
        auto, _, wait = self.run_mode(github, 'auto', role='build', no_room='the build runner waited 1h30m00s for room: '
                                                                         'a simulator job is running')
        wait.assert_called_once()
        auto.assert_not_called()
        self.assertTrue(github.posted[0].startswith('Lane report pr5-r42 — INCONCLUSIVE'))
        self.assertIn('a simulator job is running. Push again', github.posted[0])
        main_runner = FakeGitHub(labels=('automerge',))
        auto, _, wait = self.run_mode(main_runner, 'auto')
        wait.assert_not_called()  # the main runner doesn't wait
        auto.assert_called_once()

    def test_an_automerge_cleanup_leaves_the_lane_labels_alone(self):
        github = FakeGitHub(labels=('lane:queued', 'automerge'))
        with mock.patch.object(lane, 'sweep_runner_simulators'):
            lane.cleanup(github, 'https://example.test/run', 'auto')
        self.assertEqual(github.label_changes, [])
        self.assertIn('automerge run stopped before reporting', github.posted[0])

    def test_requeueing_without_a_new_request_says_so_and_clears_the_label(self):
        github = FakeGitHub(comments=[comment('/lane T2')])
        self.run_main(github)
        github.labels = {'lane:queued'}
        self.run_main(github)
        self.assertIn('no `/lane T2` or `/lane T3` request comment newer', github.posted[-1])
        self.assertNotIn('lane:queued', github.labels)

    def test_a_waiting_t4_keeps_its_label_while_the_runner_answers_a_t2(self):
        for order in (['/lane T4\nrun: J1', '/lane T2'], ['/lane T2', '/lane T4\nrun: J1']):
            with self.subTest(order=order):
                github = FakeGitHub(comments=[comment(body) for body in order])
                self.run_main(github)
                self.assertTrue(github.posted[0].startswith('Lane report'))
                self.assertIn('lane:queued', github.labels)
                self.assertNotIn(('lane:queued', 'lane:running'), github.label_changes)

    def test_only_t4_requests_are_left_entirely_to_the_test_desk(self):
        github = FakeGitHub(comments=[comment('/lane T4\nrun: J1')])
        self.run_main(github)
        self.assertEqual((github.posted, github.label_changes), ([], []))

    def test_a_report_that_cannot_be_posted_fails_the_job_and_the_tidy_step_says_so(self):
        github = FakeGitHub(comments=[comment('/lane T2')], fail_comment=True)
        with self.assertRaises(RuntimeError):
            self.run_main(github)
        self.assertIn('lane:running', github.labels)
        github.fail_comment = False
        self.run_main(github, HEAD, 'PASS', '--cleanup')
        self.assertIn('the runner stopped before reporting (https://github.com/o/r/actions/runs/42)', github.posted[-1])
        self.assertEqual(github.labels & {'lane:running', 'lane:queued'}, set())


    def test_a_t3_request_runs_with_the_diff_s_classes_from_next_s_policy(self):
        github = FakeGitHub(comments=[comment('/lane T3\ntests: Gate1AppModelWorkflowTests/testOne')])
        scope = {'tier': 'T3', 'why': ['app orchestration'], 'app_tests': ['Gate1AppModelWorkflowTests']}
        with mock.patch.object(lane, 'diff_scope', return_value=scope), \
                mock.patch.object(lane, 'run_t3', return_value=('PASS', 'sim', 'ran', ['added'], 'none', '')) as run:
            self.run_main(github)
        self.assertEqual(run.call_args[0][0], ['Gate1AppModelWorkflowTests/testOne'])
        self.assertEqual(run.call_args[0][3], ['Gate1AppModelWorkflowTests'])
        self.assertIn('\nadded\n', github.posted[0])

    def test_a_t3_request_still_runs_when_test_scope_cannot_classify_the_diff(self):
        github = FakeGitHub(comments=[comment('/lane T3\ntests: PKMWorkflowTests')])
        with mock.patch.object(lane, 'diff_scope', side_effect=AttributeError('classify')), \
                mock.patch.object(lane, 'run_t3', return_value=('PASS', 'sim', 'ran', [], 'none', '')) as run:
            self.run_main(github)
        self.assertEqual(run.call_args[0][3], [])
        self.assertIn("test-scope.py could not classify the diff (AttributeError('classify')), so only the requested "
                      'tests ran', github.posted[0])

    def test_a_pr_that_conflicts_with_next_gets_an_inconclusive_report_naming_the_files(self):
        github = FakeGitHub(comments=[comment('/lane T2')])
        with mock.patch.object(self, 'conflicts', ['App/Shared.swift']), \
                mock.patch.object(lane, 'run_t2', side_effect=AssertionError('nothing should build')):
            self.run_main(github)
        self.assertTrue(github.posted[0].startswith('Lane report pr5-r42 — INCONCLUSIVE'))
        self.assertIn('does not merge cleanly into next', github.posted[0])
        self.assertIn('App/Shared.swift', github.posted[0])


class MergeTests(unittest.TestCase):
    """The runner merges the newest base into the PR head itself, with real git."""

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        root = Path(self.temporary.name)
        self.origin, self.tree = root / 'origin', root / 'tree'
        git = ['git', '-c', 'user.name=t', '-c', 'user.email=t@example.com', '-c', 'init.defaultBranch=next']
        self.git = git
        subprocess.run(git + ['init', '-q', str(self.origin)], check=True)
        (self.origin / 'shared.txt').write_text('one\n')
        subprocess.run(git + ['-C', str(self.origin), 'add', '.'], check=True)
        subprocess.run(git + ['-C', str(self.origin), 'commit', '-q', '-m', 'start'], check=True)
        subprocess.run(git + ['clone', '-q', str(self.origin), str(self.tree)], check=True)
        subprocess.run(git + ['-C', str(self.tree), 'checkout', '-q', '-b', 'pr'], check=True)

    def commit(self, where, name, text):
        (where / name).write_text(text)
        subprocess.run(self.git + ['-C', str(where), 'add', '.'], check=True)
        subprocess.run(self.git + ['-C', str(where), 'commit', '-q', '-m', name], check=True)

    def test_a_clean_merge_brings_in_the_newest_base(self):
        self.commit(self.tree, 'pr.txt', 'pr\n')
        self.commit(self.origin, 'lane.yml', 'new on next\n')
        base = lane.fetch_base(self.tree, 'next')
        self.assertEqual(base, subprocess.check_output(['git', '-C', str(self.origin), 'rev-parse', 'HEAD'], text=True).strip())
        self.assertEqual(lane.merge_base_branch(self.tree, 'next'), [])
        self.assertTrue((self.tree / 'lane.yml').exists())

    def test_the_base_branch_policy_classifies_only_the_committed_diff(self):
        (self.origin / 'scripts').mkdir()
        (self.origin / 'scripts/test-scope.py').write_text((SCRIPTS / 'test-scope.py').read_text())
        self.commit(self.origin, 'scripts/test-scope.py', (SCRIPTS / 'test-scope.py').read_text())
        subprocess.run(self.git + ['-C', str(self.tree), 'pull', '-q', 'origin', 'next'], check=True)
        (self.tree / 'docs').mkdir()
        self.commit(self.tree, 'docs/note.md', 'words\n')
        (self.tree / 'App').mkdir()
        (self.tree / 'App/Untracked.swift').write_text('// not committed, so not part of the PR\n')
        lane.fetch_base(self.tree, 'next')
        scope = lane.diff_scope(self.tree, 'next')
        self.assertEqual((scope['tier'], [f['path'] for f in scope['files']]), ('T0', ['docs/note.md']))
        # A PR that rewrites the policy to call everything docs is still judged by next's policy.
        self.commit(self.tree, 'scripts/test-scope.py', 'def classify(paths, diffs=None, root=None):\n'
                    '    return {"tier": "T0", "why": [], "files": []}\n')
        (self.tree / 'App/SpokenMarginsApp').mkdir(parents=True)
        self.commit(self.tree, 'App/SpokenMarginsApp/View.swift', 'struct V {}\n')
        self.assertEqual(lane.diff_scope(self.tree, 'next')['tier'], 'T2')

    def test_a_diff_touching_the_app_model_suggests_its_whole_workflow_class(self):
        (self.origin / 'scripts').mkdir()
        self.commit(self.origin, 'scripts/test-scope.py', (SCRIPTS / 'test-scope.py').read_text())
        (self.origin / 'App/SpokenMarginsAppTests').mkdir(parents=True)
        self.commit(self.origin, 'App/SpokenMarginsAppTests/Gate1AppModelWorkflowTests.swift',
                    'import XCTest\nfinal class Gate1AppModelWorkflowTests: XCTestCase {}\n')
        subprocess.run(self.git + ['-C', str(self.tree), 'pull', '-q', 'origin', 'next'], check=True)
        (self.tree / 'App/SpokenMarginsApp/Sources/SpokenMarginsApp').mkdir(parents=True)
        self.commit(self.tree, 'App/SpokenMarginsApp/Sources/SpokenMarginsApp/Gate1AppModel.swift', 'final class M {}\n')
        lane.fetch_base(self.tree, 'next')
        with tempfile.TemporaryDirectory() as evidence:
            self.assertEqual(lane.t3_scope(self.tree, 'next', Path(evidence)), (['Gate1AppModelWorkflowTests'], []))
            self.assertTrue((Path(evidence) / 'scope.json').exists())

    def test_the_hot_file_ratchet_is_next_s_copy_and_absent_until_it_is_on_next(self):
        model = 'App/SpokenMarginsApp/Sources/SpokenMarginsApp/Gate1AppModel.swift'
        (self.origin / model).parent.mkdir(parents=True)
        self.commit(self.origin, model, 'one\ntwo\n')
        subprocess.run(self.git + ['-C', str(self.tree), 'pull', '-q', 'origin', 'next'], check=True)
        self.commit(self.tree, model, 'one\ntwo\nthree\n')
        lane.fetch_base(self.tree, 'next')
        self.assertEqual(lane.hot_file_violations(self.tree, 'next', set()), [])  # not on next yet
        (self.origin / 'scripts').mkdir(exist_ok=True)
        self.commit(self.origin, 'scripts/hot_file_ratchet.py', (SCRIPTS / 'hot_file_ratchet.py').read_text())
        lane.fetch_base(self.tree, 'next')
        self.assertEqual(lane.merge_base_branch(self.tree, 'next'), [])
        # The PR swaps in a ratchet that always passes; next's copy still judges it.
        self.commit(self.tree, 'scripts/hot_file_ratchet.py', 'def violations(*args):\n    return []\n')
        found = lane.hot_file_violations(self.tree, 'next', set())
        self.assertEqual(len(found), 1, found)
        self.assertIn('Gate1AppModel.swift would be 3 lines, above its ceiling of 2', found[0])
        self.assertEqual(lane.hot_file_violations(self.tree, 'next', {'hot-file-ok'}), [])

    def test_a_conflict_names_the_files_and_leaves_the_tree_clean(self):
        self.commit(self.tree, 'shared.txt', 'pr side\n')
        self.commit(self.origin, 'shared.txt', 'next side\n')
        lane.fetch_base(self.tree, 'next')
        self.assertEqual(lane.merge_base_branch(self.tree, 'next'), ['shared.txt'])
        status = subprocess.check_output(['git', '-C', str(self.tree), 'status', '--porcelain'], text=True)
        self.assertEqual(status, '')


class OnlyTestingTests(unittest.TestCase):
    def test_selectors_cover_classes_and_methods_only(self):
        self.assertTrue(verification.selected('T/A/test1', 'T/A'))
        self.assertTrue(verification.selected('T/A/test1', 'T/A/test1'))
        self.assertFalse(verification.selected('T/AB/test1', 'T/A'))

    def test_an_unknown_selector_fails_before_anything_is_built(self):
        with tempfile.TemporaryDirectory() as temporary:
            run = verification.Run(Path(temporary) / 'run', 'app')
            real_capture = verification.capture

            def capture(args):
                if args[0] in ('xcrun', 'xcodebuild', 'xcodegen'):
                    raise AssertionError(f'nothing should run: {args}')
                return real_capture(args)

            with mock.patch.object(verification, 'capture', side_effect=capture), \
                    mock.patch.object(verification.Run, 'command', side_effect=AssertionError('nothing should run')):
                with self.assertRaisesRegex(RuntimeError, 'Not in the AppBehavior test plan: SpokenMarginsAppTests/Nope'):
                    run.xcode('app', None, False, None, ['Nope'])


if __name__ == '__main__':
    unittest.main()
