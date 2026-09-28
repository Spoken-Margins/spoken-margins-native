import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
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
NEWER = 'b' * 40


def comment(body, login='uncomposed', url='https://example.test/c'):
    return {'body': body, 'user': {'login': login}, 'html_url': url}


class FakeGitHub:
    def __init__(self, labels=('lane:queued',), head=HEAD, comments=()):
        self.labels, self.head, self._comments = set(labels), head, list(comments)
        self.posted, self.label_changes = [], []

    def pull(self):
        return {'head': {'sha': self.head}, 'labels': [{'name': n} for n in sorted(self.labels)]}

    def comments(self):
        return list(self._comments)

    def comment(self, body):
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

    def test_ordinary_comments_and_lane_reports_are_not_requests(self):
        self.assertIsNone(lane.parse_request('Looks good. We could /lane T2 later.'))
        comments = [comment('/lane T2\ncommit: 1111111'),
                    comment('Lane report pr1-r1 — PASS\ncommit 1111111 …\n<!-- lane-request: {} -->'),
                    comment('Thanks!')]
        self.assertEqual(lane.latest_request(comments)['commit'], '1111111')

    def test_the_newest_request_wins(self):
        comments = [comment('/lane T2\ncommit: 1111111'), comment('/lane T3\ncommit: 2222222\ntests: X')]
        self.assertEqual(lane.latest_request(comments)['tier'], 'T3')

    def test_identical_requests_are_recognised_by_the_report_marker(self):
        wanted = lane.identity('T3', HEAD, ['B', 'A'])
        body = lane.report('pr1-r1', 'PASS', HEAD, NEWER, 'T3', 'x', 1, 'A', [], 'none', '/e', 'owner', wanted)
        self.assertEqual(lane.earlier_report([comment(body, url='u1')], lane.identity('T3', HEAD, ['A', 'B'])), 'u1')
        self.assertIsNone(lane.earlier_report([comment(body)], lane.identity('T3', NEWER, ['A', 'B'])))
        self.assertIsNone(lane.earlier_report([comment(body)], lane.identity('T2', HEAD, [])))


class ReportTests(unittest.TestCase):
    def test_report_matches_the_contract_header_and_lines(self):
        body = lane.report('pr7-r9', 'FAIL', HEAD, NEWER, 'T2', 'no simulator (compile only)', 75,
                           'simulator build (pass), device build (fail)', ['device build — expected: …'],
                           'none', '/ev/pr7-r9', 'journeys (T4)', lane.identity('T2', HEAD, []))
        lines = body.splitlines()
        self.assertEqual(lines[0], 'Lane report pr7-r9 — FAIL')
        self.assertEqual(lines[1], f'commit {HEAD[:7]} (tested merged into next as {NEWER[:7]}) · tier T2 · '
                                   'no simulator (compile only) · 1m15s')
        self.assertTrue(lines[2].startswith('ran: '))
        self.assertIn('crashes: none', lines)
        self.assertIn('not verified: journeys (T4)', lines)

    def test_t2_passes_only_when_both_builds_pass_and_names_the_first_errors(self):
        with tempfile.TemporaryDirectory() as temporary:
            evidence = Path(temporary)

            def fake(command, stdout, **_):
                if 'generic/platform=iOS' in command:
                    stdout.write('Foo.swift:3:1: error: cannot find Bar in scope\n')
                    return subprocess.CompletedProcess(command, 65)
                return subprocess.CompletedProcess(command, 0)

            verdict, ran, details = lane.run_t2(evidence, runner=fake)
            self.assertEqual(verdict, 'FAIL')
            self.assertEqual(ran, 'simulator build (pass), device build (fail)')
            self.assertTrue(any('cannot find Bar' in line for line in details))
            verdict, _, _ = lane.run_t2(evidence, runner=lambda command, **_: subprocess.CompletedProcess(command, 0))
            self.assertEqual(verdict, 'PASS')


class T3Tests(unittest.TestCase):
    PLANS = {'app': {'SpokenMarginsAppTests/A/test1', 'SpokenMarginsAppTests/A/test2'},
             'adapters': {'SpokenMarginsAppTests/Audio/test1'}}

    def test_tests_are_grouped_by_plan_and_unknown_ones_are_reported(self):
        grouped, unknown = lane.plan_for_tests(['A', 'SpokenMarginsAppTests/Audio/test1', 'Missing', 'A/test9'],
                                               self.PLANS)
        self.assertEqual(grouped, {'app': ['SpokenMarginsAppTests/A'], 'adapters': ['SpokenMarginsAppTests/Audio/test1']})
        self.assertEqual(unknown, ['Missing', 'A/test9'])

    def test_verdicts_separate_failures_from_lane_trouble(self):
        manifest = {'status': 'failed_or_incomplete', 'steps': [
            {'name': 'xcode-tests', 'tests': {'A/test1': {'status': 'passed'}, 'A/test2': {'status': 'failed'}}}]}
        summary = lane.summarize_manifest(manifest)
        self.assertEqual((summary['passed'], summary['failed']), (1, ['A/test2']))
        self.assertEqual(lane.t3_verdict([summary], ['failed_or_incomplete']), 'FAIL')
        flood = lane.summarize_manifest({'steps': [{'name': 'xcode-tests', 'simulator_crash_report': 'x.ips',
                                                    'simulator_crash_reports': ['/r/x.ips'], 'interrupted': True}]})
        self.assertTrue(flood['flood'])
        self.assertEqual(lane.t3_verdict([flood], ['failed_or_incomplete']), 'INCONCLUSIVE')
        broken = lane.summarize_manifest({'steps': [{'name': 'build-for-testing', 'errors': ['Process exit 65']}]})
        self.assertEqual(lane.t3_verdict([broken], ['failed_or_incomplete']), 'FAIL')
        self.assertEqual(lane.t3_verdict([lane.summarize_manifest({'steps': []})], ['verified']), 'PASS')

    def test_a_t3_request_without_tests_or_with_unknown_tests_does_not_boot_anything(self):
        with mock.patch.object(lane, 'newest_runtime', side_effect=AssertionError('no simulator should be made')):
            self.assertEqual(lane.run_t3([], 'r', Path('/tmp'))[0], 'INCONCLUSIVE')
            self.assertEqual(lane.run_t3(['NoSuchTestClassAnywhere'], 'r', Path('/tmp'))[0], 'FAIL')


class MainFlowTests(unittest.TestCase):
    def run_main(self, github, event_head=HEAD):
        with tempfile.TemporaryDirectory() as temporary, \
                mock.patch.object(lane, 'GitHub', return_value=github), \
                mock.patch.dict('os.environ', {'GH_REPO': 'o/r', 'SM_LANE_EVIDENCE_DIR': temporary}), \
                mock.patch.object(lane, 'run_t2', return_value=('PASS', 'simulator build (pass), device build (pass)', [])), \
                mock.patch.object(lane, 'link_tools'), mock.patch('builtins.print'):
            return lane.main(['--pr', '5', '--event-head', event_head, '--merge-sha', NEWER, '--run-id', '42'])

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

    def test_identical_requests_run_once(self):
        github = FakeGitHub(comments=[comment('/lane T2')])
        self.run_main(github)
        github.labels.add('lane:queued')
        github._comments.append(comment('/lane T2'))
        self.run_main(github)
        self.assertEqual(len(github.posted), 2)
        self.assertTrue(github.posted[1].startswith('Lane: identical T2 request'))

    def test_test_desk_tiers_and_unlabelled_prs_are_left_alone(self):
        for github in (FakeGitHub(comments=[comment('/lane T4\nrun: J1')]),
                       FakeGitHub(labels=(), comments=[comment('/lane T2')])):
            self.run_main(github)
            self.assertEqual((github.posted, github.label_changes), ([], []))


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
