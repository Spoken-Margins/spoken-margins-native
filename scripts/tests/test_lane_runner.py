import importlib.util
import os
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

    def run_auto(self, github, verdicts=('PASS',), pushes=(True,), scope=None, comments=(), moved=False):
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
                mock.patch.object(lane, 'run_automerge',
                                  side_effect=lambda scope, evidence, **_: (verdicts.pop(0), 'x', 'host tests; builds', [])):
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
        for audit in ('**Codex audit (Astra) on `aaaaaaa`**\n\nNo findings.', '## Codex audit (gpt-6-astra, high)\n\nAudited `abc`.'):
            with self.subTest(audit=audit[:20]):
                (_, _, _, details), events = self.run_auto(FakeGitHub(labels=('automerge',)), scope=risky,
                                                           comments=[comment(audit)])
                self.assertEqual(events, ['build', 'comment', 'push m1', 'sweep'])
        mention = [comment('Waiting on the Codex audit (Astra) for this one.')]  # not an audit: not its first line
        (_, _, _, _), events = self.run_auto(FakeGitHub(labels=('automerge',)), scope=risky, comments=mention)
        self.assertEqual(events, ['build'])

    def test_lane_tests_themselves_are_not_desk_only(self):
        scope = {'tier': 'T1', 'why': [], 'files': [{'path': 'scripts/tests/test_lane_runner.py', 'category': 'scripts'}]}
        self.assertEqual(lane.merge_blockers(scope, []), [])

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
        (self.tree / '.build' / 'dd').mkdir()
        (self.tree / '.build' / 'dd' / 'product').write_text('built')
        subprocess.run(self.git + ['clean', '-ffdxq'], check=True)  # what actions/checkout does
        self.assertFalse((self.tree / '.build').exists())
        self.assertIn('warm', self.warm())
        self.assertEqual((self.tree / '.build' / 'dd' / 'product').read_text(), 'built')

    def test_an_app_only_change_stays_warm_and_a_sessionkit_change_starts_a_new_cache(self):
        first = self.warm()
        self.commit('App/View.swift', 'struct V {}\n')
        self.assertTrue(self.warm().startswith('build folders: warm'), 'app-only change')
        self.commit('Packages/SessionKit/Sources/A.swift', 'struct A { var b = 1 }\n')
        second = self.warm()
        self.assertIn('cold, new cache', second)
        self.assertNotEqual(first.split('SessionKit ')[1], second.split('SessionKit ')[1])

    def test_it_keeps_at_most_two_caches_and_never_goes_below_the_disk_floor(self):
        for n in range(3):
            self.commit('Packages/SessionKit/Sources/A.swift', f'struct A{n} {{}}\n')
            self.warm()
            time.sleep(0.01)
        self.assertEqual(len([d for d in self.cache.iterdir() if d.name.startswith('sk-')]), lane.WARM_KEEP)
        self.assertIn('cold (less than 15 GB free)', self.warm(free=10**9))
        self.assertEqual(len([d for d in self.cache.iterdir() if d.name.startswith('sk-')]), 1)  # this key's

    def test_a_cache_in_use_by_another_runner_job_is_left_alone(self):
        import fcntl
        self.warm()
        cache = next(d for d in self.cache.iterdir() if d.name.startswith('sk-'))
        with open(cache / '.lock', 'a+') as other:
            fcntl.flock(other, fcntl.LOCK_EX | fcntl.LOCK_NB)
            (self.tree / '.build').unlink()
            self.assertIn('in use by another runner job', self.warm())
            self.assertFalse((self.tree / '.build').exists())  # the job builds cold in its own tree


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
    def run_main(self, github, event_head=HEAD, verdict='PASS', *extra):
        with tempfile.TemporaryDirectory() as temporary, \
                mock.patch.object(lane, 'GitHub', return_value=github), \
                mock.patch.dict('os.environ', {'GH_REPO': 'o/r', 'SM_LANE_EVIDENCE_DIR': temporary}), \
                mock.patch.object(lane, 'run_t2', return_value=(verdict, 'simulator build (pass), device build (pass)', [])), \
                mock.patch.object(lane, 'sweep_runner_simulators'), \
                mock.patch.object(lane, 'fetch_base', return_value=MERGE), \
                mock.patch.object(lane, 'merge_base_branch', return_value=self.conflicts), \
                mock.patch.object(lane, 'link_tools'), mock.patch('builtins.print'), \
                mock.patch.object(lane, 'warm_build_folders', return_value='build folders: warm (SessionKit test)'):
            return lane.main(['--pr', '5', '--event-head', event_head, '--run-id', '42', *extra])

    conflicts = []

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
