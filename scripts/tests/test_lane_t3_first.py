"""The automerge job leaves a PR with a pending T3 request for its head to the T3 job.

In the 48 hours to 2026-10-01, 24 automerge runs did their full host tests and both builds and then
ended "held for T3" (188 runner-minutes), 20 of them because the PR's T3 request had no report yet.
The lane job that reports the T3 PASS runs the same checks on the merge commit again before it merges
(#421), so those runs could never merge anything.
"""
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))
import test_lane_runner  # noqa: E402
from test_lane_runner import FakeGitHub, HEAD, MERGE, NEWER, comment, lane, runner_report  # noqa: E402

T3_FOR_HEAD = comment(f'/lane T3\ncommit: {HEAD[:7]}\ntests: SupertonicSpeechTests', url='https://example.test/t3-request')


class T3RequestForHeadTests(unittest.TestCase):
    def test_a_queued_or_running_t3_request_naming_the_head_is_found(self):
        for label in ('lane:queued', 'lane:running'):
            with self.subTest(label=label):
                self.assertEqual(lane.t3_request_for_head([T3_FOR_HEAD], {'automerge', label}, HEAD),
                                 'https://example.test/t3-request')

    def test_a_full_sha_or_a_note_after_it_still_names_the_head(self):
        for line in (f'commit: {HEAD}', f'commit: {HEAD[:9]} (the fix)', f'commit: {HEAD[:7].upper()}'):
            with self.subTest(line=line):
                request = comment(f'/lane T3\n{line}\ntests: A')
                self.assertIsNotNone(lane.t3_request_for_head([request], {'lane:queued'}, HEAD))

    def test_a_request_for_an_older_head_or_naming_no_commit_does_not_count(self):
        # The head moved after the request: the T3 may already be running on the old head, and nothing
        # would test the new one if the automerge run skipped it.
        for body in (f'/lane T3\ncommit: {NEWER[:7]}\ntests: A', '/lane T3\ntests: A', '/lane T3\ncommit: abc\ntests: A'):
            with self.subTest(body=body):
                self.assertIsNone(lane.t3_request_for_head([comment(body)], {'lane:queued'}, HEAD))

    def test_without_lane_queued_or_lane_running_no_lane_job_will_answer_it(self):
        self.assertIsNone(lane.t3_request_for_head([T3_FOR_HEAD], {'automerge'}, HEAD))
        self.assertIsNone(lane.t3_request_for_head([T3_FOR_HEAD], {'automerge', 'lane:done'}, HEAD))

    def test_an_answered_request_or_a_newer_t2_request_does_not_count(self):
        answered = [T3_FOR_HEAD, runner_report('FAIL', lane.identity('T3', HEAD, MERGE, ['A']))]
        self.assertIsNone(lane.t3_request_for_head(answered, {'lane:queued'}, HEAD))
        t2_after = [T3_FOR_HEAD, comment(f'/lane T2\ncommit: {HEAD[:7]}')]
        self.assertIsNone(lane.t3_request_for_head(t2_after, {'lane:queued'}, HEAD))


class AutomergeJobLeavesItToTheT3Tests(unittest.TestCase):
    run_main = test_lane_runner.MainFlowTests.run_main
    conflicts, role, attempt = [], '', '1'

    def run_auto_job(self, github, role=''):
        self.role = role
        with mock.patch.object(lane, 'run_auto', return_value=('PASS', 'x', 'host tests; builds', [])) as auto, \
                mock.patch.object(lane, 'wait_for_room_to_build', return_value=None) as wait:
            self.run_main(github, HEAD, 'PASS', '--mode', 'auto')
        return auto, wait

    def test_a_pending_t3_request_for_the_head_skips_the_host_tests_and_builds(self):
        github = FakeGitHub(labels=('automerge', 'lane:queued'), comments=[T3_FOR_HEAD])
        auto, wait = self.run_auto_job(github, role='build')
        auto.assert_not_called()
        wait.assert_not_called()  # nothing to build, so nothing to wait for
        report = github.posted[0]
        self.assertTrue(report.startswith('Lane report pr5-r42 — INCONCLUSIVE'), report)
        self.assertIn('ran: nothing', report)
        self.assertIn('https://example.test/t3-request', report)
        # The T3 job releases the run only if it finds it held (#421): the report must read as held.
        self.assertTrue(lane.held_for_t3(github.comments(), HEAD))
        self.assertEqual(github.label_changes, [('lane:done', 'lane:done')])  # lane:queued stays for the lane job

    def test_the_t3_pass_then_runs_the_checks_and_merges_in_the_lane_job(self):
        github = FakeGitHub(labels=('automerge', 'lane:queued'), comments=[T3_FOR_HEAD])
        self.run_auto_job(github)
        github._comments.append(runner_report('PASS', lane.identity('T3', HEAD, MERGE, ['SupertonicSpeechTests'])))
        with mock.patch.object(lane, 'run_auto', return_value=('PASS', 'x', 'host tests; builds',
                                                               ['merged into next as abc1234'])) as auto, \
                mock.patch.object(lane, 'fetch_base', return_value=MERGE), mock.patch.object(lane, 'clean_tree'), \
                mock.patch('builtins.print'), tempfile.TemporaryDirectory() as evidence:
            released = lane.merge_after_t3(github, 5, 'next', HEAD, 'pr5-r43-auto', Path(evidence), MERGE,
                                           'started by the T3 PASS')
        auto.assert_called_once()
        self.assertIn('merged into next as abc1234', released)

    def test_a_t3_request_for_an_older_head_still_gets_the_automerge_checks(self):
        older = comment(f'/lane T3\ncommit: {NEWER[:7]}\ntests: A')
        github = FakeGitHub(labels=('automerge', 'lane:queued'), comments=[older])
        auto, _ = self.run_auto_job(github)
        auto.assert_called_once()

    def test_a_pr_without_a_t3_request_runs_as_before(self):
        github = FakeGitHub(labels=('automerge',))
        auto, _ = self.run_auto_job(github)
        auto.assert_called_once()


if __name__ == '__main__':
    unittest.main()
