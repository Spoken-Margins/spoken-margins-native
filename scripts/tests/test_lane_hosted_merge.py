"""#2459: the hosted automerge job merges on the hosted fast checks' PASS and runs no host tests.

What these tests guard: a hosted PASS on the exact head skips the pre-merge host tests; a different head, a missing or
unfinished run, or a merge tree it didn't test sends the job to the Mac fallback with no report; a failed hosted check
fails the PR. The checks themselves are read with the real hosted_fast_records.
"""
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))
import test_lane_hosted_fast as fast_tests
import test_lane_runner as runner_tests
import test_test_scope as scope_tests

FakeGitHub, HEAD, MERGE, lane = (runner_tests.FakeGitHub, runner_tests.HEAD, runner_tests.MERGE, runner_tests.lane)
scope = scope_tests.scope
APP_DIFF = {'tier': 'T2', 'why': ['App/x.swift'], 'files': [{'path': 'App/x.swift', 'category': 'app'}],
            'lane_paths': []}


class SkipRuleTests(unittest.TestCase):
    """hosted_fast_checks through the real records reader, then run_auto's hosted branch."""

    def run_auto(self, checks, merge_tree='e' * 40):
        github = FakeGitHub(labels=('automerge',))
        real = lane.hosted_fast_checks
        with tempfile.TemporaryDirectory() as temporary, \
                mock.patch.object(lane, 'TESTED_RECORD', Path(temporary) / 'tested.json'), \
                mock.patch.object(lane, 'build_merge_commit', return_value=(MERGE, [])), \
                mock.patch.object(lane, 'base_policy', return_value=scope), \
                mock.patch.object(lane, 'diff_scope', return_value=APP_DIFF), \
                mock.patch.object(lane, 'inherited_check', return_value=lambda comments: []), \
                mock.patch.object(lane, 'hot_file_violations', return_value=[]), \
                mock.patch.object(lane, 'sweep_merge_audit'), \
                mock.patch.object(lane, 'checks_stand', return_value=True), \
                mock.patch.object(lane, 'untested_moves', return_value=([], 'unchanged')), \
                mock.patch.object(lane, 'merged_tree', return_value=merge_tree), \
                mock.patch.object(lane, 'hosted_fast_checks', lambda gh, tree, base, head, base_sha, **kw:
                                  real(gh, tree, base, head, base_sha, records=lambda g, h, names:
                                       lane.hosted_fast_records(checks, h, names), wait=0)), \
                mock.patch.dict(lane.os.environ, {'LANE_HOSTED_FAST': 'on'}), \
                mock.patch.object(lane, 'run_fast') as fast, mock.patch.object(lane, 'run_mac_rest') as rest, \
                mock.patch.object(lane, 'run_ops') as ops, \
                mock.patch.object(lane, 'push_merge', return_value=(True, '')) as push:
            result = lane.run_auto(github, {}, 5, 'next', HEAD, MERGE, Path(temporary), [], hosted=True)
        self.assertFalse(fast.called or rest.called or ops.called, 'the hosted job never runs host tests itself')
        return result, github, push

    def test_a_hosted_pass_on_the_same_head_skips_the_host_tests_and_merges(self):
        result, github, push = self.run_auto(fast_tests.passing(HEAD))
        self.assertEqual(result[0], 'PASS')
        self.assertTrue(any(line.startswith('merged into next') for line in result[3]))
        self.assertIn('no host tests re-run', ' '.join(result[3]))
        push.assert_called_once()

    def test_another_head_or_no_hosted_run_hands_the_job_to_the_mac_with_no_report(self):
        for name, checks in (('another head', fast_tests.passing('b' * 40)),
                             ('no hosted run', fast_tests.FakeChecks({}, {}))):
            with self.subTest(name):
                result, github, push = self.run_auto(checks)
                self.assertEqual(result[0], lane.NEEDS_MAC)
                push.assert_not_called()
                self.assertEqual(github.posted, [])

    def test_a_merge_tree_the_hosted_run_did_not_test_goes_to_the_mac(self):
        result, _, push = self.run_auto(fast_tests.passing(HEAD), merge_tree='f' * 40)
        self.assertEqual(result[0], lane.NEEDS_MAC)
        push.assert_not_called()

    def test_a_hosted_check_that_failed_fails_the_pr_instead_of_a_second_run(self):
        checks = fast_tests.passing(HEAD, **{'hosted fast: portable': {'conclusion': 'failure'}})
        result, _, push = self.run_auto(checks)
        self.assertEqual(result[0], 'FAIL')
        push.assert_not_called()

    def test_a_cancelled_hosted_check_goes_to_the_mac(self):
        checks = fast_tests.passing(HEAD, **{'hosted fast: portable': {'conclusion': 'cancelled'}})
        self.assertEqual(self.run_auto(checks)[0][0], lane.NEEDS_MAC)


class RoutingTests(unittest.TestCase):
    def test_the_switch_sends_every_automerge_job_to_linux_and_leaves_the_lane_job(self):
        mac = {'lane': ['self-hosted', 'macOS', 'sm-lane'], 'automerge': ['self-hosted', 'macOS']}
        self.assertEqual(scope.hosted_merge_routing(mac, {'LANE_HOSTED_FAST': 'on'}),
                         {'lane': mac['lane'], 'automerge': ['ubuntu-latest']})
        for env in ({}, {'LANE_HOSTED_FAST': 'off'}):
            self.assertEqual(scope.hosted_merge_routing(mac, env), mac)

    def test_the_workflow_has_a_hosted_mac_fallback_and_one_merge_group_per_pr(self):
        workflow = (scope_tests.SCRIPTS.parent / '.github/workflows/lane.yml').read_text()
        job = workflow.split('\n  automerge-mac:\n', 1)[1].split('\n  release:\n', 1)[0]
        self.assertIn("needs.automerge.outputs.needs_mac == 'true'", job)
        self.assertIn('runs-on: macos-latest', job)
        self.assertEqual(workflow.count('group: lane-auto-pr-${{ github.event.pull_request.number }}'), 2)
        self.assertIn('needs_mac: ${{ steps.run.outputs.needs_mac }}', workflow)


if __name__ == '__main__':
    unittest.main()
