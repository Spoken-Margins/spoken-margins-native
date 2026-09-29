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
        self.assertEqual(lane.earlier_report([runner_report('PASS', wanted, url='u1')], same), 'u1')
        self.assertEqual(lane.earlier_report([runner_report('FAIL', wanted, url='u2')], same), 'u2')
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
                                                         'at boot: warn, after waiting 600s)'))

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


class MainFlowTests(unittest.TestCase):
    def run_main(self, github, event_head=HEAD, verdict='PASS', *extra):
        with tempfile.TemporaryDirectory() as temporary, \
                mock.patch.object(lane, 'GitHub', return_value=github), \
                mock.patch.dict('os.environ', {'GH_REPO': 'o/r', 'SM_LANE_EVIDENCE_DIR': temporary}), \
                mock.patch.object(lane, 'run_t2', return_value=(verdict, 'simulator build (pass), device build (pass)', [])), \
                mock.patch.object(lane, 'sweep_runner_simulators'), \
                mock.patch.object(lane, 'fetch_base', return_value=MERGE), \
                mock.patch.object(lane, 'merge_base_branch', return_value=self.conflicts), \
                mock.patch.object(lane, 'link_tools'), mock.patch('builtins.print'):
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
