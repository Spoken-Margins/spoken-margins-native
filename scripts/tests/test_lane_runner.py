import os
os.environ.pop('SM_TRUNK', None)  # fixtures are written for the default trunk; the lane and the Mac export SM_TRUNK (#1492)
import contextlib
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
import types
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


class LostLaneJobTests(unittest.TestCase):
    """A lane job whose runner is lost runs no step; lane.yml's lane-lost job reports it (#2174)."""

    URL = 'https://github.com/o/r/actions/runs/39167859799'
    T3 = '/lane T3\ntests: AccessibilityFixProofTests, CatalogDrawerTests\n'

    def lost(self, github, attempt='1'):
        with mock.patch('builtins.print'):
            return lane.report_lost(github, 9, '39167859799', attempt, HEAD, 'main', self.URL)

    def test_a_lost_t3_gets_an_inconclusive_report_naming_the_run_and_frees_the_labels(self):
        github = FakeGitHub(labels=('lane:queued', 'automerge'), comments=[comment(self.T3)])
        self.lost(github)
        body, = github.posted
        self.assertTrue(body.startswith('Lane report pr9-r39167859799 — INCONCLUSIVE'), body)
        self.assertIn(self.URL, body)
        self.assertIn('No test ran', body)
        wanted = lane.report_identity(body)
        self.assertEqual((wanted['tier'], wanted['commit'], wanted['tests']),
                         ('T3', HEAD, ['AccessibilityFixProofTests', 'CatalogDrawerTests']))
        self.assertEqual(github.labels, {'automerge', 'lane:done'})
        # The held automerge run now sees an INCONCLUSIVE T3 report instead of a request with none.
        self.assertIsNone(lane.pending_requests(github.comments())[0])
        self.assertTrue(lane.lane_report_verdict(body)[0], 'dispatch counts it as a runner fault (one rerun)')

    def test_the_report_names_no_tested_commit_so_the_auto_revert_never_counts_it(self):
        github = FakeGitHub(comments=[comment(self.T3)])
        self.lost(github)
        self.assertIsNone(lane.TESTED_ON.search(github.posted[0]))

    def test_a_second_attempt_of_the_run_is_named_for_its_attempt(self):
        github = FakeGitHub(comments=[comment(self.T3)])
        self.lost(github, attempt='2')
        self.assertTrue(github.posted[0].startswith('Lane report pr9-r39167859799-a2 — INCONCLUSIVE'))

    def test_a_job_that_reported_is_left_alone(self):
        wanted = lane.identity('T3', HEAD, 'b' * 40, ['X'])
        done = comment(lane.report('pr9-r39167859799', 'FAIL', HEAD, 'b' * 40, 'T3', 'x', 1, 'x', [], 'none', '/e',
                                   'owner', wanted), login='github-actions[bot]')
        github = FakeGitHub(comments=[comment(self.T3), done])
        self.lost(github)
        self.assertEqual((github.posted, github.label_changes), ([], []))

    def test_a_job_whose_tidy_step_spoke_is_left_alone(self):
        note = comment(f'Lane: the runner stopped before reporting ({self.URL}). If it is still needed, comment the '
                       f'request again and add lane:queued.\n{lane.NOTE}', login='github-actions[bot]')
        github = FakeGitHub(comments=[comment(self.T3), note])
        self.lost(github)
        self.assertEqual((github.posted, github.label_changes), ([], []))

    def test_the_automerge_run_of_the_same_workflow_run_does_not_hide_the_lost_lane_job(self):
        wanted = lane.identity('auto', HEAD, 'b' * 40, [])
        auto = comment(lane.report('pr9-r39167859799-auto', 'PASS', HEAD, 'b' * 40, 'auto', 'x', 1, 'x', [], 'none',
                                   '/e', 'owner', wanted), login='github-actions[bot]')
        note = comment(f'Lane: the automerge run stopped before reporting ({self.URL}).\n{lane.NOTE}',
                       login='github-actions[bot]')
        github = FakeGitHub(comments=[comment(self.T3), auto, note])
        self.lost(github)
        self.assertEqual(len(github.posted), 1)

    def test_a_pr_that_moved_on_is_left_alone(self):
        github = FakeGitHub(head='c' * 40, comments=[comment(self.T3)])
        self.lost(github)
        self.assertEqual((github.posted, github.label_changes), ([], []))

    def test_a_request_the_runner_already_answered_only_frees_the_labels(self):
        wanted = lane.identity('T3', HEAD, 'b' * 40, ['X'])
        answered = runner_report('PASS', wanted)
        github = FakeGitHub(labels=('lane:queued', 'lane:running'), comments=[comment(self.T3), answered])
        self.lost(github)
        self.assertEqual(github.posted, [])
        self.assertEqual(github.labels, {'lane:done'})

    def test_a_request_the_lane_job_answered_as_identical_changes_nothing(self):
        # "Lane: identical T3 request ... already reported (FAIL)" turns the job red but answers the request.
        identical = comment(f'Lane: identical T3 request for {HEAD[:7]} already reported (FAIL): https://example.test/r'
                            f'\n{lane.NOTE}', login='github-actions[bot]')
        github = FakeGitHub(labels=('lane:done',), comments=[comment(self.T3), identical])
        self.lost(github)
        self.assertEqual((github.posted, github.label_changes), ([], []))

    def test_a_closed_pr_is_left_alone(self):
        github = FakeGitHub(comments=[comment(self.T3)])
        pull = github.pull
        github.pull = lambda: {**pull(), 'state': 'closed'}
        self.lost(github)
        self.assertEqual((github.posted, github.label_changes), ([], []))

    def test_a_waiting_test_desk_request_keeps_lane_queued(self):
        github = FakeGitHub(labels=('lane:queued',), comments=[comment(self.T3), comment('/lane T4\nrun: J1\n')])
        self.lost(github)
        self.assertIn('lane:queued', github.labels)
        self.assertEqual(len(github.posted), 1)


class ClaudeAuditGateTests(unittest.TestCase):
    def test_claude_head_audit_clears_lane_and_risky_changes(self):
        clean = comment('**Claude audit on `aaaaaaa`**\n\nNo blocking findings.')
        scope = {'files': [{'category': 'audio'}, {'category': 'persistence'}, {'category': 'packet'}],
                 'lane_paths': ['scripts/lane-runner.py']}
        self.assertIsNone(lane.audit_blocker([clean], HEAD))
        self.assertEqual(lane.merge_blockers(scope, [clean], HEAD), [])

    def test_pr1654_host_domain_persistence_requires_its_head_audit(self):
        paths = [
            'App/SpokenMarginsApp/Sources/SpokenMarginsApp/Gate1AppModel+RemoteProvider.swift',
            'App/SpokenMarginsAppTests/SummaryFailureOwnershipWorkflowTests.swift',
            'App/SpokenMarginsAppTests/SummarySuccessOwnershipWorkflowTests.swift',
            'Packages/SessionKit/Sources/SessionKit/LocalSummaryRequestOrigin.swift',
            'Packages/SessionKit/Sources/SessionKit/SessionEngine.swift',
            'Packages/SessionKit/Tests/SessionKitTests/LocalSummaryCompletionTests.swift',
        ]
        spec = importlib.util.spec_from_file_location('audit_gate_scope', SCRIPTS / 'test-scope.py')
        scope_policy = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(scope_policy)
        scope = scope_policy.classify(paths)
        self.assertEqual(scope['tier'], 'T3')
        engine = next(f for f in scope['files'] if f['path'].endswith('/SessionEngine.swift'))
        self.assertEqual(engine['category'], 'sessionkit')  # audit risk must not change test tiers
        self.assertEqual(lane.merge_blockers(scope, [], HEAD),
                         ['it touches persistence and has no Codex or Claude audit comment yet'])
        stale = comment('**Claude audit on `ccccccc`**\n\nNo blocking findings.')
        self.assertTrue(lane.merge_blockers(scope, [stale], HEAD))
        blocked = comment('**Claude audit on `aaaaaaa`**\n\n[P1] Wrong owner.')
        self.assertTrue(lane.merge_blockers(scope, [blocked], HEAD))
        clean = comment('**Claude audit on `aaaaaaa`**\n\nNo blocking findings.')
        self.assertEqual(lane.merge_blockers(scope, [clean], HEAD), [])

    def test_existing_persistence_path_policy_and_neighbor_exemptions(self):
        cases = {
            'Packages/SessionKit/Sources/SessionKit/SessionEngine+Retry.swift': True,
            'Packages/SessionKit/Sources/SessionKit/LocalSummaryRequestOrigin.swift': False,
            'Packages/SessionKit/Tests/SessionKitTests/SessionEngineTests.swift': False,
            'scripts/tests/test_persistence.py': False,
            'docs/SessionEngine.swift': False,
            'research/SessionEngine.swift': False,
            'Design/SessionEngine.swift': False,
            'docs/persistence.md': False,
        }
        for path, required in cases.items():
            with self.subTest(path=path):
                scope = {'files': [{'path': path, 'category': 'sessionkit'}]}
                self.assertEqual(bool(lane.merge_blockers(scope, [], HEAD)), required)

    def test_runner_copied_out_of_the_tree_still_loads_and_applies_the_persistence_gate(self):
        # lane.yml runs main's lane-runner.py from $RUNNER_TEMP (git show > file), so a helper module must be
        # imported only after main() puts the workspace's scripts/ on sys.path (#1659).
        driver = (
            'import importlib.util, sys\n'
            'spec = importlib.util.spec_from_file_location("lane_runner", sys.argv[1])\n'
            'lane = importlib.util.module_from_spec(spec)\n'
            'spec.loader.exec_module(lane)\n'
            'sys.path.insert(0, sys.argv[2])\n'
            'files = [{"path": "Packages/SessionKit/Sources/SessionKit/SessionEngine.swift", "category": "sessionkit"}]\n'
            'print(lane.merge_blockers({"files": files}, [], "a" * 40))\n'
        )
        with tempfile.TemporaryDirectory() as tmp:
            temp = Path(tmp) / '_work' / '_temp'
            temp.mkdir(parents=True)
            runner = temp / 'lane-runner.py'
            runner.write_text((SCRIPTS / 'lane-runner.py').read_text())
            env = {k: v for k, v in os.environ.items() if k != 'PYTHONPATH'}
            run = subprocess.run([sys.executable, '-c', driver, str(runner), str(SCRIPTS)],
                                 cwd=tmp, env=env, capture_output=True, text=True)
            self.assertEqual(run.returncode, 0, run.stderr[-800:])
            self.assertIn('no Codex or Claude audit comment yet', run.stdout)

    def test_newest_head_audit_wins_across_reviewers(self):
        claude = comment('**Claude audit on `aaaaaaa`**\n\nNo blocking findings.')
        codex = comment('**Codex audit (Astra) on `aaaaaaa`**\n\n[P1] Broken.')
        self.assertIsNone(lane.audit_blocker([codex, claude], HEAD))
        self.assertIsNotNone(lane.audit_blocker([claude, codex], HEAD))


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
        # Same head, but main moved: it runs again.
        self.assertIsNone(lane.earlier_report([runner_report('PASS', wanted)], lane.identity('T3', HEAD, NEWER, ['A', 'B'])))


class ReportTests(unittest.TestCase):
    def test_report_matches_the_contract_header_and_lines(self):
        body = lane.report('pr7-r9', 'FAIL', HEAD, MERGE, 'T2', 'no simulator (compile only)', 75,
                           'simulator build (pass), device build (fail)', ['device build — expected: …'],
                           'none', '/ev/pr7-r9', 'journeys (T4)', lane.identity('T2', HEAD, MERGE, []))
        lines = body.splitlines()
        self.assertEqual(lines[0], 'Lane report pr7-r9 — FAIL')
        self.assertEqual(lines[1], f'commit {HEAD[:7]} (tested merged with main at {MERGE[:7]}) · tier T2 · '
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
                mock.patch.object(lane, 'run_plans', return_value=([lane.summarize_manifest({'steps': []})], ['verified'],
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

    def test_large_attachment_listing_keeps_t3_failure_report_postable(self):
        prefix = '/mac/' + 'long-path/' * 25
        files = [prefix + f'debug-{n}.txt' for n in range(999)] + [prefix + 'recording.mp4']
        manifest = {'status': 'failed_or_incomplete', 'steps': [{
            'tests': {'T/A/testBad': {'status': 'failed'}},
            'attachments': [{'test': 'T/A/testBad', 'manifest': prefix + 'manifest.json',
                             'files': files}]}]}
        summaries, statuses, _, details = lane.run_plans(
            {'app': ['T/A']}, lambda *args: manifest, Path('/mac/run'))
        verdict = lane.t3_verdict(summaries, statuses)
        text = lane.report('r', verdict, HEAD, HEAD, 'T3', 'simulator', 1, '1 failed',
                           details, 'none', '/mac/run', 'audible content', {})
        self.assertLess(len(text), 65536)
        self.assertIn('— FAIL', text)
        self.assertIn('observed: failed', text)
        self.assertIn('more file links omitted', text)
        self.assertIn('recording.mp4', text)
        self.assertEqual(manifest['steps'][0]['attachments'][0]['files'], files)

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
                mock.patch.object(lane_sim, 'clone_temporary', side_effect=AssertionError('no simulator should be made')):
            self.assertEqual(lane.run_t3([], 'r', Path('/tmp'))[0], 'INCONCLUSIVE')
            self.assertEqual(lane.run_t3(['NoSuchTestClassAnywhere'], 'r', Path('/tmp'))[0], 'FAIL')


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
        self.behave({'status': 'verified', 'steps': []})
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
        for manifest, expected in (({'status': 'verified', 'steps': []}, 'PASS'), (failed, 'FAIL')):
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

        def create(created, runtime, **kw):
            seen['at create'] = lane.runner_device_claimed(created)
            return 'U'

        def release(udid):
            seen['at delete'] = lane.runner_device_claimed(name)

        with mock.patch.object(lane_sim, 'clone_temporary', side_effect=create), \
                mock.patch.object(lane_sim, 'start_watcher'), mock.patch.object(lane_sim, 'release', side_effect=release), \
                mock.patch.object(lane_sim, 'unsafe_devices', return_value={}), \
                mock.patch.object(lane, 'boot_t3_device', return_value=(None, {})), \
                mock.patch.object(lane, 'run_plans', return_value=([lane.summarize_manifest({'steps': []})], ['verified'],
                                                                   ['A (1 passed)'], [])), \
                tempfile.TemporaryDirectory() as temporary:
            lane._t3_on_fresh_device({'app': ['T/A']}, 'pr7-r7', Path(temporary),
                                     'com.apple.CoreSimulator.SimRuntime.iOS-26-5')
        self.assertEqual(seen, {'at create': True, 'at delete': True})
        self.assertFalse(lane.runner_device_claimed(name))
        self.assertEqual(list(Path(self.state.name).glob('runner-device-*')), [])


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
                (output / 'manifest.json').write_text(json.dumps({'status': 'verified', 'steps': []}))
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
        # main's test-scope.py from before #351 names them only in its suggested request.
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
        method = 'SupertonicSpeechTests/testDownloadedRendererSynthesizesJamesAndLilyAndReusesSessions'
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

    def run_checks(self, tier, fast='PASS', too_big=()):
        """run_automerge with fake host tests, and every process it starts recorded: no app build may run."""
        calls = []

        def fake_fast(evidence, changed=None):
            calls.append('fast')
            return fast, [] if fast == 'PASS' else [f'host tests {fast}']

        def started(command, log, timeout, **_):
            calls.append(Path(command[0]).name)
            return 0

        with tempfile.TemporaryDirectory() as evidence, mock.patch.object(lane, 'run_bounded', side_effect=started):
            result = lane.run_automerge({'tier': tier, 'why': ['x']}, Path(evidence), fast=fake_fast,
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

    def test_a_diff_that_reaches_the_app_runs_the_host_tests_and_no_app_build(self):
        # Owner, 2026-10-09: from 10-02 to 10-09, 140 automerge runs built for simulator and device after the
        # host tests (about 3.4 min each, ~8 runner-hours a week) and caught no compile failure. Authors build
        # both targets before pushing, and the integration run on main's tip builds the merged app.
        for tier in ('T2', 'T3'):
            with self.subTest(tier=tier):
                (verdict, where, ran, details), calls = self.run_checks(tier)
                self.assertEqual((verdict, where, calls), ('PASS', 'host only', ['fast']))
                self.assertEqual(ran, 'host tests (--plan fast): passed')
                self.assertIn(lane.NO_APP_BUILD_PER_PR, details)

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

    def test_a_pass_carries_the_manifest_s_notes_and_a_superseded_parallel_run_is_not_a_failure(self):
        # #1328: the PASS says when the SessionKit tests were skipped or the parallel core run was run again serially,
        # and the failed parallel step doesn't count against the serial run that replaced it.
        steps = [{'name': 'package-core', 'superseded': 'run again serially', 'exit_code': 1,
                  'tests': {'SessionKitCoreTests/A/testX': {'status': 'failed'}}},
                 {'name': 'package-core-serial', 'exit_code': 0,
                  'tests': {'SessionKitCoreTests/A/testX': {'status': 'passed'}}}]

        def run(command, log, timeout):
            output = Path(command[command.index('--output') + 1])
            output.mkdir(parents=True)
            (output / 'manifest.json').write_text(json.dumps({
                'status': 'verified', 'steps': steps, 'notes': ['SessionKitCoreTests: the parallel run failed']}))
            return 0

        with tempfile.TemporaryDirectory() as folder:
            verdict, details = lane.run_fast(Path(folder), runner=run)
            self.assertEqual((verdict, details), ('PASS', ['SessionKitCoreTests: the parallel run failed']))
            # the superseded parallel step's records are not a run: the serial run's one test is what ran
            self.assertEqual(lane.manifest_failures(Path(folder) / 'fast'),
                             ([], False, ['SessionKitCoreTests/A/testX']))
            steps[1]['tests']['SessionKitCoreTests/A/testX']['status'] = 'failed'
            (Path(folder) / 'fast/manifest.json').write_text(json.dumps({'steps': steps}))
            self.assertEqual(lane.manifest_failures(Path(folder) / 'fast'),
                             (['SessionKitCoreTests/A/testX'], False, ['SessionKitCoreTests/A/testX']))

    def test_skipped_sessionkit_tests_are_not_a_run_of_zero_tests(self):
        # #1328: a skipped run has no test records, and the step ledger counted that as a runner fault.
        with tempfile.TemporaryDirectory() as folder:
            (Path(folder) / 'manifest.json').write_text(json.dumps({
                'status': 'verified', 'sessionkit_pass': {'reused': 'k'},
                'steps': [{'name': 'runner-tests', 'exit_code': 0}, {'name': 'package', 'skipped': 'already passed'}]}))
            self.assertEqual(lane.manifest_failures(Path(folder)), ([], False, []))  # skipped: ran nothing, adds no names
            (Path(folder) / 'manifest.json').write_text(json.dumps({
                'status': 'verified', 'steps': [{'name': 'runner-tests', 'exit_code': 0}]}))
            self.assertEqual(lane.manifest_failures(Path(folder)), ([], True, []))  # still zero without the record

    def test_the_tests_a_run_executed_are_every_test_across_manifests_once_each(self):
        # #1830: the ledger closes a named failure only on a run that ran it, so ran lists the passed and failed
        # tests of every verify-* manifest, a test named in two plans once, and no step name.
        with tempfile.TemporaryDirectory() as folder:
            for plan, tests in (('app', {'A/a': {'status': 'passed'}, 'B/b': {'status': 'failed'}}),
                                ('adapters', {'B/b': {'status': 'failed'}, 'C/c': {'status': 'passed'}})):
                (Path(folder) / f'verify-{plan}').mkdir()
                (Path(folder) / f'verify-{plan}' / 'manifest.json').write_text(json.dumps({
                    'steps': [{'name': 'xctest', 'exit_code': 1, 'tests': tests}]}))
            failed, zero, ran = lane.manifest_failures(*sorted(Path(folder).glob('verify-*')))
            self.assertEqual((failed, zero, sorted(ran)), (['B/b', 'B/b'], False, ['A/a', 'B/b', 'C/c']))

    def test_a_lane_fault_in_the_host_tests_is_inconclusive_not_a_pr_fail(self):
        # #909: with the lane Mac's lid closed every real-player test failed, so every PR read FAIL.
        def run(command, log, timeout):
            output = Path(command[command.index('--output') + 1])
            output.mkdir(parents=True, exist_ok=True)
            (output / 'manifest.json').write_text(json.dumps({
                'status': 'failed_or_incomplete', 'lane_fault': 'no audio output: lid closed'}))
            return 1

        with tempfile.TemporaryDirectory() as folder:
            verdict, details = lane.run_fast(Path(folder), runner=run)
        self.assertEqual(verdict, 'INCONCLUSIVE')
        self.assertIn('lane fault: no audio output: lid closed', details[0])

    def test_the_host_tests_are_verify_tests_py_s_fast_plan_writing_into_the_evidence_folder(self):
        # The runners above write a verified manifest into whatever --output they get, whatever plan they were
        # asked for, so none of them could tell the fast plan from a retired one (`--plan ui`).
        launched = []

        def run(command, log, timeout):
            launched.append((command, timeout))
            output = Path(command[command.index('--output') + 1])
            output.mkdir(parents=True)
            (output / 'manifest.json').write_text('{"status": "verified"}')
            return 0

        with tempfile.TemporaryDirectory() as folder:
            self.assertEqual(lane.run_fast(Path(folder), runner=run), ('PASS', []))
            [(command, timeout)] = launched
            self.assertEqual(command[1:], ['scripts/verify-tests.py', '--plan', 'fast', '--output',
                                           str(Path(folder) / 'fast')])
        self.assertIn(command[0], (str(lane.ROOT / '.venv/bin/python'), sys.executable))
        self.assertEqual(timeout, lane.FAST_TIMEOUT)


class ChangedPathsForTestsTests(unittest.TestCase):
    """#862: the lane hands verify-tests.py the PR's changed paths so it can skip suites nothing can affect."""

    def test_run_fast_passes_the_changed_paths_only_when_it_has_them(self):
        for changed, expected in ((['docs/a.md'], True), (None, False), ([], False)):
            with self.subTest(changed=changed), tempfile.TemporaryDirectory() as folder:
                seen = []

                def runner(command, log, timeout):
                    seen.append(command)
                    return 0

                lane.run_fast(Path(folder), runner=runner, changed=changed)
                self.assertEqual('--changed-files' in seen[0], expected)
                if expected:
                    listing = Path(seen[0][seen[0].index('--changed-files') + 1])
                    self.assertEqual(listing.read_text(), 'docs/a.md\n')

    def test_both_sides_of_a_rename_count_and_a_git_failure_runs_everything(self):
        with tempfile.TemporaryDirectory() as folder:
            repo = Path(folder)

            def git(*args):
                subprocess.check_call(['git', '-C', folder, '-c', 'user.name=t', '-c', 'user.email=t@t', *args],
                                      stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

            git('init', '-q', '-b', 'main')
            (repo / 'scripts').mkdir()
            (repo / 'scripts/tool.py').write_text('print("a long enough file body so git sees a rename")\n' * 20)
            git('add', '.')
            git('commit', '-qm', 'base')
            git('update-ref', 'refs/remotes/origin/main', 'HEAD')
            git('checkout', '-qb', 'pr')
            (repo / 'docs').mkdir()
            git('mv', 'scripts/tool.py', 'docs/tool.py')  # a lane script moved out of scripts/
            git('commit', '-qm', 'move')
            self.assertEqual(lane.changed_paths_for_tests(repo, 'main'), ['docs/tool.py', 'scripts/tool.py'])
            self.assertIsNone(lane.changed_paths_for_tests(repo / 'nowhere', 'main'))
            self.assertIsNone(lane.changed_paths_for_tests(repo, 'no-such-base'))

    def pr_changing(self, folder, *names):
        """A repository whose PR branch adds each name, one tracked file per name, on top of origin/main."""
        def git(*args):
            subprocess.check_call(['git', '-C', folder, '-c', 'user.name=t', '-c', 'user.email=t@t', *args],
                                  stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

        git('init', '-q', '-b', 'main')
        git('commit', '-qm', 'base', '--allow-empty')
        git('update-ref', 'refs/remotes/origin/main', 'HEAD')
        git('checkout', '-qb', 'pr')
        for name in names:
            (Path(folder) / name).parent.mkdir(parents=True, exist_ok=True)
            (Path(folder) / name).write_text('x\n')
        git('add', '.')
        git('commit', '-qm', 'change')
        return Path(folder)

    def test_names_git_would_quote_come_through_exactly(self):
        # Audit of #898: git prints scripts/tests/test_café.py as "scripts/tests/test_caf\303\251.py" unless it is
        # asked for NUL-delimited names; the quoted form doesn't start with scripts/, so the lane's own tests
        # would have been skipped for a scripts change.
        names = ['scripts/tests/test_café.py', 'scripts/tab\tname.py', 'scripts/quote"name.py',
                 'scripts/back\\slash.py', 'docs/note ü.md']
        with tempfile.TemporaryDirectory() as folder:
            repo = self.pr_changing(folder, *names)
            self.assertEqual(lane.changed_paths_for_tests(repo, 'main'), sorted(names))

    def test_a_name_the_one_path_per_line_hand_off_would_change_runs_everything(self):
        for name in ('scripts/line\nbreak.py', ' scripts/leading-space.py', 'scripts/trailing-space.py '):
            with self.subTest(name=name), tempfile.TemporaryDirectory() as folder:
                repo = self.pr_changing(folder, 'docs/a.md', name)
                self.assertIsNone(lane.changed_paths_for_tests(repo, 'main'))


class MergeTests_Runner(unittest.TestCase):
    """The runner merges what it passes (decision 3): blockers, order, retries. Git is faked here;
    PushTests below uses real git."""

    SCOPE = {'tier': 'T2', 'why': ['app UI'], 'files': [{'path': 'App/X.swift', 'category': 'app-ui'}]}

    def run_auto(self, github, verdicts=('PASS',), pushes=(True,), scope=None, comments=(), moved=False,
                 automerge=None, inherited=lambda comments: []):
        events = []
        self.dispatched = []
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
                mock.patch.object(lane, 'TESTED_RECORD', Path(folder) / 'tested.json'), \
                mock.patch.object(lane, 'build_merge_commit', side_effect=build), \
                mock.patch.object(lane, 'push_merge', side_effect=push), \
                mock.patch.object(lane, 'fetch_base', side_effect=lambda tree, base: NEWER), \
                mock.patch.object(lane, 'sweep_merge_audit', side_effect=lambda tree, base: events.append('sweep')), \
                mock.patch.object(lane, 'dispatch_hosted_integration',
                                  side_effect=lambda base: self.dispatched.append(base) or 'started'), \
                mock.patch.object(lane, 'host_build_folders', return_value='build folders: in the workspace (test)'), \
                mock.patch.object(lane, 'inherited_check', return_value=inherited), \
                mock.patch.object(lane, 'diff_scope', return_value=scope or self.SCOPE), \
                mock.patch.object(lane, 'hot_file_violations', return_value=[]), \
                mock.patch.object(lane, 'run_automerge', side_effect=automerge or (
                    lambda scope, evidence, **_: (verdicts.pop(0), 'x', 'host tests; builds', []))):
            result = lane.run_auto(github, {'title': 'T'}, 5, 'main', HEAD, MERGE, Path(folder), list(comments))
        return result, events

    def test_a_simulated_run_does_not_judge_the_checkout_s_own_hot_files(self):
        # #1104: run_auto's ratchet read the real checkout's Gate1AppModel.swift, so these simulated runs failed
        # on any commit above the hot-file ceiling (PR #1103's first commit grew the model by 6 lines, and
        # phone-build stopped at "host tests failed"). The ratchet's own refusals are tested over fixture
        # repositories (the hot-file tests below), not here.
        real_policy, real_automerge = lane.base_policy, lane.run_automerge
        over_ceiling = types.SimpleNamespace(violations=lambda *args: [
            'Gate1AppModel.swift would be 99999 lines, above its ceiling of 1 (a checkout that is over it)'])

        def policy(tree, base, path):
            return over_ceiling if path == 'scripts/hot_file_ratchet.py' else real_policy(tree, base, path)

        def automerge(scope, evidence, **kwargs):
            return real_automerge(scope, evidence, fast=lambda e, changed=None: ('PASS', []), **kwargs)

        host_only = {'tier': 'T1', 'why': ['scripts'], 'files': [{'path': 'scripts/x.py', 'category': 'scripts'}]}
        with mock.patch.object(lane, 'base_policy', side_effect=policy):
            (verdict, where, _, details), _ = self.run_auto(FakeGitHub(labels=('automerge',)), scope=host_only,
                                                            automerge=automerge)
        self.assertEqual((verdict, where), ('PASS', 'host only'), details)

    def test_a_pass_posts_the_merge_check_then_pushes_the_tested_commit(self):
        github = FakeGitHub(labels=('automerge',))
        (verdict, _, _, details), events = self.run_auto(github)
        self.assertEqual(verdict, 'PASS')
        self.assertEqual(events, ['build', 'comment', 'push m1', 'sweep'])  # the check is on the PR before the merge
        self.assertTrue(github.posted[0].startswith(f'**Merge check (triage desk) on `{HEAD[:7]}`: PASS.**'))
        import merge_audit  # the comment satisfies the merge audit's rule
        self.assertTrue(merge_audit.has_merge_check([dict(body=github.posted[0], created_at='2026-09-29T20:00:00Z', user={'login': 'github-actions[bot]'})],
                                                    HEAD, '2026-09-29T20:00:01Z'))
        self.assertIn('merged into main as m100000', details[-1])

    def test_a_fail_or_inconclusive_never_merges(self):
        for verdict in ('FAIL', 'INCONCLUSIVE'):
            with self.subTest(verdict=verdict):
                github = FakeGitHub(labels=('automerge',))
                (got, _, _, _), events = self.run_auto(github, verdicts=(verdict,))
                self.assertEqual((got, events, github.posted), (verdict, ['build'], []))

    def test_lane_changes_merge_on_pass_plus_a_clean_audit_of_the_head(self):
        # Owner rule 2026-10-01: lane PRs no longer wait for the owner. They wait for the audit, then merge.
        # The runner itself and .github/ are the exception (next test).
        clean = comment('**Codex audit (Astra) on `aaaaaaa`**\n\nNo blocking findings.')
        for path in ('scripts/lane_sim.py', 'scripts/verify-tests.py'):
            with self.subTest(path=path):
                scope = {'tier': 'T1', 'why': [], 'lane_paths': [path], 'files': [{'path': path, 'category': 'scripts'}]}
                (verdict, _, _, details), events = self.run_auto(FakeGitHub(labels=('automerge',)), scope=scope)
                self.assertEqual((verdict, events), ('PASS', ['build']))
                self.assertEqual(details[-1], 'not merged by the runner: it touches the lane and has no Codex or Claude audit '
                                              'comment yet. It merges once a Codex or Claude audit of its head says '
                                              '"No blocking findings".')
                (verdict, _, _, details), events = self.run_auto(FakeGitHub(labels=('automerge',), comments=[clean]),
                                                                 scope=scope)
                self.assertEqual(events, ['build', 'comment', 'push m1', 'sweep'])
                self.assertIn('merged into main as m100000', details[-1])

    def test_the_runner_and_github_changes_never_merge_without_the_owner_whatever_the_audit_says(self):
        # #1210, owner decision 2026-10-09 (#1203): arming and merging a PR that touches scripts/lane-runner.py or
        # anything under .github/ is the owner's tap. The runner can't test itself, and a bad runner or workflow
        # change could wave later PRs through, so a clean audit doesn't let the runner merge it.
        clean = comment('**Codex audit (Astra) on `aaaaaaa`**\n\nNo blocking findings.')
        cases = {
            'scripts/lane-runner.py': ['scripts/lane-runner.py'],
            '.github/workflows/lane.yml': ['.github/workflows/lane.yml'],
            '.github/CODEOWNERS': [],  # under .github/ but not a lane path (test-scope.py's LANE_PREFIXES)
        }
        for path, lane_paths in cases.items():
            with self.subTest(path=path):
                scope = {'tier': 'T1', 'why': [], 'lane_paths': lane_paths,
                         'files': [{'path': 'App/X.swift', 'category': 'app-ui'}, {'path': path, 'category': 'scripts'}]}
                self.assertEqual(lane.owner_tap_paths(scope), [path])
                github = FakeGitHub(labels=('automerge',), comments=[clean])
                (verdict, _, _, details), events = self.run_auto(github, scope=scope)
                self.assertEqual((verdict, events, github.posted), ('PASS', ['build'], []))
                self.assertEqual(details[-1], f'not merged by the runner: it touches `{path}`, which only the owner '
                                              'merges (owner rule 2026-10-09, #1203), whatever an audit says. It needs '
                                              'the owner\'s tap.')
        unaudited = {'tier': 'T1', 'why': [], 'lane_paths': ['scripts/lane-runner.py'],
                     'files': [{'path': 'scripts/lane-runner.py', 'category': 'scripts'}]}
        (_, _, _, details), _ = self.run_auto(FakeGitHub(labels=('automerge',)), scope=unaudited)
        # The audit hold line stays first: the Mac's audit script finds lane PRs to audit by it.
        self.assertTrue(details[-2].startswith('not merged by the runner: it touches the lane and has no Codex'))
        self.assertIn("needs the owner's tap", details[-1])

    def test_a_policy_without_paths_holds_nothing_for_the_owner(self):
        self.assertEqual(lane.owner_tap_paths(self.SCOPE), [])
        self.assertEqual(lane.owner_tap_paths({'files': [{'category': 'scripts'}]}), [])
        self.assertEqual(lane.owner_tap_paths({'files': [{'path': 'scripts/lane-runner.pyc'},
                                                         {'path': 'docs/.github/x'}]}), [])

    def test_unaudited_risky_changes_wait_for_the_audit(self):
        risky = {'tier': 'T2', 'why': [], 'files': [{'path': 'Packages/SessionKit/Sources/SessionKitSharing/A.swift',
                                                        'category': 'packet'}]}
        (_, _, _, details), events = self.run_auto(FakeGitHub(labels=('automerge',)), scope=risky)
        self.assertEqual(events, ['build'])
        self.assertIn('it touches packets and has no Codex or Claude audit comment yet', details[-1])
        for audit in ('**Codex audit (Astra) on `aaaaaaa`**\n\nNo blocking findings.',
                      '## Codex audit (gpt-6-astra, high) of `aaaaaaaa`\n\nNo findings.'):
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

    def test_an_inherited_blocking_audit_holds_a_clean_audited_pr_until_resolved(self):
        # #712: PR #636 merged #616's blocked commit on its own clean audit. The hold is reported, nothing is pushed.
        clean = comment(f'**Claude audit on `{HEAD[:7]}`**\n\nNo blocking findings.')
        reason = f'{lane.INHERITED_HOLD}: #616\'s audit of `8ddbd14` (https://example.test/616) is not resolved'
        (verdict, _, _, details), events = self.run_auto(
            FakeGitHub(labels=('automerge',), comments=[clean]), scope=self.RISKY, inherited=lambda comments: [reason])
        self.assertEqual(events, ['build'])  # no merge-check comment, no push
        self.assertEqual(verdict, 'PASS')  # the checks passed; the hold is separate, as for an unaudited PR
        self.assertEqual(details[-1], f'not merged by the runner: {reason}.')
        self.assertFalse(any('says "No blocking findings"' in line for line in details))
        (_, _, _, details), events = self.run_auto(
            FakeGitHub(labels=('automerge',), comments=[clean]), scope=self.RISKY, inherited=lambda comments: [])
        self.assertEqual(events, ['build', 'comment', 'push m1', 'sweep'])

    def test_a_lookup_that_cannot_finish_holds_the_merge_with_the_way_to_retry(self):
        why = f'{lane.INHERITED_FAILED}: rate limited. Remove and re-add automerge to check again'
        (_, _, _, details), events = self.run_auto(FakeGitHub(labels=('automerge',)), inherited=lambda comments: [why])
        self.assertEqual(events, ['build'])
        self.assertEqual(details[-1], f'not merged by the runner: {why}.')

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
        self.assertIn('the Codex or Claude audit on the head `aaaaaaa` has blocking findings', details[-1])

    def test_findings_that_only_mention_no_findings_elsewhere_still_hold(self):
        # The #414 audit's form: numbered findings, then "Nothing else found …" and "No packet or database changes."
        audit = ('**Codex audit (Astra) on `aaaaaaa`**\n\n1. **Plausible: one stop reason is shared by every item.** '
                 '`A.swift:626`\n   - Smallest fix: keep it per target; no findings elsewhere.\n\nNothing else found. '
                 'No packet or database changes.\n\nChecked by the SM Codex audit task; Codex ran read-only.')
        self.assertEqual(self.audited(audit)[1], ['build'])
        also = ('**Codex audit (Astra) on `aaaaaaa`**\n\n1. **Confirmed: data loss.**\n   - Scenario: …\n\n'
                'No findings against packets or owner data.\n')
        self.assertEqual(self.audited(also)[1], ['build'])
        clean = ('**Codex audit (Astra) on `aaaaaaa`**\n\nNo blocking findings on correctness, owner data, or Build 29 '
                 'compatibility. One plausible gap against "Done when":\n1. **Plausible: …**')
        self.assertEqual(self.audited(clean)[1], ['build', 'comment', 'push m1', 'sweep'])

    def test_the_newest_audit_of_the_head_decides(self):
        blocked = '**Codex audit (Astra) on `aaaaaaa`**\n\n### Blocking findings\n1. Wrong.'
        clean = '**Codex audit (Astra) on `aaaaaaa`**\n\nNo blocking findings.'
        self.assertEqual(self.audited(clean, blocked)[1], ['build'])
        self.assertEqual(self.audited(blocked, clean)[1], ['build', 'comment', 'push m1', 'sweep'])

    def test_a_manual_audit_counts_only_if_it_names_the_head(self):
        (_, _, _, details), events = self.audited('## Codex audit (gpt-6-astra, high)\n\nNo findings. Audited the PR.')
        self.assertEqual(events, ['build'])
        self.assertIn('has no Codex or Claude audit naming its head `aaaaaaa`', details[-1])
        older = '## Codex audit of `1234567`\n\nNo findings. The head `aaaaaaa` came later.'  # the sha only in the body
        self.assertEqual(self.audited(older)[1], ['build'])

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
                self.assertIn(f'not merged: held for T3: the newest T3 lane report on this PR is {verdict} (on {HEAD[:7]}: '
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

    def test_a_lane_change_is_held_for_a_codex_audit_of_its_head(self):
        # Owner rule 2026-10-01: lane PRs get the same audit hold as audio, persistence and packet PRs. The
        # audit script picks a PR up from this hold line ("not merged by the runner: … has no "Codex audit").
        scope = {'tier': 'T1', 'why': [], 'lane_paths': ['scripts/lane_sim.py'],
                 'files': [{'path': 'scripts/lane_sim.py', 'category': 'scripts'}]}
        held = lane.merge_blockers(scope, [], HEAD)
        self.assertIn('it touches the lane and has no Codex or Claude audit comment yet', held)
        findings = [comment('**Codex audit (Astra) on `aaaaaaa`**\n\n### Blocking findings\n1. The slot leaks.')]
        self.assertTrue(any('has blocking findings' in reason for reason in lane.merge_blockers(scope, findings, HEAD)))
        clean = [comment('**Codex audit (Astra) on `aaaaaaa`**\n\nNo blocking findings.')]
        self.assertFalse(any('Codex audit' in reason for reason in lane.merge_blockers(scope, clean, HEAD)))
        packet_too = dict(scope, files=scope['files'] + [{'path': 'A/Share.swift', 'category': 'packet'}])
        self.assertIn('it touches packets and the lane and has no Codex or Claude audit comment yet',
                      lane.merge_blockers(packet_too, [], HEAD))

    def test_audio_persistence_and_packet_changes_are_each_held_for_a_codex_audit(self):
        # The lane change above is held by its own rule; these kinds come from AUDITED, one entry each.
        for category, what in (('audio', 'the audio session'), ('persistence', 'persistence'), ('packet', 'packets')):
            with self.subTest(category=category):
                scope = {'tier': 'T3', 'why': [], 'lane_paths': [], 'files': [
                    {'path': 'App/X.swift', 'category': 'app-ui'}, {'path': 'App/Y.swift', 'category': category}]}
                self.assertEqual(lane.merge_blockers(scope, [], HEAD),
                                 [f'it touches {what} and has no Codex or Claude audit comment yet'])
                clean = [comment('**Codex audit (Astra) on `aaaaaaa`**\n\nNo blocking findings.')]
                self.assertEqual(lane.merge_blockers(scope, clean, HEAD), [])

    def test_an_ordinary_pr_is_not_held_for_an_audit(self):
        scope = {'tier': 'T2', 'why': [], 'lane_paths': [], 'files': [{'path': 'App/X.swift', 'category': 'app-ui'}]}
        self.assertEqual(lane.merge_blockers(scope, [], HEAD), [])
        self.assertEqual(lane.merge_blockers(self.SCOPE, [], HEAD), [])  # a policy from before lane_paths

    def test_lane_tests_themselves_are_not_desk_only(self):
        scope = {'tier': 'T1', 'why': [], 'files': [{'path': 'scripts/tests/test_lane_runner.py', 'category': 'scripts'}]}
        self.assertEqual(lane.merge_blockers(scope, [], HEAD), [])

    def test_a_pr_that_moved_or_lost_its_label_while_tested_is_not_merged(self):
        (_, _, _, details), events = self.run_auto(FakeGitHub(labels=('automerge',)), moved=True)
        self.assertEqual(events, ['build'])
        (_, _, _, details), events = self.run_auto(FakeGitHub(labels=()))
        self.assertEqual(events, ['build'])
        self.assertIn('lost the automerge label', details[-1])

    def test_a_pr_merged_by_another_run_while_tested_is_not_merged_again(self):
        github = FakeGitHub(labels=('automerge',))
        github.pull = lambda: {'head': {'sha': HEAD}, 'labels': [{'name': 'automerge'}], 'state': 'closed'}
        (_, _, _, details), events = self.run_auto(github)
        self.assertEqual((events, github.posted), (['build'], []))
        self.assertIn('was closed while it was tested', details[-1])

    def test_each_merge_the_runner_pushes_starts_hosted_integration_once(self):
        # #2127: a push with the workflow token starts no workflow, so hosted-integration's push trigger never saw
        # the runner's merges. Only a pushed merge dispatches; a refused push, then the re-merge, dispatches once.
        cases = [('pushed', {}, ['main']), ('refused, then pushed', {'verdicts': ('PASS', 'PASS'), 'pushes': (False, True)}, ['main']),
                 ('refused for good', {'verdicts': ('PASS',) * 3, 'pushes': (False,) * 3}, [])]
        for name, kw, expected in cases:
            with self.subTest(name):
                self.run_auto(FakeGitHub(labels=('automerge',)), **kw)
                self.assertEqual(self.dispatched, expected)

    def test_a_refused_push_means_next_moved_so_it_tests_again_on_the_newest_next(self):
        github = FakeGitHub(labels=('automerge',))
        (verdict, _, _, details), events = self.run_auto(github, verdicts=('PASS', 'PASS'), pushes=(False, True))
        self.assertEqual(events, ['build', 'comment', 'push m1', 'build', 'comment', 'push m2', 'sweep'])
        self.assertIn('attempt 1: the push to main was refused', ' '.join(details))
        self.assertIn('merged into main as m200000', details[-1])

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
            return real_automerge(scope, evidence, fast=lambda e, changed=None: lane.run_fast(e, runner=verify_tests, changed=changed), **kwargs)

        host_only = {'tier': 'T1', 'why': ['scripts'], 'files': [{'path': 'scripts/x.py', 'category': 'scripts'}]}
        with mock.patch.object(verification, 'input_identity', return_value='x'):
            (verdict, _, _, details), events = self.run_auto(FakeGitHub(labels=('automerge',)), scope=host_only,
                                                             pushes=(False, True), automerge=automerge)
        self.assertEqual((verdict, details[-1]), ('PASS', 'merged into main as m200000'), details)
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
        self.assertIn('not merged: the push to main failed', details[-1])
        self.assertTrue(lane.next_moved(' ! [rejected]        abc -> main (fetch first)'))
        self.assertTrue(lane.next_moved(' ! [rejected]        abc -> main (non-fast-forward)'))
        self.assertFalse(lane.next_moved('remote: Permission to uncomposed/x.git denied to github-actions[bot].'))
        self.assertFalse(lane.next_moved('fatal: unable to access \'https://github.com/x.git/\': The requested URL returned error: 403'))

    def test_it_gives_up_after_three_refused_pushes(self):
        github = FakeGitHub(labels=('automerge',))
        (verdict, _, _, details), events = self.run_auto(github, verdicts=('PASS',) * 3, pushes=(False,) * 3)
        self.assertEqual(events.count('build'), 3)
        self.assertIn('not merged: main kept moving (3 attempts)', details[-1])

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

    def test_a_second_call_in_the_same_job_keeps_its_own_lock_and_stays_warm(self):
        # A merge retry, or the automerge run a T3 PASS releases (#421), links the folders again in the job
        # that already holds the cache's lock; flock belongs to the open file, so a second open saw it busy.
        lane.warm_build_folders(self.tree, root=self.cache, free=lambda path: 10**12)
        again = self.warm()
        self.assertTrue(again.startswith('build folders: warm'), again)
        self.assertTrue((self.tree / '.build').is_symlink())

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

    def test_a_key_revisited_after_three_other_trees_keeps_its_build_products(self):
        # #863: two caches evicted an otherwise reusable key as SessionKit PRs interleaved.
        source = 'Packages/SessionKit/Sources/A.swift'
        self.commit(source, 'struct Original {}\n')
        self.warm()
        original = (self.tree / '.build').resolve()
        product = original / 'dd-simulator/Build/product'
        product.parent.mkdir(parents=True)
        product.write_text('built for Original')
        os.utime(original.parent, (1, 1))
        for n in range(3):
            self.commit(source, f'struct Other{n} {{}}\n')
            self.assertIn('cold, new cache', self.warm())
            os.utime((self.tree / '.build').resolve().parent, (n + 2, n + 2))
        self.commit(source, 'struct Original {}\n')
        self.assertTrue(self.warm().startswith('build folders: warm'))
        self.assertEqual((self.tree / '.build').resolve(), original)
        self.assertEqual(product.read_text(), 'built for Original')

    def test_it_keeps_at_most_the_limit_and_never_goes_below_the_disk_floor(self):
        for n in range(lane.WARM_KEEP + 1):
            self.commit('Packages/SessionKit/Sources/A.swift', f'struct A{n} {{}}\n')
            self.warm()
            time.sleep(0.01)
        self.assertEqual(len(self.caches()), lane.WARM_KEEP)
        self.assertIn('cold (less than 25 GB free)', self.warm(free=10**9))
        self.assertEqual(len(self.caches()), 1)  # this key's

    def test_the_floor_that_clears_idle_caches_sits_above_the_finisher_pause(self):
        # The Mac finisher pauses below MIN_FREE_GIB (ops/claude/sm_claude_worker.py), the build runner
        # waits below 20 GB. Caches must go before either, not after (#1775). Read the worker's own line, not a copy.
        worker_spec = importlib.util.spec_from_file_location('sm_claude_worker_for_floor', SCRIPTS.parent / 'ops' / 'claude' / 'sm_claude_worker.py')
        worker = importlib.util.module_from_spec(worker_spec)
        worker_spec.loader.exec_module(worker)
        self.assertGreater(lane.WARM_FREE_FLOOR, worker.MIN_FREE_GIB * 2**30)
        self.assertGreater(lane.WARM_FREE_FLOOR, lane.BUILD_RUNNER_FREE_DISK)

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


class AutomergeKeepsNoCacheTests(unittest.TestCase):
    """#1207: automerge runs build no app, yet linked a warm cache each and kept four per runner (1.3 GB of
    SwiftPM build apiece, about 9 GB on the build runners), which held them at the 20 GB disk floor."""
    setUp, commit, warm, caches = WarmBuildTests.setUp, WarmBuildTests.commit, WarmBuildTests.warm, WarmBuildTests.caches

    def run_auto(self):
        github = FakeGitHub(labels=('automerge',))
        with tempfile.TemporaryDirectory() as folder, \
                mock.patch.dict(os.environ, {'SM_LANE_WARM_DIR': str(self.cache)}), \
                mock.patch.object(lane, 'ROOT', self.tree), \
                mock.patch.object(lane, 'TESTED_RECORD', Path(folder) / 'tested.json'), \
                mock.patch.object(lane, 'build_merge_commit', return_value=(MERGE, [])), \
                mock.patch.object(lane, 'push_merge', return_value=(True, '')), \
                mock.patch.object(lane, 'sweep_merge_audit'), \
                mock.patch.object(lane, 'inherited_check', return_value=lambda comments: []), \
                mock.patch.object(lane, 'diff_scope', return_value={'tier': 'T1', 'why': ['x'], 'files': []}), \
                mock.patch.object(lane, 'hot_file_violations', return_value=[]), \
                mock.patch.object(lane, 'changed_paths_for_tests', return_value=None), \
                mock.patch.object(lane, 'run_automerge', return_value=('PASS', 'host only', 'host tests', [])):
            return lane.run_auto(github, {'title': 'T'}, 5, 'main', HEAD, MERGE, Path(folder), [])

    def cache_folder(self, name, checkout=None):
        cache = self.cache / (checkout or lane.checkout_folder(self.tree)) / name
        (cache / 'root').mkdir(parents=True)
        (cache / 'root/verification.lock').write_text('')
        (cache / 'sessionkit/out').mkdir(parents=True)
        (cache / 'sessionkit/out/SessionKit.o').write_bytes(b'x' * 8192)
        return cache

    def test_an_automerge_run_links_no_cache_and_keeps_none(self):
        verdict, _, _, details = self.run_auto()
        self.assertEqual(verdict, 'PASS', details)
        self.assertEqual(self.caches(), [])
        self.assertFalse((self.tree / '.build').is_symlink())
        self.assertFalse((self.tree / 'Packages/SessionKit/.build').is_symlink())
        self.assertIn('no cache kept', details[0])

    def test_after_a_t3_in_the_same_job_its_links_are_undone_and_its_cache_kept(self):
        self.warm()  # the T3's links; its job still holds the cache
        cache = (self.tree / '.build').resolve().parent
        built = cache / 'root/verification/SpokenMarginsAppBehavior/Build/product'
        built.parent.mkdir(parents=True)
        built.write_text('T3 build')
        line = lane.host_build_folders(self.tree, root=self.cache)
        self.assertFalse((self.tree / '.build').exists())
        self.assertFalse((self.tree / 'Packages/SessionKit/.build').exists())
        self.assertEqual(built.read_text(), 'T3 build')
        self.assertNotIn('removed', line)

    def test_idle_host_test_caches_are_removed_and_app_builds_and_busy_caches_stay(self):
        import fcntl
        idle = self.cache_folder('sk-idle-0000')
        busy = self.cache_folder('sk-busy-0000')
        t2 = self.cache_folder('sk-t2-0000')
        (t2 / 'root/dd-simulator').mkdir()
        t3 = self.cache_folder('sk-t3-0000')
        (t3 / 'root/verification/SpokenMarginsAppBehavior').mkdir(parents=True)
        other_runner = self.cache_folder('sk-idle-0000', checkout='checkout-0th3r000')
        with open(busy / '.lock', 'a+') as job:
            fcntl.flock(job, fcntl.LOCK_EX | fcntl.LOCK_NB)  # another job of this runner's, from an older runner
            line = lane.host_build_folders(self.tree, root=self.cache)
        self.assertFalse(idle.exists())
        for kept in (busy, t2, t3, other_runner):
            self.assertTrue(kept.exists(), kept)
        self.assertRegex(line, r'removed 1 idle host-test cache \(0\.0 GB\)')
        line = lane.host_build_folders(self.tree, root=self.cache)
        self.assertRegex(line, r'removed 1 idle host-test cache')  # the busy one, now that its job has ended
        self.assertNotIn('removed', lane.host_build_folders(self.tree, root=self.cache))  # once
        self.assertTrue(t2.exists() and t3.exists() and other_runner.exists())

    def test_a_checkout_with_no_caches_gets_no_folder(self):
        lane.host_build_folders(self.tree, root=self.cache)
        self.assertFalse(self.cache.exists())

    def test_the_job_empties_the_build_folders_it_kept_in_the_workspace(self):
        swiftpm = self.tree / 'Packages/SessionKit/.build/out'
        swiftpm.mkdir(parents=True)
        (swiftpm / 'SessionKit.o').write_text('host tests')
        (self.tree / '.build/dd-simulator').mkdir(parents=True)
        (self.tree / '.build/verification.lock').write_text('')
        lane.drop_workspace_builds(self.tree)
        self.assertFalse((self.tree / 'Packages/SessionKit/.build').exists())
        self.assertFalse((self.tree / '.build/dd-simulator').exists())

    def test_the_job_leaves_a_warm_cache_it_linked_alone(self):
        self.warm()
        product = self.tree / 'Packages/SessionKit/.build/out/product'
        product.parent.mkdir(parents=True)
        product.write_text('kept')
        lane.drop_workspace_builds(self.tree)
        self.assertEqual(product.read_text(), 'kept')

    def test_main_empties_them_when_an_automerge_job_ends(self):
        seen = []

        def auto(*args, **kwargs):
            (lane.ROOT / 'Packages/SessionKit/.build/out').mkdir(parents=True)
            return 'PASS', 'host only', 'host tests', []

        def drop(tree):
            real(tree)
            seen.append((tree / 'Packages/SessionKit/.build').exists())

        real = lane.drop_workspace_builds
        flow = MainFlowTests()
        with mock.patch.object(lane, 'run_auto', side_effect=auto), \
                mock.patch.object(lane, 'drop_workspace_builds', side_effect=drop):
            flow.run_main(FakeGitHub(labels=('automerge',)))
        self.assertEqual(seen, [False])


class BuildRunnerRoomTests(unittest.TestCase):
    """The second runner runs its automerge jobs only while the Mac has room (item 5)."""

    def wait(self, jobs, pressures, frees, max_wait=100):
        now = [0.0]
        states = {'jobs': list(jobs), 'pressure': list(pressures), 'free': list(frees)}
        take = lambda key: (states[key].pop(0) if len(states[key]) > 1 else states[key][0])
        with open(os.devnull, 'w') as quiet:
            return lane.wait_for_room_to_test_on_host(
                out=quiet, max_wait=max_wait, poll=10, clock=lambda: now[0],
                sleep=lambda seconds: now.__setitem__(0, now[0] + seconds),
                simulator_jobs=lambda: take('jobs'), pressure=lambda: take('pressure'),
                free=lambda: take('free'))[0], now[0]

    def test_it_starts_at_once_when_the_mac_has_room(self):
        self.assertEqual(self.wait([0], [1], [10**12]), (None, 0.0))

    def test_it_waits_for_the_simulator_job_pressure_and_disk_to_clear(self):
        result, waited = self.wait([1, 1, 0], [2, 2, 2, 1], [10**9, 10**12])
        self.assertIsNone(result)
        self.assertEqual(waited, 30.0)

    def test_it_gives_up_after_its_limit_and_says_why(self):
        result, _ = self.wait([0], [2], [10**9], max_wait=60)
        self.assertIn('waited 1m00s for room', result)
        for reason in ('memory pressure is above normal', 'less than 20 GB of disk is free'):
            self.assertIn(reason, result)
        result, _ = self.wait([1], [2], [10**9], max_wait=60)  # beside a simulator job: the trial's terms
        for reason in ('a simulator job is running and memory pressure is above normal', 'less than 30 GiB'):
            self.assertIn(reason, result)


class HostedIntegrationDispatchTests(unittest.TestCase):
    """#2127: after the runner pushes main, it asks GitHub to start hosted-integration.yml, since the push
    itself (the workflow token's) starts nothing. Never raises: a merge has already landed."""

    IN_JOB = {'GITHUB_ACTIONS': 'true', 'GH_TOKEN': 't', 'GH_REPO': 'o/r'}

    def dispatch(self, base='main', env=IN_JOB, result=None, error=None):
        with mock.patch.dict(os.environ, env, clear=True), \
                mock.patch.object(lane.subprocess, 'run', side_effect=error,
                                  return_value=result or subprocess.CompletedProcess([], 0, '', '')) as run:
            said = lane.dispatch_hosted_integration(base)
        return said, run

    def test_it_dispatches_the_workflow_on_next(self):
        said, run = self.dispatch()
        self.assertEqual(run.call_args.args[0], ['gh', 'api', '-X', 'POST',
                                                 'repos/o/r/actions/workflows/hosted-integration.yml/dispatches',
                                                 '-f', 'ref=main'])
        self.assertTrue(said.startswith('hosted integration started on main'), said)

    def test_outside_a_lane_job_or_off_next_it_sends_nothing(self):
        cases = [('no Actions', {'GH_TOKEN': 't', 'GH_REPO': 'o/r'}, 'main'),
                 ('no token (the PR code environment)', {'GITHUB_ACTIONS': 'true', 'GH_REPO': 'o/r'}, 'main'),
                 ('no repository', {'GITHUB_ACTIONS': 'true', 'GH_TOKEN': 't'}, 'main'),
                 ('another base', self.IN_JOB, 'next')]
        for name, env, base in cases:
            with self.subTest(name):
                said, run = self.dispatch(base, env)
                run.assert_not_called()
                self.assertTrue(said.startswith('hosted integration not started'), said)

    def test_a_refusal_or_an_error_is_reported_not_raised(self):
        # Until the workflow file is on main, GitHub answers 404 (workflow_dispatch needs the default branch).
        refused = subprocess.CompletedProcess([], 1, '', 'gh: Not Found (HTTP 404)')
        for name, kw in [('refused', {'result': refused}), ('gh missing', {'error': FileNotFoundError('gh')}),
                         ('timed out', {'error': subprocess.TimeoutExpired('gh', 60)})]:
            with self.subTest(name):
                said, _ = self.dispatch(**kw)
                self.assertTrue(said.startswith('hosted integration not started'), said)
        self.assertIn('HTTP 404', self.dispatch(result=refused)[0])


class PushTests(unittest.TestCase):
    """Building and pushing the merge commit, with real git and a bare origin."""

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        root = Path(self.temporary.name)
        self.origin, self.tree, self.other = root / 'origin.git', root / 'tree', root / 'other'
        self.git = ['git', '-c', 'user.name=t', '-c', 'user.email=t@example.com', '-c', 'init.defaultBranch=main']
        subprocess.run(self.git + ['init', '-q', '--bare', str(self.origin)], check=True)
        subprocess.run(self.git + ['clone', '-q', str(self.origin), str(self.other)], check=True, capture_output=True)
        self.commit(self.other, 'shared.txt', 'one\n')
        subprocess.run(self.git + ['-C', str(self.other), 'push', '-q', 'origin', 'HEAD:main'], check=True)
        subprocess.run(self.git + ['clone', '-q', '-b', 'main', str(self.origin), str(self.tree)], check=True)
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
        lane.fetch_base(self.tree, 'main')
        sha, conflicts = lane.build_merge_commit(self.tree, 'main', head, 5, 'A change')
        self.assertEqual(conflicts, [])
        parents = subprocess.check_output(['git', '-C', str(self.tree), 'rev-list', '--parents', '-n', '1', sha],
                                          text=True).split()[1:]
        self.assertEqual(parents, [self.rev(self.tree, 'origin/main'), head])
        self.assertIn('Merge pull request #5: A change',
                      subprocess.check_output(['git', '-C', str(self.tree), 'log', '-1', '--format=%B', sha], text=True))
        self.assertTrue(lane.push_merge(self.tree, sha, 'main')[0])
        self.assertEqual(self.rev(self.origin, 'main'), sha)

    def test_the_push_is_refused_when_next_moved_after_the_test(self):
        self.commit(self.tree, 'pr.txt', 'pr\n')
        head = self.rev(self.tree, 'HEAD')
        lane.fetch_base(self.tree, 'main')
        sha, _ = lane.build_merge_commit(self.tree, 'main', head, 5, 'A change')
        self.commit(self.other, 'other.txt', 'someone else merged\n')
        subprocess.run(self.git + ['-C', str(self.other), 'push', '-q', 'origin', 'HEAD:main'], check=True)
        moved = self.rev(self.origin, 'main')
        pushed, message = lane.push_merge(self.tree, sha, 'main')
        self.assertFalse(pushed)
        self.assertIn('rejected', message)
        self.assertTrue(lane.next_moved(message), message)  # so the runner tests again
        self.assertEqual(self.rev(self.origin, 'main'), moved)  # nothing untested landed

    def test_a_conflict_names_the_files_and_leaves_the_tree_clean(self):
        self.commit(self.tree, 'shared.txt', 'pr side\n')
        head = self.rev(self.tree, 'HEAD')
        self.commit(self.other, 'shared.txt', 'main side\n')
        subprocess.run(self.git + ['-C', str(self.other), 'push', '-q', 'origin', 'HEAD:main'], check=True)
        lane.fetch_base(self.tree, 'main')
        self.assertEqual(lane.build_merge_commit(self.tree, 'main', head, 5, 'x'), (None, ['shared.txt']))
        self.assertEqual(subprocess.check_output(['git', '-C', str(self.tree), 'status', '--porcelain'], text=True), '')


class MainFlowTests(unittest.TestCase):
    def run_main(self, github, event_head=HEAD, verdict='PASS', *extra, evidence=None, t2=None):
        with tempfile.TemporaryDirectory() as temporary, \
                mock.patch.object(lane, 'ROOT', Path(temporary)), \
                mock.patch.object(lane, 'GitHub', return_value=github), \
                mock.patch.dict('os.environ', {'GH_REPO': 'o/r', 'SM_LANE_EVIDENCE_DIR': evidence or temporary,
                                               # set, not inherited: runner two's own .env has role=build,
                                               # and these tests run inside a lane job, maybe a re-run
                                               'SM_LANE_RUNNER_ROLE': self.role, 'GITHUB_RUN_ATTEMPT': self.attempt,
                                               # the test's own temp folder, never a real lane job's
                                               'RUNNER_TEMP': temporary,
                                               # nor the Mac's lane state (the step ledger, #1200)
                                               'SM_LANE_STATE_DIR': self.state_dir or temporary}), \
                mock.patch.object(lane, 'Repo', return_value=self.ops), \
                mock.patch.object(lane, 'run_t2', side_effect=t2,
                                  return_value=(verdict, 'simulator build (pass), device build (pass)', [])), \
                mock.patch.object(lane, 'sweep_runner_simulators'), \
                mock.patch.object(lane, 'auto_revert', return_value='nothing to revert') as self.auto_revert, \
                mock.patch.object(lane, 'fetch_base', return_value=MERGE), \
                mock.patch.object(lane, 'merge_base_branch', return_value=self.conflicts), \
                mock.patch.object(lane, 'link_tools'), mock.patch('builtins.print'), \
                mock.patch.object(lane, 'prune_lane_folder', return_value='lane folder prune: test'), \
                mock.patch.object(lane, 'warm_build_folders', return_value='build folders: warm (SessionKit test)'):
            return lane.main(['--pr', '5', '--event-head', event_head, '--run-id', '42', *extra])

    def test_a_run_for_a_merged_or_closed_pr_tests_nothing(self):
        # #860: a queued run for a PR that merged meanwhile used to spend a full host-test and build cycle.
        for state in ('closed', 'merged'):
            github = FakeGitHub(labels=('automerge',))
            github.pull = lambda state=state: {'state': 'closed' if state == 'merged' else state,
                                               'head': {'sha': HEAD}, 'labels': [{'name': 'automerge'}]}
            with mock.patch.object(lane, 'run_auto') as run_auto, mock.patch.object(lane, 'run_t2') as run_t2:
                self.assertEqual(self.run_main(github, HEAD, 'PASS', '--mode', 'auto'), 0)
            run_auto.assert_not_called()
            run_t2.assert_not_called()
            self.assertEqual(github.posted, [])

    conflicts = []
    role = ''  # the main runner, unless a test says otherwise
    state_dir = None  # the lane state folder: the run's temporary folder unless a test names one
    ops = mock.Mock()  # Repo(...): what main posts on #337
    attempt = '1'

    def retry_fault_report(self, released_t3=False, throws=False, exhausted=False):
        real_auto = lane.run_auto

        def retry(*args, **kwargs):
            second = RuntimeError('runner failed after retry') if throws else (
                'INCONCLUSIVE', 'host only', 'interrupted', ['host tests ran out of time'])
            if exhausted:
                second = ('PASS', 'host only', 'passed', [])
            with mock.patch.object(lane, 'build_merge_commit', return_value=('m' * 40, [])), \
                    mock.patch.object(lane, 'inherited_check', return_value=lambda comments: []), \
                    mock.patch.object(lane, 'diff_scope', return_value={'tier': 'T1', 'why': [], 'files': []}), \
                    mock.patch.object(lane, 'run_automerge', side_effect=[('PASS', 'host only', 'passed', []), second]), \
                    mock.patch.object(lane, 'push_merge', return_value=(False, '! [rejected] (fetch first)')), \
                    mock.patch.object(lane, 'fetch_base', side_effect=[NEWER, 'd' * 40]), \
                    mock.patch.object(lane, 'untested_moves', return_value=(None, 'build inputs changed')):
                result = real_auto(*args, **kwargs, attempts=2)
                self.last_retry_note = lane.tested_note()
                return result

        github = FakeGitHub(labels=('automerge', 'lane:queued') if released_t3 else ('automerge',),
                            comments=[self.T3_REQUEST, self.held_report()] if released_t3 else [])
        with mock.patch.object(lane, 'run_auto', side_effect=retry), \
                mock.patch.object(lane, 't3_scope', return_value=([], [])), \
                mock.patch.object(lane, 'run_t3', return_value=('PASS', 'sim', 'ran', [], 'none', '')), \
                mock.patch.object(lane, 'clean_tree'):
            self.run_main(github)
        return next(body for body in reversed(github.posted) if body.startswith('Lane report'))

    def test_a_t3_on_a_checkout_left_with_lfs_pointers_is_a_runner_fault_and_starts_nothing(self):
        # #2139: pointers from a checkout without LFS failed SupertonicSpeechTests as the PR's FAIL.
        github = FakeGitHub(comments=[comment('/lane T3\ntests: SupertonicSpeechTests')])
        fault = 'runner fault, not the PR (#2139): Resources/model.onnx: LFS pointer, not the model.'
        with mock.patch.object(lane, 'ensure_lfs_files', return_value=fault), \
                mock.patch.object(lane, 'run_t3', side_effect=AssertionError('no simulator run')):
            self.assertEqual(self.run_main(github), 0)
        body = next(body for body in github.posted if body.startswith('Lane report'))
        self.assertIn('— INCONCLUSIVE', body)
        self.assertIn('LFS pointer, not the model', body)

    def test_auto_fault_after_retry_reports_the_base_it_actually_tested(self):
        for throws in (False, True):
            with self.subTest(throws=throws):
                body = self.retry_fault_report(throws=throws)
                self.assertIn('— INCONCLUSIVE', body)
                self.assertEqual(lane.TESTED_ON.search(body).group(2), NEWER[:7])
                self.assertEqual(json.loads(lane.MARKER.search(body).group(1))['next'], NEWER)

    def test_t3_released_fault_after_retry_reports_the_base_it_actually_tested(self):
        for throws in (False, True):
            with self.subTest(throws=throws):
                body = self.retry_fault_report(released_t3=True, throws=throws)
                self.assertIn('— INCONCLUSIVE', body)
                self.assertEqual(lane.TESTED_ON.search(body).group(2), NEWER[:7])
                self.assertEqual(json.loads(lane.MARKER.search(body).group(1))['next'], NEWER)

    def test_exhausted_retries_do_not_claim_an_unused_fetched_base_was_tested(self):
        body = self.retry_fault_report(exhausted=True)
        self.assertIn('— PASS', body)
        self.assertEqual(lane.TESTED_ON.search(body).group(2), NEWER[:7])
        self.assertEqual(json.loads(lane.MARKER.search(body).group(1))['next'], NEWER)
        self.assertEqual(self.last_retry_note, f' (tested merged with main at {NEWER[:7]})')

    def test_main_flow_fixture_does_not_delete_callers_build_folders(self):
        with tempfile.TemporaryDirectory() as caller:
            root = Path(caller)
            sentinels = [root / '.build' / name / 'active-product'
                         for name in ('dd-simulator', 'dd-device', 'verification')]
            for sentinel in sentinels:
                sentinel.parent.mkdir(parents=True)
                sentinel.write_text('caller-owned build evidence')
            github = FakeGitHub(comments=[comment('/lane T2')])
            with mock.patch.object(lane, 'ROOT', root):
                self.run_main(github)
            for sentinel in sentinels:
                self.assertTrue(sentinel.exists(), f'the test deleted {sentinel}')
                self.assertEqual(sentinel.read_text(), 'caller-owned build evidence')

    def test_main_flow_still_cleans_its_own_cold_build_folders(self):
        caches = []

        def t2(evidence):
            for name in ('dd-simulator', 'verification'):
                cache = lane.ROOT / '.build' / name
                cache.mkdir(parents=True)
                (cache / 'scratch-product').write_text('fixture-owned')
                caches.append(cache)
            return 'PASS', 'simulator build (pass), device build (pass)', []

        github = FakeGitHub(comments=[comment('/lane T2')])
        # Observe the real runner cleanup, before TemporaryDirectory removes the fixture root.
        with mock.patch.object(lane.shutil, 'rmtree', wraps=lane.shutil.rmtree) as cleanup:
            self.run_main(github, t2=t2)
        removed = [Path(call.args[0]) for call in cleanup.call_args_list]
        self.assertEqual(len(caches), 2)
        for cache in caches:
            self.assertIn(cache, removed)

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
        self.assertEqual(github.label_changes, [('lane:queued', 'lane:running'), ('lane:running', None),
                                                ('lane:done', 'lane:done')])

    def test_every_finished_run_adds_lane_done_as_a_new_labeled_event(self):
        # The Hourly dispatch fires on lane:done's `labeled` event. #432's second T3 report (2026-09-30
        # 16:02Z) made none: its earlier lane:done was still on, so adding it again was no event.
        github = FakeGitHub(labels=('lane:queued', 'lane:done'), comments=[comment('/lane T2')])
        self.run_main(github)
        self.assertEqual(github.labeled, ['lane:running', 'lane:done'])
        self.assertEqual(github.labels, {'lane:done'})
        self.assertEqual(github.label_changes[0], ('lane:done', None))

    def test_a_run_makes_its_event_even_when_the_other_job_added_lane_done_meanwhile(self):
        # The lane and automerge jobs run side by side: an automerge report during a T3 adds lane:done.
        github = FakeGitHub(comments=[comment('/lane T2')])
        def t2(evidence):
            github.relabel(None, 'lane:done')
            return 'PASS', 'simulator build (pass), device build (pass)', []
        self.run_main(github, t2=t2)
        self.assertEqual(github.labeled, ['lane:running', 'lane:done', 'lane:done'])

    def test_a_waiting_test_desk_request_keeps_the_labels_as_they_were(self):
        waiting = FakeGitHub(labels=('lane:queued', 'lane:done'), comments=[comment('/lane T4\nrun: J1'),
                                                                            comment('/lane T2')])
        self.run_main(waiting)  # the Test Desk's T4 keeps lane:queued, so this run doesn't take it
        self.assertEqual((waiting.labels, waiting.labeled), ({'lane:queued', 'lane:done'}, []))

    def test_an_automerge_run_that_does_not_merge_adds_lane_done_as_a_new_labeled_event(self):
        # A FAIL, an INCONCLUSIVE, or a PASS the runner won't merge (no audit, lane files, T3 gate) is
        # something to pick up, so it wakes the Hourly dispatch like a /lane report does.
        github = FakeGitHub(labels=('automerge', 'lane:queued', 'lane:done'),
                            comments=[comment('/lane T3\ntests: T/A')])
        self.run_mode(github, 'auto')
        self.assertEqual(github.labeled, ['lane:done'])
        self.assertEqual(github.labels, {'automerge', 'lane:queued', 'lane:done'})  # the lane job's queue stays

    def test_an_automerge_run_that_merges_leaves_the_labels_alone(self):
        github = FakeGitHub(labels=('automerge', 'lane:done'))
        self.run_automerge_main(github, details=['merged into main as abc1234'])
        self.assertEqual((github.label_changes, github.labeled), ([], []))  # the PR closes

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

    def test_the_workflow_gets_the_verdict_so_the_check_is_red_on_fail(self):
        # lane.yml's Verdict step fails on verdict=FAIL; reported=true keeps the tidy step quiet.
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
        # Every Mac job checks out the Git LFS models: --plan fast's contracts check reads them (#301). The third is
        # the release job a T3 PASS hands to a build runner (#1209). The lane job checks them out on the Mac, and on a
        # GitHub-hosted Mac fetches them from a cache instead (#1389 phase 2, test_lane_hosted_app.py).
        self.assertEqual(workflow.count('lfs: true'), 2)  # the release job and the automerge-mac fallback (#2459)
        self.assertIn("lfs: ${{ runner.environment != 'github-hosted' }}", workflow)
        self.assertIn("lfs: ${{ !contains(fromJSON(needs.route.outputs.automerge || '[]'), 'ubuntu-latest') }}", workflow)
        # hosted routing plus the four Mac jobs (automerge-mac, #2459)
        self.assertEqual(workflow.count('persist-credentials: false'), 5)
        self.assertIn("if: steps.run.outputs.reported == 'true'", workflow)
        self.assertIn("if: (failure() || cancelled()) && steps.run.outputs.reported != 'true'", workflow)

    @staticmethod
    def verdict_steps() -> list[str]:
        """The shell script of each job's Verdict step in lane.yml."""
        workflow = (Path(__file__).resolve().parents[2] / '.github/workflows/lane.yml').read_text()
        scripts = []
        for step in workflow.split('      - name: Verdict\n')[1:]:
            lines = []
            for line in step.split('        run: |\n', 1)[1].splitlines():
                if line.strip() and not line.startswith(' ' * 10):
                    break
                lines.append(line[10:])
            scripts.append('\n'.join(lines))
        return scripts

    def test_the_check_is_red_only_on_fail(self):
        # Project threads wake when a check on their PR fails. A FAIL is the PR's code; an INCONCLUSIVE report
        # (held for T3, no simulator, XCTest never connected, a flood, a conflict with main) isn't, so its check
        # stays green with a warning, and the report and the lane:done relabel carry it to the dispatcher.
        # In 13 hours on 2026-09-30, 29 of the lane's 46 red checks were INCONCLUSIVE, 20 of them held for T3.
        scripts = self.verdict_steps()
        # the lane job's, the automerge job's, its automerge-mac fallback's (#2459) and the release job's (#1209)
        self.assertEqual(len(scripts), 4)
        for job, script in zip(('lane', 'automerge', 'automerge-mac', 'release'), scripts):
            # The release job's check sits on main's tip, not on the PR (#1209): a FAIL there stays a warning.
            fail = ('FAIL', 0, '::warning title=Lane FAIL') if job == 'release' else ('FAIL', 1, '::error title=Lane FAIL')
            for verdict, code, annotation in (('PASS', 0, None), ('INCONCLUSIVE', 0, '::warning title=Lane INCONCLUSIVE'),
                                              fail):
                with self.subTest(job=job, verdict=verdict):
                    # GitHub runs a step's script with bash -e when the step names no shell.
                    done = subprocess.run(['bash', '-e', '-c', script], env=dict(os.environ, VERDICT=verdict),
                                          capture_output=True, text=True)
                    self.assertEqual(done.returncode, code, done.stdout + done.stderr)
                    self.assertIn(f'Lane verdict: {verdict}', done.stdout)
                    if annotation:
                        self.assertIn(annotation, done.stdout)
                    else:
                        self.assertNotIn('::', done.stdout)

    def run_automerge_main(self, github, verdict='PASS', details=()):
        # run_auto does real git in the runner's tree; here it is faked, so the tree is never touched.
        with mock.patch.object(lane, 'run_auto',
                               return_value=(verdict, 'x', 'host tests; builds', list(details))) as run:
            self.run_main(github)
        return None, run

    def test_the_automerge_label_is_a_request_by_itself(self):
        github = FakeGitHub(labels=('automerge',))
        _, run = self.run_automerge_main(github)
        run.assert_called_once()
        self.assertTrue(github.posted[0].startswith('Lane report pr5-r42 — PASS'), github.posted)
        self.assertIn('tier auto', github.posted[0])
        self.assertEqual(github.label_changes, [('lane:done', 'lane:done')])  # queued and running are the lane job's

    def test_an_explicit_request_goes_before_the_automerge_checks(self):
        github = FakeGitHub(labels=('automerge', 'lane:queued'), comments=[comment('/lane T2')])
        _, run = self.run_automerge_main(github)
        run.assert_not_called()
        self.assertIn('tier T2', github.posted[0])

    def test_an_automerge_run_runs_again_even_for_the_same_head_and_next(self):
        # Re-adding the label is how to retry a PASS that didn't merge (no audit yet, main moved).
        github = FakeGitHub(labels=('automerge',))
        self.run_automerge_main(github, 'PASS')
        _, run = self.run_automerge_main(github)
        run.assert_called_once()
        self.assertEqual(len([b for b in github.posted if b.startswith('Lane report')]), 2)
        self.assertEqual(github.label_changes, [('lane:done', 'lane:done')] * 2)

    def test_a_run_without_lane_queued_or_automerge_posts_nothing(self):
        github = FakeGitHub(labels=())
        self.run_main(github)
        self.assertEqual((github.posted, github.label_changes), ([], []))

    def run_mode(self, github, mode, role='', no_room=None):
        self.role = role
        self.addCleanup(setattr, self, 'role', '')
        with mock.patch.object(lane, 'run_auto', return_value=('PASS', 'x', 'host tests; builds', [])) as auto, \
                mock.patch.object(lane, 'run_t3', return_value=('PASS', 'x', 'T/A', [], 'none', '')) as t3, \
                mock.patch.object(lane, 'wait_for_room_to_test_on_host', return_value=(no_room, None)) as wait:
            self.run_main(github, HEAD, 'PASS', '--mode', mode)
        self.role = ''
        return auto, t3, wait

    def test_the_automerge_job_never_answers_a_lane_request(self):
        github = FakeGitHub(labels=('automerge', 'lane:queued'), comments=[comment('/lane T3\ntests: T/A')])
        auto, t3, _ = self.run_mode(github, 'auto')
        auto.assert_called_once()
        t3.assert_not_called()
        self.assertIn('tier auto', github.posted[0])
        self.assertEqual(github.label_changes, [('lane:done', 'lane:done')])  # lane:queued stays for the lane job
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
        self.assertIn('does not merge cleanly into main', github.posted[0])
        self.assertIn('App/Shared.swift', github.posted[0])


    # #421: an automerge run held by the T3 gate merged only after someone pushed again or re-added the
    # label, and a label the runner re-adds with the workflow's GITHUB_TOKEN starts no run. So the lane job
    # that reports the T3 PASS runs the held automerge run itself.
    T3_REQUEST = comment('/lane T3\ntests: SupertonicSpeechTests')

    def held_report(self, commit=HEAD, why=None):
        why = why or lane.t3_gate([self.T3_REQUEST])[1]
        return comment(lane.report('pr5-r41', 'INCONCLUSIVE', commit, MERGE, 'auto', 'x', 1, 'x',
                                   [f'not merged: {why}.'], 'none', '/e', 'owner',
                                   lane.identity('auto', commit, MERGE, [])), login='github-actions[bot]')

    def run_t3_main(self, github, t3_verdict='PASS', auto_verdict='PASS',
                    auto_details=('merged into main as m000000',)):
        with mock.patch.object(lane, 't3_scope', return_value=([], [])), \
                mock.patch.object(lane, 'run_t3', return_value=(t3_verdict, 'sim', 'ran', [], 'none', '')), \
                mock.patch.object(lane, 'clean_tree', create=True) as clean, \
                mock.patch.object(lane, 'run_auto', return_value=(auto_verdict, 'x', 'host tests; builds',
                                                                  list(auto_details))) as auto:
            self.run_main(github)
        return auto, clean

    def test_a_t3_pass_runs_the_automerge_run_the_t3_gate_held_in_the_same_job(self):
        github = FakeGitHub(labels=('automerge', 'lane:queued'), comments=[self.T3_REQUEST, self.held_report()])
        auto, clean = self.run_t3_main(github)
        auto.assert_called_once()
        clean.assert_called_once()
        self.assertEqual(auto.call_args[0][4], HEAD)  # the head the T3 passed on
        self.assertTrue(github.posted[0].startswith('Lane report pr5-r42 — PASS'), github.posted[0])
        self.assertIn('tier T3', github.posted[0])
        self.assertTrue(github.posted[1].startswith('Lane report pr5-r42-auto — PASS'), github.posted[1])
        self.assertIn('tier auto', github.posted[1])
        self.assertIn(f'started by the T3 PASS ({github._comments[2]["html_url"]})', github.posted[1])
        self.assertIn('merged into main as m000000', github.posted[1])
        self.assertEqual(lane.report_identity(github.posted[1])['tier'], 'auto')
        # lane:running comes off as after any T3, and no lane:done: the released run merged, so the PR closes.
        # The automerge report answers no /lane request.
        self.assertEqual(github.label_changes, [('lane:queued', 'lane:running'), ('lane:running', None)])
        self.assertEqual(lane.pending_requests(github.comments()), (None, False))

    def test_lane_done_comes_after_the_released_automerge_report_when_it_does_not_merge(self):
        # One event for the whole job, after its last report, so the Hourly dispatch reads the final outcome.
        github = FakeGitHub(labels=('automerge', 'lane:queued'), comments=[self.T3_REQUEST, self.held_report()])
        reports_before_done, relabel = [], github.relabel

        def spy(remove, add):
            if add == 'lane:done':
                reports_before_done.append(len(github.posted))
            relabel(remove, add)
        github.relabel = spy
        self.run_t3_main(github, auto_details=['not merged by the runner: it touches audio and has no audit yet.'])
        self.assertTrue(github.posted[1].startswith('Lane report pr5-r42-auto — PASS'), github.posted[1])
        self.assertEqual((github.labeled, reports_before_done), (['lane:running', 'lane:done'], [2]))

    def test_a_pr_held_by_an_older_runner_s_wording_is_released_too(self):
        old = ("this PR's newest /lane T3 request has no lane report yet; after a T3 PASS, push or remove and "
               're-add automerge to merge')
        github = FakeGitHub(labels=('automerge', 'lane:queued'), comments=[self.T3_REQUEST, self.held_report(why=old)])
        auto, _ = self.run_t3_main(github)
        auto.assert_called_once()

    def test_a_t3_fail_or_inconclusive_or_a_pass_without_automerge_starts_no_automerge_run(self):
        for labels, verdict in ((('automerge', 'lane:queued'), 'FAIL'), (('automerge', 'lane:queued'), 'INCONCLUSIVE'),
                                (('lane:queued',), 'PASS')):
            with self.subTest(labels=labels, verdict=verdict):
                github = FakeGitHub(labels=labels, comments=[self.T3_REQUEST, self.held_report()])
                auto, clean = self.run_t3_main(github, t3_verdict=verdict)
                auto.assert_not_called()
                clean.assert_not_called()
                self.assertEqual(len(github.posted), 1)
                self.assertIn(f'— {verdict}', github.posted[0])

    def test_a_t3_pass_starts_no_automerge_run_unless_the_newest_one_on_this_head_was_held(self):
        merged_pass = comment(lane.report('pr5-r41', 'PASS', HEAD, MERGE, 'auto', 'x', 1, 'x', ['merged'], 'none',
                                          '/e', 'owner', lane.identity('auto', HEAD, MERGE, [])),
                              login='github-actions[bot]')
        cases = {
            'no automerge report yet (the automerge run is still going, and reads the T3 itself)': [self.T3_REQUEST],
            'held, but on an older head (the push since started a new automerge run)': [
                self.T3_REQUEST, self.held_report(commit=NEWER)],
            'a newer automerge report on this head was not held': [
                self.T3_REQUEST, self.held_report(), merged_pass, comment('/lane T3\ntests: SupertonicSpeechTests')],
        }
        for name, comments in cases.items():
            with self.subTest(name):
                github = FakeGitHub(labels=('automerge', 'lane:queued'), comments=comments)
                auto, _ = self.run_t3_main(github)
                auto.assert_not_called()
                self.assertEqual(len(github.posted), 1)

    def test_an_identical_t3_request_already_passed_releases_a_held_run_too(self):
        wanted = lane.identity('T3', HEAD, MERGE, ['SupertonicSpeechTests'])
        passed = runner_report('PASS', wanted, url='https://example.test/t3-pass')
        # A second T3 request made the automerge run wait for its report, which is "already reported".
        github = FakeGitHub(labels=('automerge', 'lane:queued'),
                            comments=[self.T3_REQUEST, passed, self.T3_REQUEST, self.held_report()])
        auto, _ = self.run_t3_main(github)
        auto.assert_called_once()
        self.assertTrue(github.posted[0].startswith('Lane: identical T3 request'), github.posted[0])
        self.assertIn('started by the T3 PASS (https://example.test/t3-pass)', github.posted[1])
        failed = FakeGitHub(labels=('automerge', 'lane:queued'), comments=[
            self.T3_REQUEST, runner_report('FAIL', wanted), self.T3_REQUEST, self.held_report()])
        auto, _ = self.run_t3_main(failed)
        auto.assert_not_called()

    def test_a_lane_fault_in_the_released_run_is_reported_not_silent(self):
        github = FakeGitHub(labels=('automerge', 'lane:queued'), comments=[self.T3_REQUEST, self.held_report()])
        with mock.patch.object(lane, 't3_scope', return_value=([], [])), \
                mock.patch.object(lane, 'run_t3', return_value=('PASS', 'sim', 'ran', [], 'none', '')), \
                mock.patch.object(lane, 'clean_tree', create=True), \
                mock.patch.object(lane, 'run_auto', side_effect=RuntimeError('checkout refused')):
            self.run_main(github)
        self.assertTrue(github.posted[1].startswith('Lane report pr5-r42-auto — INCONCLUSIVE'), github.posted[1])
        self.assertIn("RuntimeError('checkout refused')", github.posted[1])

    def test_the_identical_request_path_links_the_test_tools_before_the_released_run(self):
        # That path returns before the job links .venv and node_modules into the fresh checkout, and
        # verify-tests.py --plan fast stops without them: the released run would report a false FAIL.
        wanted = lane.identity('T3', HEAD, MERGE, ['SupertonicSpeechTests'])
        github = FakeGitHub(labels=('automerge', 'lane:queued'), comments=[
            self.T3_REQUEST, runner_report('PASS', wanted), self.T3_REQUEST, self.held_report()])
        with mock.patch.object(lane, 'tools_source', create=True, return_value=Path('/tools')) as tools:
            auto, _ = self.run_t3_main(github)
        auto.assert_called_once()
        tools.assert_called_once()

    def test_a_failure_while_releasing_leaves_the_t3_verdict_and_says_so_on_the_pr(self):
        github = FakeGitHub(labels=('automerge', 'lane:queued'), comments=[self.T3_REQUEST, self.held_report()])
        with mock.patch.object(lane, 'merge_after_t3', create=True, side_effect=RuntimeError('gh api: 502')), \
                mock.patch.object(lane, 't3_scope', return_value=([], [])), \
                mock.patch.object(lane, 'run_t3', return_value=('PASS', 'sim', 'ran', [], 'none', '')):
            self.assertEqual(self.outcome(github), {'reported': 'true', 'verdict': 'PASS'})
        self.assertTrue(github.posted[-1].startswith('Lane: the automerge run after the T3 PASS stopped'),
                        github.posted[-1])
        self.assertIn("RuntimeError('gh api: 502')", github.posted[-1])
        self.assertTrue(lane.is_automerge_comment(github.posted[-1]))  # it answers no /lane request

    def test_an_automerge_job_whose_hold_was_passed_by_a_t3_meanwhile_runs_again(self):
        # The race: the automerge job read no T3 report, the T3 job posted PASS and found no held report
        # to release, then the automerge job posted its held report. The automerge job releases itself.
        github = FakeGitHub(labels=('automerge',), comments=[self.T3_REQUEST])
        t3_pass = runner_report('PASS', lane.identity('T3', HEAD, MERGE, ['SupertonicSpeechTests']))
        held = f'not merged: {lane.t3_gate([self.T3_REQUEST])[1]}.'
        results = [('INCONCLUSIVE', 'x', 'host tests; builds', [held]),
                   ('PASS', 'x', 'host tests; builds', ['merged into main as m000000'])]

        def run_auto(*_args, **_kwargs):
            if len(results) == 2:
                github._comments.append(t3_pass)  # landed after this run read the T3 reports
            return results.pop(0)
        with mock.patch.object(lane, 'run_auto', side_effect=run_auto) as auto, \
                mock.patch.object(lane, 'clean_tree', create=True):
            self.run_main(github, HEAD, 'PASS', '--mode', 'auto')
        self.assertEqual(auto.call_count, 2)
        self.assertTrue(github.posted[0].startswith('Lane report pr5-r42 — INCONCLUSIVE'), github.posted[0])
        self.assertTrue(github.posted[1].startswith('Lane report pr5-r42-auto — PASS'), github.posted[1])
        self.assertIn('started again in the same automerge job', github.posted[1])
        self.assertEqual(github.label_changes, [])  # the second run merged: no lane:done, the PR closes
        still_held = FakeGitHub(labels=('automerge',), comments=[self.T3_REQUEST])
        with mock.patch.object(lane, 'run_auto', return_value=('INCONCLUSIVE', 'x', 'ran', [held])) as auto, \
                mock.patch.object(lane, 'clean_tree', create=True):
            self.run_main(still_held, HEAD, 'PASS', '--mode', 'auto')
        auto.assert_called_once()
        self.assertEqual((len(still_held.posted), still_held.labeled), (1, ['lane:done']))

    def test_the_workflow_gives_the_lane_job_room_for_the_released_automerge_run(self):
        workflow = (Path(__file__).resolve().parents[2] / '.github/workflows/lane.yml').read_text()
        lane_job = workflow.split('\n  lane:\n')[1].split('\n  automerge:\n')[0]
        self.assertIn('timeout-minutes: 240', lane_job)

class MergeTests(unittest.TestCase):
    """The runner merges the newest base into the PR head itself, with real git."""

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        root = Path(self.temporary.name)
        self.origin, self.tree = root / 'origin', root / 'tree'
        git = ['git', '-c', 'user.name=t', '-c', 'user.email=t@example.com', '-c', 'init.defaultBranch=main']
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
        self.commit(self.origin, 'lane.yml', 'new on main\n')
        base = lane.fetch_base(self.tree, 'main')
        self.assertEqual(base, subprocess.check_output(['git', '-C', str(self.origin), 'rev-parse', 'HEAD'], text=True).strip())
        self.assertEqual(lane.merge_base_branch(self.tree, 'main'), [])
        self.assertTrue((self.tree / 'lane.yml').exists())

    def test_the_base_branch_policy_classifies_only_the_committed_diff(self):
        (self.origin / 'scripts').mkdir()
        (self.origin / 'scripts/test-scope.py').write_text((SCRIPTS / 'test-scope.py').read_text())
        self.commit(self.origin, 'scripts/test-scope.py', (SCRIPTS / 'test-scope.py').read_text())
        subprocess.run(self.git + ['-C', str(self.tree), 'pull', '-q', 'origin', 'main'], check=True)
        (self.tree / 'docs').mkdir()
        self.commit(self.tree, 'docs/note.md', 'words\n')
        (self.tree / 'App').mkdir()
        (self.tree / 'App/Untracked.swift').write_text('// not committed, so not part of the PR\n')
        lane.fetch_base(self.tree, 'main')
        scope = lane.diff_scope(self.tree, 'main')
        self.assertEqual((scope['tier'], [f['path'] for f in scope['files']]), ('T0', ['docs/note.md']))
        # A PR that rewrites the policy to call everything docs is still judged by main's policy.
        self.commit(self.tree, 'scripts/test-scope.py', 'def classify(paths, diffs=None, root=None):\n'
                    '    return {"tier": "T0", "why": [], "files": []}\n')
        (self.tree / 'App/SpokenMarginsApp').mkdir(parents=True)
        self.commit(self.tree, 'App/SpokenMarginsApp/View.swift', 'struct V {}\n')
        self.assertEqual(lane.diff_scope(self.tree, 'main')['tier'], 'T2')

    def test_a_file_moved_out_of_the_owner_s_paths_still_counts_as_a_change_to_them(self):
        # #1402 audit: git lists only the new name of a rename, so a PR that moved .github/workflows/merge-audit.yml or
        # scripts/lane-runner.py elsewhere looked like a docs change and the runner merged it without the owner's tap.
        workflow = '.github/workflows/merge-audit.yml'
        for name in (workflow, 'scripts/lane-runner.py', '.github/wörkflows/audit.yml'):
            (self.origin / name).parent.mkdir(parents=True, exist_ok=True)
            self.commit(self.origin, name, 'name: audit\nrun: the same body, long enough for rename detection\n' * 4)
        subprocess.run(self.git + ['-C', str(self.tree), 'pull', '-q', 'origin', 'main'], check=True)
        (self.tree / 'docs/archive').mkdir(parents=True)
        for old, new in ((workflow, 'docs/archive/merge-audit.yml'),
                         ('scripts/lane-runner.py', 'docs/archive/lane-runner.py'),
                         ('.github/wörkflows/audit.yml', 'docs/archive/audit.yml')):
            subprocess.run(self.git + ['-C', str(self.tree), 'mv', old, new], check=True)
        subprocess.run(self.git + ['-C', str(self.tree), 'commit', '-q', '-m', 'move them'], check=True)
        lane.fetch_base(self.tree, 'main')
        paths, _ = lane.committed_changes(self.tree, 'main')
        self.assertEqual(paths, sorted(['.github/wörkflows/audit.yml', 'docs/archive/audit.yml',
                                        'docs/archive/lane-runner.py', 'docs/archive/merge-audit.yml',
                                        'scripts/lane-runner.py', workflow]))
        self.assertEqual(lane.owner_tap_paths({'files': [{'path': p} for p in paths]}),
                         sorted(['.github/wörkflows/audit.yml', 'scripts/lane-runner.py', workflow]))

    def test_a_diff_touching_the_app_model_suggests_its_whole_workflow_class(self):
        (self.origin / 'scripts').mkdir()
        self.commit(self.origin, 'scripts/test-scope.py', (SCRIPTS / 'test-scope.py').read_text())
        (self.origin / 'App/SpokenMarginsAppTests').mkdir(parents=True)
        self.commit(self.origin, 'App/SpokenMarginsAppTests/Gate1AppModelWorkflowTests.swift',
                    'import XCTest\nfinal class Gate1AppModelWorkflowTests: XCTestCase {}\n')
        subprocess.run(self.git + ['-C', str(self.tree), 'pull', '-q', 'origin', 'main'], check=True)
        (self.tree / 'App/SpokenMarginsApp/Sources/SpokenMarginsApp').mkdir(parents=True)
        self.commit(self.tree, 'App/SpokenMarginsApp/Sources/SpokenMarginsApp/Gate1AppModel.swift', 'final class M {}\n')
        lane.fetch_base(self.tree, 'main')
        with tempfile.TemporaryDirectory() as evidence:
            self.assertEqual(lane.t3_scope(self.tree, 'main', Path(evidence)), (['Gate1AppModelWorkflowTests'], []))
            self.assertTrue((Path(evidence) / 'scope.json').exists())

    def test_the_hot_file_ratchet_is_next_s_copy_and_absent_until_it_is_on_next(self):
        model = 'App/SpokenMarginsApp/Sources/SpokenMarginsApp/Gate1AppModel.swift'
        (self.origin / model).parent.mkdir(parents=True)
        self.commit(self.origin, model, 'one\ntwo\n')
        subprocess.run(self.git + ['-C', str(self.tree), 'pull', '-q', 'origin', 'main'], check=True)
        self.commit(self.tree, model, 'one\ntwo\nthree\n')
        lane.fetch_base(self.tree, 'main')
        self.assertEqual(lane.hot_file_violations(self.tree, 'main', set()), [])  # not on main yet
        (self.origin / 'scripts').mkdir(exist_ok=True)
        self.commit(self.origin, 'scripts/hot_file_ratchet.py', (SCRIPTS / 'hot_file_ratchet.py').read_text())
        lane.fetch_base(self.tree, 'main')
        self.assertEqual(lane.merge_base_branch(self.tree, 'main'), [])
        # The PR swaps in a ratchet that always passes; main's copy still judges it.
        self.commit(self.tree, 'scripts/hot_file_ratchet.py', 'def violations(*args):\n    return []\n')
        found = lane.hot_file_violations(self.tree, 'main', set())
        self.assertEqual(len(found), 1, found)
        self.assertIn('Gate1AppModel.swift would be 3 lines, above its ceiling of 2', found[0])
        self.assertEqual(lane.hot_file_violations(self.tree, 'main', {'hot-file-ok'}), [])

    def run_auto_on_the_real_ratchet(self, labels):
        """run_auto and run_automerge as they are, over a tree whose PR grows a hot file past main's ceiling.

        Every other run_auto test replaces run_automerge, so the `ratchet=` it is handed was never called."""
        model = 'App/SpokenMarginsApp/Sources/SpokenMarginsApp/Gate1AppModel.swift'
        (self.origin / model).parent.mkdir(parents=True)
        self.commit(self.origin, model, 'one\ntwo\n')
        (self.origin / 'scripts').mkdir()
        self.commit(self.origin, 'scripts/hot_file_ratchet.py', (SCRIPTS / 'hot_file_ratchet.py').read_text())
        subprocess.run(self.git + ['-C', str(self.tree), 'pull', '-q', 'origin', 'main'], check=True)
        self.commit(self.tree, model, 'one\ntwo\nthree\n')
        head = subprocess.check_output(['git', '-C', str(self.tree), 'rev-parse', 'HEAD'], text=True).strip()
        base_sha = lane.fetch_base(self.tree, 'main')
        docs_only = {'tier': 'T0', 'why': ['docs'], 'files': [{'path': 'docs/x.md', 'category': 'docs'}]}
        github, pushed = FakeGitHub(labels=('automerge',), head=head), []
        with tempfile.TemporaryDirectory() as folder, \
                mock.patch.object(lane, 'ROOT', self.tree), \
                mock.patch.object(lane, 'TESTED_RECORD', Path(folder) / 'tested.json'), \
                mock.patch.object(lane, 'build_merge_commit', return_value=('m' * 40, [])), \
                mock.patch.object(lane, 'push_merge', side_effect=lambda tree, sha, base: pushed.append(sha) or (True, '')), \
                mock.patch.object(lane, 'sweep_merge_audit'), \
                mock.patch.object(lane, 'host_build_folders', return_value='build folders: in the workspace (test)'), \
                mock.patch.object(lane, 'diff_scope', return_value=docs_only), \
                mock.patch.object(lane, 'inherited_check', return_value=lambda comments: []):
            result = lane.run_auto(github, {'title': 'T'}, 5, 'main', head, base_sha, Path(folder), [],
                                   labels=labels)
        return result, github, pushed

    def test_run_auto_refuses_to_merge_a_pr_that_grows_a_hot_file_past_its_ceiling(self):
        (verdict, where, ran, details), github, pushed = self.run_auto_on_the_real_ratchet(labels=['automerge'])
        self.assertEqual((verdict, where, ran), ('FAIL', 'no build', 'hot-file ratchet: failed'))
        self.assertIn('hot-file ratchet — Gate1AppModel.swift would be 3 lines, above its ceiling of 2', details[-1])
        self.assertEqual((pushed, github.posted), ([], []))  # nothing pushed, no merge check posted

    def test_run_auto_passes_the_pr_s_labels_to_the_ratchet_so_hot_file_ok_still_merges_it(self):
        (verdict, _, _, details), github, pushed = self.run_auto_on_the_real_ratchet(labels=['automerge', 'hot-file-ok'])
        self.assertEqual((verdict, pushed), ('PASS', ['m' * 40]), details)
        self.assertIn('merged into main as mmmmmmm', details[-1])

    def test_a_conflict_names_the_files_and_leaves_the_tree_clean(self):
        self.commit(self.tree, 'shared.txt', 'pr side\n')
        self.commit(self.origin, 'shared.txt', 'main side\n')
        lane.fetch_base(self.tree, 'main')
        self.assertEqual(lane.merge_base_branch(self.tree, 'main'), ['shared.txt'])
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


class GhCliTests(unittest.TestCase):
    """lane.GitHub and lane.Repo against a fake `gh` on PATH that records its argv and prints queued answers.

    Every other test replaces both classes (FakeGitHub, FakeRepo), so the REST paths, the `labels[]` field, the
    `%3A` label encoding and the `--paginate --jq` flags were never produced: a wrong field name or a label
    DELETE that missed would leave the PR on `lane:queued` forever with every test green."""

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

    def test_pull_comments_and_comment_use_the_pr_s_rest_paths(self):
        github = lane.GitHub('owner/repo', 5)
        self.answer('{"head": {"sha": "abc"}, "labels": []}',
                    json.dumps({'body': 'one', 'author_association': 'OWNER'}) + '\n\n'
                    + json.dumps({'body': 'two', 'author_association': 'OWNER'}) + '\n',
                    json.dumps({'html_url': 'https://example.test/c1'}))
        self.assertEqual(github.pull(), {'head': {'sha': 'abc'}, 'labels': []})
        self.assertEqual([c['body'] for c in github.comments()], ['one', 'two'])  # blank lines are skipped
        body = 'Lane report pr5-r1 — PASS\n```text\nran: it\n```'
        self.assertEqual(github.comment(body), 'https://example.test/c1')
        self.assertEqual(self.calls(), [
            ['api', 'repos/owner/repo/pulls/5'],
            ['api', '--paginate', '--jq', '.[] | @json', 'repos/owner/repo/issues/5/comments'],
            ['api', 'repos/owner/repo/issues/5/comments', '-f', f'body={body}']])

    def test_relabel_deletes_the_encoded_old_label_then_adds_the_new_one_as_a_labels_field(self):
        lane.GitHub('owner/repo', 5).relabel('lane:queued', 'lane:running')
        self.assertEqual(self.calls(), [
            ['api', '-X', 'DELETE', 'repos/owner/repo/issues/5/labels/lane%3Aqueued'],
            ['api', '-X', 'POST', 'repos/owner/repo/issues/5/labels', '-f', 'labels[]=lane:running']])

    def test_relabel_with_only_one_side_makes_only_that_call(self):
        github = lane.GitHub('owner/repo', 5)
        github.relabel(None, 'lane:done')
        github.relabel('lane:running', None)
        self.assertEqual(self.calls(), [
            ['api', '-X', 'POST', 'repos/owner/repo/issues/5/labels', '-f', 'labels[]=lane:done'],
            ['api', '-X', 'DELETE', 'repos/owner/repo/issues/5/labels/lane%3Arunning']])

    def test_removing_a_label_the_pr_no_longer_has_does_not_stop_the_new_label_being_added(self):
        self.answer(('', 1))  # DELETE answers 404 when the label is already gone
        lane.GitHub('owner/repo', 5).relabel('lane:queued', 'lane:running')
        self.assertEqual([call[1:3] for call in self.calls()], [['-X', 'DELETE'], ['-X', 'POST']])

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


class FakeRepo:
    """Repository-wide GitHub calls for the auto-revert: comments everywhere, #337, new issues."""

    def __init__(self, comments=(), ops=()):
        self.all, self.ops = list(comments), list(ops)
        self.posted, self.opened, self.since = [], [], []

    def comments_since(self, since):
        self.since.append(since)
        return iter(self.all)

    def issue_comments(self, number):
        assert number == lane.OPS_ISSUE
        return list(self.ops)

    def comment(self, number, body):
        self.posted.append((number, body))
        self.ops.append({'body': body})
        return f'https://github.com/o/r/issues/{number}#issuecomment-{len(self.posted)}'

    def title(self, number):
        return f'PR {number} title'

    def open_issue(self, title, body, labels):
        self.opened.append((title, body, labels))
        return 'https://github.com/o/r/issues/700'


class AutoRevertTests(unittest.TestCase):
    """Owner rule 2026-10-01: a lane change followed by two runner faults is reverted on main, once.
    Real git with a bare origin; GitHub is faked."""

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        root = Path(self.temporary.name)
        self.origin, self.tree, self.other = root / 'origin.git', root / 'tree', root / 'other'
        self.git = ['git', '-c', 'user.name=t', '-c', 'user.email=t@example.com', '-c', 'init.defaultBranch=main']
        subprocess.run(self.git + ['init', '-q', '--bare', str(self.origin)], check=True)
        subprocess.run(self.git + ['clone', '-q', str(self.origin), str(self.other)], check=True, capture_output=True)
        (self.other / 'scripts').mkdir()
        (self.other / 'scripts/test-scope.py').write_text((SCRIPTS / 'test-scope.py').read_text())
        self.write('scripts/lane-runner.py', 'v1\n')
        self.write('app.txt', 'app 1\n')
        self.start = self.commit('start', '2026-10-01T10:00:00Z')
        self.lane_merge = self.merge(7, 'Lane: faster boots', {'scripts/lane-runner.py': 'v2 broken\n'},
                                     '2026-10-01T12:00:00Z')
        self.later = self.merge(8, 'An app change', {'app.txt': 'app 2\n'}, '2026-10-01T12:10:00Z')
        self.push()
        subprocess.run(self.git + ['clone', '-q', '-b', 'main', str(self.origin), str(self.tree)], check=True)
        subprocess.run(self.git + ['-C', str(self.tree), 'checkout', '-q', '-b', 'pr'], check=True)
        (self.tree / 'pr.txt').write_text('the PR under test\n')
        subprocess.run(self.git + ['-C', str(self.tree), 'add', '.'], check=True)
        subprocess.run(self.git + ['-C', str(self.tree), 'commit', '-q', '-m', 'pr'], check=True)
        self.pr_head = self.rev(self.tree, 'HEAD')

    def write(self, name, text):
        (self.other / name).write_text(text)

    def run_git(self, args, when=None):
        env = dict(os.environ, GIT_AUTHOR_DATE=when, GIT_COMMITTER_DATE=when) if when else None
        subprocess.run(self.git + ['-C', str(self.other), *args], check=True, capture_output=True, env=env)

    def commit(self, message, when):
        self.run_git(['add', '.'])
        self.run_git(['commit', '-q', '-m', message], when)
        return self.rev(self.other, 'HEAD')

    def merge(self, pr, title, files, when):
        self.run_git(['checkout', '-q', '-b', f'pr{pr}'])
        for name, text in files.items():
            self.write(name, text)
        self.commit(title, when)
        self.run_git(['checkout', '-q', 'main'])
        self.run_git(['merge', '--no-ff', '-q', '-m', f'Merge pull request #{pr}: {title}', f'pr{pr}'], when)
        return self.rev(self.other, 'HEAD')

    def push(self):
        self.run_git(['push', '-q', 'origin', 'main'])

    def rev(self, where, ref):
        return subprocess.check_output(['git', '-C', str(where), 'rev-parse', ref], text=True).strip()

    def origin_file(self, name):
        return subprocess.check_output(['git', '-C', str(self.origin), 'show', f'main:{name}'], text=True)

    def report(self, verdict, details, at, tested=None, pr=9, n=1, base='main'):
        wanted = lane.identity('auto', 'f' * 40, tested or self.later, [])
        body = lane.report(f'pr{pr}-r{n}', verdict, 'f' * 40, tested or self.later, 'auto', 'host only', 60,
                           'nothing', details, 'none', '/e', 'owner', wanted, base_name=base)
        return self.posted(body, at, pr, n)

    def posted(self, body, at, pr=9, n=1):
        return {'body': body, 'created_at': at, 'user': {'login': 'github-actions[bot]'},
                'html_url': f'https://github.com/o/r/pull/{pr}#issuecomment-{n}'}

    def fault(self, at, n, tested=None, base='main'):
        return self.report('INCONCLUSIVE', ["The lane itself failed: FileNotFoundError('xcrun')."], at, tested, n=n,
                           base=base)

    def stopped(self, at, n, tested=None, base='main', mode='auto'):
        """The note cleanup() posts for a job that stopped, after main() recorded the base it tested."""
        with tempfile.TemporaryDirectory() as temporary, mock.patch.object(lane, 'sweep_runner_simulators'), \
                mock.patch.object(lane, 'TESTED_RECORD', Path(temporary) / 'tested.json'):
            if tested:
                lane.remember_tested(base, tested)
            github = FakeGitHub(labels=('automerge',))
            lane.cleanup(github, 'https://example.test/run', mode)
        return self.posted(github.posted[0], at, n=n)

    def revert(self, repo):
        with mock.patch('builtins.print'):
            return lane.auto_revert(self.tree, 'main', repo)

    def test_two_runner_faults_after_a_lane_merge_revert_it_once(self):
        repo = FakeRepo([self.fault('2026-10-01T13:00:00Z', 1), self.fault('2026-10-01T13:30:00Z', 2)])
        with mock.patch.object(lane, 'dispatch_hosted_integration', return_value='started') as dispatch:
            did = self.revert(repo)
        dispatch.assert_called_once_with('main')  # the pushed revert is a new tip too (#2127)
        self.assertTrue(did.startswith('reverted #7 as '), did)
        self.assertEqual(self.origin_file('scripts/lane-runner.py'), 'v1\n')  # the lane change is undone
        self.assertEqual(self.origin_file('app.txt'), 'app 2\n')  # the later ordinary merge stays
        revert = self.rev(self.origin, 'main')
        self.assertEqual(self.rev(self.origin, 'main^'), self.later)  # a plain push on top of main
        message = subprocess.check_output(['git', '-C', str(self.origin), 'log', '-1', '--format=%B', 'main'], text=True)
        self.assertIn(f'This reverts commit {self.lane_merge}', message)
        self.assertEqual(self.rev(self.tree, 'HEAD'), self.pr_head)  # the job goes on testing its PR
        (title, body, labels), = repo.opened
        self.assertEqual(labels, ['ready', 'regression'])
        self.assertIn('Re-land #7', title)
        (number, posted), = repo.posted
        self.assertEqual(number, 337)
        self.assertTrue(posted.startswith('Lane auto-revert: reverted #7'), posted)
        for needed in ('https://github.com/o/r/pull/9#issuecomment-1', 'https://github.com/o/r/pull/9#issuecomment-2',
                       f'`{revert[:7]}`', f'`{self.lane_merge[:7]}`', 'https://github.com/o/r/issues/700'):
            self.assertIn(needed, posted)
        self.assertEqual(repo.since, ['2026-10-01T12:00:00Z'])
        # Only once per lane change: the next job finds the revert and does nothing.
        again = self.revert(repo)
        self.assertIn('already reverted', again)
        self.assertEqual((len(repo.posted), len(repo.opened), self.rev(self.origin, 'main')), (1, 1, revert))

    def test_a_merge_conflict_a_t3_hold_or_a_fail_is_not_a_runner_fault(self):
        not_faults = [
            self.report('INCONCLUSIVE', ['The PR does not merge cleanly into main (abc1234): a.swift. Merge main '
                                         'into your branch and push; the automerge label runs it again.'],
                        '2026-10-01T13:30:00Z', n=2),
            self.report('INCONCLUSIVE', ['not merged: held for T3: this PR\'s newest /lane T3 request has no lane '
                                         'report yet.'], '2026-10-01T13:30:00Z', n=2),
            self.report('FAIL', ['host tests (--plan fast) — expected: verified. observed: exit 1.'],
                        '2026-10-01T13:30:00Z', n=2),
            # #909: the Mac's lid was closed, which no lane change causes; reverting one for it would be wrong.
            self.report('INCONCLUSIVE', ['host tests (--plan fast) — lane fault: no audio output: lid closed with no '
                                         'external display. Ask the owner to open the lid or connect an audio '
                                         'output, then re-run.'], '2026-10-01T13:30:00Z', n=2),
        ]
        for second in not_faults:
            with self.subTest(second=second['body'].splitlines()[3][:30]):
                repo = FakeRepo([self.fault('2026-10-01T13:00:00Z', 1), second])
                self.assertIn('fine so far', self.revert(repo))
                self.assertEqual((repo.posted, repo.opened, self.rev(self.origin, 'main')), ([], [], self.later))
        self.assertEqual(lane.lane_report_verdict(f'Lane: the runner stopped before reporting (run). If it is still '
                                                  f'needed, comment the request again.\n{lane.NOTE}'),
                         (True, 'the job stopped before it could report'))
        self.assertIsNone(lane.lane_report_verdict('Lane report journeys-abc1234 — INCONCLUSIVE\nrun by: Test Desk'))
        self.assertTrue(lane.lane_report_verdict(self.fault('2026-10-01T13:00:00Z', 1)['body'])[0])

    def test_a_fault_after_t3_release_counts_despite_the_historical_hold(self):
        released = self.report('INCONCLUSIVE', [
            'started by the T3 PASS; the automerge run on aaaaaaa was held for T3',
            "The lane itself failed: RuntimeError('runner timed out').",
        ], '2026-10-01T13:30:00Z', n=2)
        self.assertTrue(lane.lane_report_verdict(released['body'])[0])
        repo = FakeRepo([self.fault('2026-10-01T13:00:00Z', 1), released])
        self.assertTrue(self.revert(repo).startswith('reverted #7 as '))
        self.assertEqual(self.origin_file('scripts/lane-runner.py'), 'v1\n')

    def test_only_reports_on_prs_by_the_runner_after_the_change_landed_count(self):
        before = self.fault('2026-10-01T11:00:00Z', 1)  # posted before the merge
        older_next = self.fault('2026-10-01T13:00:00Z', 2, tested=self.start)  # tested a main without it
        desk = dict(self.fault('2026-10-01T13:05:00Z', 3), user={'login': 'uncomposed'})  # not the runner
        on_issue = dict(self.fault('2026-10-01T13:10:00Z', 4), html_url='https://github.com/o/r/issues/184#c-4')
        repo = FakeRepo([before, older_next, desk, on_issue, self.fault('2026-10-01T13:20:00Z', 5)])
        did = self.revert(repo)
        self.assertIn('fine so far', did)
        self.assertIn('issuecomment-5', did)
        self.assertEqual((repo.posted, self.rev(self.origin, 'main')), ([], self.later))

    def test_an_ordinary_merge_is_never_reverted(self):
        self.run_git(['reset', '-q', '--hard', self.start])
        self.merge(18, 'Another app change', {'app.txt': 'app 3\n'}, '2026-10-01T12:10:00Z')
        self.run_git(['push', '-q', '--force', 'origin', 'main'])
        repo = FakeRepo([self.fault('2026-10-01T13:00:00Z', 1), self.fault('2026-10-01T13:30:00Z', 2)])
        self.assertEqual(self.revert(repo), 'no lane change in recent merges')
        self.assertEqual(repo.posted, [])

    def github_revert_merge(self, pr, subject, when):
        """A revert PR the way GitHub's Revert button makes one: a `git revert -m 1` commit on a branch,
        merged with GitHub's own subject, which doesn't say "Revert"."""
        self.run_git(['checkout', '-q', '-b', f'pr{pr}'])
        self.run_git(['revert', '--no-edit', '-m', '1', self.lane_merge], when)
        self.run_git(['checkout', '-q', 'main'])
        self.run_git(['merge', '--no-ff', '-q', '-m', subject, f'pr{pr}'], when)
        self.run_git(['push', '-q', '--force', 'origin', 'main'])

    def test_a_revert_of_a_lane_change_is_never_reverted_itself(self):
        for pr, subject in ((9, 'Merge pull request #9 from o/revert-7-faster-boots'),
                            (10, 'Merge pull request #10: Undo the faster boots')):
            with self.subTest(subject=subject):
                self.run_git(['reset', '-q', '--hard', self.later])
                self.github_revert_merge(pr, subject, '2026-10-01T12:20:00Z')
                undone = self.rev(self.other, 'main')
                repo = FakeRepo([self.fault('2026-10-01T13:00:00Z', 1, tested=undone),
                                 self.fault('2026-10-01T13:30:00Z', 2, tested=undone)])
                self.assertIn('is itself a revert', self.revert(repo))
                self.assertEqual((repo.posted, self.rev(self.origin, 'main')), ([], undone))

    def test_a_lane_change_whose_title_says_revert_is_still_a_lane_change(self):
        # Codex audit of #640, P2: the subject is a title, not proof of a revert. A feature named "Revert
        # a lane change ..." is reverted like any lane change, and so is one whose branch reverted its own
        # earlier commit (a commit that was never on main).
        self.run_git(['checkout', '-q', '-b', 'pr11'])
        self.write('scripts/lane-runner.py', 'v3 first try\n')
        self.commit('first try', '2026-10-01T12:15:00Z')
        self.run_git(['revert', '--no-edit', 'HEAD'], '2026-10-01T12:16:00Z')
        self.write('scripts/lane-runner.py', 'v3 auto-revert, broken\n')
        self.commit('second try', '2026-10-01T12:17:00Z')
        self.run_git(['checkout', '-q', 'main'])
        self.run_git(['merge', '--no-ff', '-q', '-m', 'Merge pull request #11: Revert a lane change on main when '
                      'the two lane reports after it are runner faults', 'pr11'], '2026-10-01T12:20:00Z')
        self.push()
        feature = self.rev(self.other, 'main')
        repo = FakeRepo([self.fault('2026-10-01T13:00:00Z', 1, tested=feature),
                         self.fault('2026-10-01T13:30:00Z', 2, tested=feature)])
        did = self.revert(repo)
        self.assertTrue(did.startswith('reverted #11 as '), did)
        self.assertEqual(self.origin_file('scripts/lane-runner.py'), 'v2 broken\n')

    def test_only_reports_that_tested_next_count(self):
        # Codex audit of #640, P1: a lane-check/** branch made from main after the lane change contains it,
        # so its faults (testing some other lane change) passed the ancestry check.
        repo = FakeRepo([self.fault('2026-10-01T13:00:00Z', 1, base='lane-check/x'),
                         self.fault('2026-10-01T13:30:00Z', 2, base='lane-check/x'),
                         self.fault('2026-10-01T13:40:00Z', 3)])
        did = self.revert(repo)
        self.assertIn('fine so far', did)
        self.assertNotIn('issuecomment-1', did)
        self.assertIn('issuecomment-3', did)
        self.assertEqual((repo.posted, self.rev(self.origin, 'main')), ([], self.later))

    def test_a_stopped_job_note_that_names_no_tested_next_does_not_count(self):
        # Codex audit of #640, P1: a runner from before this fix posted no tested main, so its time decided.
        old_note = self.posted('Lane: the runner stopped before reporting (run). If it is still needed, comment '
                               f'the request again and add lane:queued.\n{lane.NOTE}', '2026-10-01T13:00:00Z')
        repo = FakeRepo([old_note, self.fault('2026-10-01T13:30:00Z', 2)])
        self.assertIn('fine so far', self.revert(repo))
        self.assertEqual((repo.posted, self.rev(self.origin, 'main')), ([], self.later))

    def test_a_stopped_job_counts_only_if_it_says_it_tested_a_next_with_the_change(self):
        # Codex audit of #640, P1: a stopped-job note named no tested main, so a job that was testing a main
        # from before the change, and stopped after it landed, counted against the change.
        for note in (self.stopped('2026-10-01T13:00:00Z', 1),  # stopped before it fetched main
                     self.stopped('2026-10-01T13:00:00Z', 1, tested=self.start),  # tested an older main
                     self.stopped('2026-10-01T13:00:00Z', 1, tested=self.later, base='lane-check/x')):
            with self.subTest(note=note['body'][:90]):
                repo = FakeRepo([note, self.fault('2026-10-01T13:30:00Z', 2)])
                self.assertIn('fine so far', self.revert(repo))
                self.assertEqual((repo.posted, self.rev(self.origin, 'main')), ([], self.later))
        for mode in ('auto', 'explicit'):
            with self.subTest(mode=mode):
                note = self.stopped('2026-10-01T13:00:00Z', 1, tested=self.later, mode=mode)
                self.assertIn(f'(tested merged with main at {self.later[:7]})', note['body'])
                self.assertEqual(lane.lane_report_verdict(note['body']), (True, 'the job stopped before it could report'))
        repo = FakeRepo([note, self.fault('2026-10-01T13:30:00Z', 2)])
        self.assertTrue(self.revert(repo).startswith('reverted #7 as '))

    def test_a_revert_that_does_not_apply_is_posted_on_337_once_and_nothing_is_pushed(self):
        self.write('scripts/lane-runner.py', 'v3, edited straight on main\n')
        moved = self.commit('a direct edit on main', '2026-10-01T12:30:00Z')
        self.push()
        repo = FakeRepo([self.fault('2026-10-01T13:00:00Z', 1, tested=moved),
                         self.fault('2026-10-01T13:30:00Z', 2, tested=moved)])
        did = self.revert(repo)
        self.assertIn('could not revert #7', did)
        (number, posted), = repo.posted
        self.assertTrue(posted.startswith('Lane auto-revert failed: #7'), posted)
        self.assertIn('scripts/lane-runner.py', posted)
        self.assertEqual((repo.opened, self.rev(self.origin, 'main')), ([], moved))
        self.assertEqual(self.rev(self.tree, 'HEAD'), self.pr_head)
        self.assertEqual(subprocess.check_output(['git', '-C', str(self.tree), 'status', '--porcelain'], text=True), '')
        self.assertIn('already handled', self.revert(repo))
        self.assertEqual(len(repo.posted), 1)

    def test_every_job_on_next_runs_the_check_first(self):
        flow = MainFlowTests()
        flow.run_main(FakeGitHub(comments=[comment('/lane T2')]))
        flow.auto_revert.assert_called_once()
        self.assertEqual(flow.auto_revert.call_args.args[1], 'main')
        flow.run_main(FakeGitHub(comments=[comment('/lane T2')]), HEAD, 'PASS', '--base', 'lane-check/x')
        flow.auto_revert.assert_not_called()  # a lane-check base is for testing lane changes, never reverted



class BaseScriptsFallbackTests(unittest.TestCase):
    """#904: main's lane-runner imported lane_slots from a branch that predates it and crashed before reporting."""

    def setUp(self):
        self.dir = Path(tempfile.mkdtemp(prefix='lane-fallback-'))
        self.addCleanup(subprocess.run, ['rm', '-rf', str(self.dir)])
        self.tree = self.dir / 'tree'
        git = ['git', '-C', str(self.tree), '-c', 'user.name=t', '-c', 'user.email=t@example.com']
        subprocess.run(['git', 'init', '-q', str(self.tree)], check=True)
        (self.tree / 'scripts').mkdir()
        (self.tree / 'scripts/old_helper.py').write_text("WHERE = 'base'\n")
        (self.tree / 'scripts/lane_slots.py').write_text("WHERE = 'base'\n")
        (self.tree / 'scripts/test-scope.py').write_text("WHERE = 'base'\n")
        (self.tree / 'scripts/tests').mkdir()
        (self.tree / 'scripts/tests/test_x.py').write_text('')
        subprocess.run(git + ['add', '-A'], check=True)
        subprocess.run(git + ['commit', '-qm', 'main'], check=True)
        subprocess.run(git + ['update-ref', 'refs/remotes/origin/main', 'HEAD'], check=True)
        # The PR branch: an old checkout with its own old_helper and no lane_slots.
        (self.tree / 'scripts/old_helper.py').write_text("WHERE = 'tree'\n")
        (self.tree / 'scripts/lane_slots.py').unlink()
        (self.tree / 'scripts/test-scope.py').unlink()
        self.path = list(sys.path)
        self.addCleanup(setattr, sys, 'path', self.path)

    def importable(self, *paths):
        code = 'import lane_slots, old_helper; print(lane_slots.WHERE, old_helper.WHERE)'
        return subprocess.run([sys.executable, '-I', '-c', f'import sys; sys.path[:0] = {list(map(str, paths))!r}; {code}'],
                              capture_output=True, text=True)

    def test_branch_without_lane_slots_cannot_import_it(self):
        self.assertIn("No module named 'lane_slots'", self.importable(self.tree / 'scripts').stderr)

    def test_missing_helpers_come_from_the_base_and_the_tree_keeps_its_own(self):
        into = lane.base_scripts_fallback(self.tree, 'main', into=self.dir / 'fallback')
        self.assertEqual(sorted(p.name for p in into.iterdir()), ['lane_slots.py'])
        self.assertEqual(sys.path[-1], str(into))
        result = self.importable(self.tree / 'scripts', into)
        self.assertEqual(result.stdout.split(), ['base', 'tree'], result.stderr)

    def test_nothing_missing_adds_nothing(self):
        (self.tree / 'scripts/lane_slots.py').write_text("WHERE = 'tree'\n")
        self.assertIsNone(lane.base_scripts_fallback(self.tree, 'main', into=self.dir / 'fallback'))
        self.assertEqual(sys.path, self.path)

    def test_unknown_base_raises_for_main_to_log(self):
        with self.assertRaises(RuntimeError):
            lane.base_scripts_fallback(self.tree, 'no-such-base', into=self.dir / 'fallback')

    def test_main_sets_it_up_before_any_lane_work(self):
        class Stop(Exception):
            pass
        root = lane.ROOT
        self.addCleanup(setattr, lane, 'ROOT', root)
        with mock.patch.dict(os.environ, {'GH_REPO': 'o/r'}), \
                mock.patch.object(lane, 'GitHub', side_effect=Stop), \
                mock.patch.object(lane, 'base_scripts_fallback', return_value=None) as fallback:
            with self.assertRaises(Stop):
                lane.main(['--pr', '1', '--event-head', HEAD, '--run-id', '1', '--tree', str(self.tree)])
        fallback.assert_called_once_with(self.tree.resolve(), 'main')

def stalled_step(recovered=True, stalls=1, errors=(), tests=3):
    """An xcode-tests step as verify-tests.py records it after a startup stall."""
    step = {'name': 'xcode-tests', 'exit_code': 0, 'errors': list(errors), 'startup_attempts': stalls + 1,
            'startup_stalls': [{'attempt': n, 'after_seconds': 90.2, 'last_log_line': 'Writing result bundle at path:'}
                               for n in range(1, stalls + 1)],
            'tests': {f'T/A/test{n}': {'status': 'passed'} for n in range(tests)}}
    if recovered:
        step['startup_recovered'] = True
    return step


class RecoveredStallTests(unittest.TestCase):
    """Owner's call 2026-10-11: one startup stall recovered on the first retry, every test then passing, is a PASS."""

    def plan(self, step, status='verified'):
        manifest = {'status': status, 'steps': [{'name': 'build-for-testing', 'exit_code': 0, 'errors': []}, step]}
        summaries, statuses, _, details = lane.run_plans({'app': ['T/A']}, lambda *_: manifest, Path('/e'))
        return lane.t3_verdict(summaries, statuses), details

    def test_one_stall_recovered_on_the_first_retry_is_a_pass_the_report_says_so(self):
        verdict, details = self.plan(stalled_step())
        self.assertEqual(verdict, 'PASS')
        self.assertEqual(len(details), 1)
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

    def test_each_recovered_stall_is_logged_on_705_with_its_evidence(self):
        with tempfile.TemporaryDirectory() as folder:
            for plan, step in (('app', stalled_step()), ('adapters', stalled_step(tests=5)),
                               ('quiet', {'name': 'xcode-tests', 'exit_code': 0, 'errors': [], 'tests': {}})):
                (Path(folder) / f'verify-{plan}').mkdir()
                (Path(folder) / f'verify-{plan}' / 'manifest.json').write_text(json.dumps({'steps': [step]}))
            posted = []
            count = lane.log_recovered_stalls(Path(folder), 5, HEAD, 'https://example.test/report', posted.append)
        self.assertEqual(count, 2)
        self.assertEqual(len(posted), 2)
        self.assertIn('`adapters` plan', posted[0])
        self.assertIn('retry then passed 5 test(s)', posted[0])
        self.assertIn('`app` plan', posted[1])
        for body in posted:
            self.assertIn('PR #5 at `aaaaaaa` (https://example.test/report)', body)
            self.assertIn('xcode-tests-stall-1/', body)
            self.assertIn('90.2s after launch', body)

    def test_a_failed_log_comment_never_fails_the_job(self):
        with tempfile.TemporaryDirectory() as folder:
            (Path(folder) / 'verify-app').mkdir()
            (Path(folder) / 'verify-app' / 'manifest.json').write_text(json.dumps({'steps': [stalled_step()]}))

            def refuse(body):
                raise RuntimeError('GitHub API unavailable')

            with mock.patch('builtins.print'):
                self.assertEqual(lane.log_recovered_stalls(Path(folder), 5, HEAD, 'u', refuse), 0)

    def test_a_t3_run_with_a_recovered_stall_logs_it_on_705_after_reporting(self):
        run = MainFlowTests()
        ops = FakeRepo()
        run.ops = ops

        def t3(tests, request_id, evidence, classes=()):
            (evidence / 'verify-app').mkdir(parents=True)
            (evidence / 'verify-app' / 'manifest.json').write_text(json.dumps({'steps': [stalled_step()]}))
            return 'PASS', 'sim', 'ran', ['app: recovered after 1 startup stall'], 'none', ''

        github = FakeGitHub(comments=[comment('/lane T3\ntests: SupertonicSpeechTests')])
        with mock.patch.object(lane, 't3_scope', return_value=([], [])), \
                mock.patch.object(lane, 'run_t3', side_effect=t3), \
                mock.patch.object(lane, 'clean_tree'):
            run.run_main(github)
        self.assertTrue(any(body.startswith('Lane report') and '— PASS' in body for body in github.posted))
        logged = [(number, body) for number, body in ops.posted if number == lane.STALL_ISSUE]
        self.assertEqual(len(logged), 1)
        self.assertIn('PR #5', logged[0][1])
        self.assertIn('(https://example.test/', logged[0][1])  # links the report it was found in



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
                mock.patch.object(lane, 'run_plans', return_value=([lane.summarize_manifest({'steps': []})],
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

    def test_the_boot_stalls_are_posted_on_705_with_the_report_and_verdict(self):
        for outcome, verdict, expected in (
                ('recovered on a fresh device (`U2`, ready after 40s)', 'PASS',
                 'Boot stall recovered on a fresh device; the run then ended PASS'),
                ('recovered on a fresh device (`U2`, ready after 40s)', 'FAIL',
                 'Boot stall recovered on a fresh device; the run then ended FAIL'),
                ('not recovered (two in a row), so the run stays INCONCLUSIVE', 'INCONCLUSIVE',
                 'Boot stall, not recovered (two in a row)')):
            with self.subTest(verdict=verdict), tempfile.TemporaryDirectory() as folder:
                (Path(folder) / lane.BOOT_STALLS).write_text(json.dumps({'label': 'runner boot U1', 'outcome': outcome,
                    'stalls': [{'udid': 'U1', 'error': 'SpringBoard restarted', 'pressure': 'normal'}]}))
                posted = []
                self.assertEqual(lane.log_recovered_stalls(Path(folder), 5, HEAD, 'https://example.test/r',
                                                           posted.append, verdict), 1)
                self.assertTrue(posted[0].startswith(expected), posted[0])
                self.assertIn('T3 run for PR #5 at `aaaaaaa` (https://example.test/r)', posted[0])
                self.assertIn('clone `U1` (memory pressure normal): SpringBoard restarted', posted[0])

    def test_no_boot_stall_file_posts_nothing(self):
        with tempfile.TemporaryDirectory() as folder:
            self.assertEqual(lane.log_recovered_stalls(Path(folder), 5, HEAD, 'u', self.fail, 'PASS'), 0)



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

    def test_each_rerun_is_logged_on_the_stall_issue(self):
        with tempfile.TemporaryDirectory() as folder:
            (Path(folder) / lane.FRESH_RERUNS).write_text(json.dumps([{
                'plan': 'app', 'stalled': 'U1', 'fresh': 'U2', 'status': 'verified', 'passed': 195,
                'first': '/e/verify-app', 'output': '/e/verify-app-fresh',
                'stalls': [{'attempt': 1, 'after_seconds': 90.1, 'diagnosis': 'no host app process'}]}]))
            # A recovered stall inside the rerun is not posted as "counted as a PASS": the rerun is evidence only.
            fresh = Path(folder) / 'verify-app-fresh'
            fresh.mkdir()
            recovered = passing_manifest()
            recovered['steps'][0].update(startup_recovered=True, startup_stalls=[{'attempt': 1}])
            (fresh / 'manifest.json').write_text(json.dumps(recovered))
            posted = []
            self.assertEqual(lane.log_recovered_stalls(Path(folder), 5, HEAD, 'https://example.test/r', posted.append), 1)
        self.assertIn('the `app` plan of the T3 run for PR #5 at `aaaaaaa` (https://example.test/r)', posted[0])
        self.assertIn('Launch 1 on clone `U1`: no test output 90.1s after launch; no host app process', posted[0])
        self.assertIn('fresh-clone rerun: passed 195 tests; verdict stays INCONCLUSIVE (two stalls, owner '
                      '2026-10-11/2026-10-23) (clone `U2`)', posted[0])

class TrustedCommentTests(unittest.TestCase):
    """Once the repository is public, only the owner, collaborators and the project's bot steer the lane (#1719)."""

    @staticmethod
    def comment(body, login, association):
        return {'body': body, 'user': {'login': login}, 'author_association': association,
                'html_url': f'https://example.test/{login}'}

    def test_who_is_trusted(self):
        for login, association, trusted in (
                ('uncomposed', 'OWNER', True),
                ('a-member', 'MEMBER', True),
                ('a-collaborator', 'COLLABORATOR', True),
                ('github-actions[bot]', 'NONE', True),
                ('stranger', 'NONE', False),
                ('past-contributor', 'CONTRIBUTOR', False),
                ('first-timer', 'FIRST_TIME_CONTRIBUTOR', False),
                ('first-timer', 'FIRST_TIMER', False),
                ('mannequin', 'MANNEQUIN', False),
                ('chatgpt-codex-connector[bot]', 'NONE', False),
                ('github-actions', 'NONE', False),  # not the bot: the [bot] suffix is reserved for apps
                ('owner-lookalike', 'owner', False),  # GitHub sends it upper case; anything else is not trusted
                ('no-association', None, False)):
            with self.subTest(login=login, association=association):
                self.assertEqual(lane.trusted_comment(self.comment('/lane T3', login, association)), trusted)
        self.assertFalse(lane.trusted_comment({'body': '/lane T3'}))  # no author at all

    def comments_from(self, *comments):
        github = lane.GitHub('o/r', 5)
        lines = '\n'.join(json.dumps(c) for c in comments)
        with mock.patch.object(github, 'api', return_value=lines), mock.patch('builtins.print') as printed:
            return github.comments(), printed

    def test_a_strangers_lane_request_is_never_run(self):
        kept, printed = self.comments_from(
            self.comment('/lane T3\ntests: SpeechTests', 'uncomposed', 'OWNER'),
            self.comment('/lane T2\ncommit: deadbeef', 'stranger', 'NONE'))
        request, _ = lane.pending_requests(kept)
        self.assertEqual((request['tier'], request['author']), ('T3', 'uncomposed'))
        self.assertIn('ignored 1 comment(s)', printed.call_args.args[0])
        self.assertIn('stranger', printed.call_args.args[0])

    def test_a_contributors_request_alone_leaves_nothing_to_run(self):
        kept, _ = self.comments_from(self.comment('/lane T3\ntests: SpeechTests', 'drive-by', 'CONTRIBUTOR'))
        self.assertEqual(lane.pending_requests(kept), (None, False))

    def test_a_fake_report_cannot_answer_a_request_or_lift_the_t3_hold(self):
        identity = json.dumps(lane.identity('T3', HEAD, 'b' * 40, []))
        fake = f'Lane report r1 — PASS\n<!-- lane-request: {identity} -->'
        kept, _ = self.comments_from(self.comment('/lane T3\ncommit: aaaaaaa', 'uncomposed', 'OWNER'),
                                     self.comment(fake, 'stranger', 'NONE'))
        request, _ = lane.pending_requests(kept)
        self.assertIsNotNone(request)  # still waiting for the real runner
        self.assertIsNotNone(lane.t3_gate(kept))  # still held: no trusted T3 report

    def test_the_project_bots_reports_still_count(self):
        identity = json.dumps(lane.identity('T3', HEAD, 'b' * 40, []))
        report = f'Lane report r1 — PASS\n<!-- lane-request: {identity} -->'
        kept, printed = self.comments_from(self.comment('/lane T3\ncommit: aaaaaaa', 'uncomposed', 'OWNER'),
                                           self.comment(report, 'github-actions[bot]', 'NONE'))
        self.assertEqual(len(kept), 2)
        self.assertEqual(lane.pending_requests(kept), (None, False))
        printed.assert_not_called()


if __name__ == '__main__':
    unittest.main()


class PruneLaneFolderTests(unittest.TestCase):
    """prune_lane_folder runs ops/disk/sm_lane_prune.py; the rules have their own tests (ops/disk)."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.state = Path(self.tmp.name) / 'state'
        self.evidence = Path(self.tmp.name) / 'checkout/artifacts/lane'
        self.old = self.evidence / 'pr999999-r1'
        self.new = self.evidence / 'pr999998-r2'
        for folder, days in ((self.old, 40), (self.new, 1)):
            folder.mkdir(parents=True)
            (folder / 'report.md').write_text('x')
            stamp = time.time() - days * 86400
            os.utime(folder / 'report.md', (stamp, stamp))
            os.utime(folder, (stamp, stamp))

    def prune(self, tools=None):
        with mock.patch.dict(os.environ, {'SM_LANE_STATE_DIR': str(self.state)}), \
                mock.patch.object(lane, 'tools_source', return_value=tools or SCRIPTS.parent):
            return lane.prune_lane_folder(self.evidence)

    def test_old_evidence_in_the_runners_evidence_folder_is_removed_and_new_stays(self):
        line = self.prune()
        self.assertTrue(line.startswith('lane folder prune:'), line)
        self.assertFalse(self.old.exists())
        self.assertTrue(self.new.exists())

    def test_a_tools_checkout_without_the_script_or_with_a_broken_one_never_fails_the_job(self):
        empty = Path(self.tmp.name) / 'empty'
        empty.mkdir()
        self.assertIn('not installed', self.prune(empty))
        broken = Path(self.tmp.name) / 'broken'
        (broken / 'ops/disk').mkdir(parents=True)
        (broken / 'ops/disk/sm_lane_prune.py').write_text('raise SystemExit(3)\n')
        self.assertIn('failed', self.prune(broken))
        self.assertTrue(self.old.exists())
