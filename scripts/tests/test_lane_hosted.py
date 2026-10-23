"""#861: hosted automerge must never admit a Mac diff or bypass the merge gates."""
from pathlib import Path
import os
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))
import test_lane_runner as runner_tests
import test_test_scope as scope_tests

FakeGitHub, HEAD, MERGE, lane = (runner_tests.FakeGitHub, runner_tests.HEAD, runner_tests.MERGE, runner_tests.lane)
scope = scope_tests.scope


class HostedRoutingTests(unittest.TestCase):
    route = scope_tests.LaneRunnerRoutingTests.route
    assert_normal = scope_tests.LaneRunnerRoutingTests.assert_normal

    def test_t0_and_ops_use_hosted_even_without_an_online_mac(self):
        for paths in (['docs/plan.md'], ['README.md', 'research/notes.txt'],
                      ['ops/dial/dial_gate.py'], ['ops/codex/a.py', 'docs/plan.md']):
            for labels in ([], ['priority']):
                with self.subTest(paths=paths, labels=labels):
                    result = self.route(paths, labels=labels, online=False)
                    self.assertEqual(result['automerge'], ['ubuntu-latest'])

    def test_ops_only_explicit_lane_requests_keep_their_priority_route(self):
        self.assertEqual(self.route(['ops/dial/a.py'])['lane'], ['self-hosted', 'sm-lane-priority'])

    def test_hosted_route_does_not_depend_on_the_runner_list(self):
        # GitHub-hosted runners never appear in the repo's runner list (#2442), so any readable list will do.
        other = [{'runners': [{'status': 'offline', 'busy': False, 'labels': [{'name': 'sm-vps-t1'}]},
                              {'status': 'online', 'busy': False, 'labels': [{'name': 'sm-lane-build'}]}]}]
        for paths in (['docs/plan.md'], ['ops/dial/dial_gate.py']):
            with self.subTest(paths=paths):
                self.assertEqual(self.route(paths)['automerge'], ['ubuntu-latest'])
                self.assertEqual(self.route(paths, runners=other)['automerge'], ['ubuntu-latest'])

    def test_every_lane_path_and_mixed_diff_stays_on_mac(self):
        for path in sorted(scope.LANE_FILES) + ['.github/workflows/lane.yml', 'scripts/lane_new.py',
                'scripts/tests/test_lane_runner.py', 'scripts/validate-contracts.py', 'App/README.md',
                'Packages/README.md', 'Contracts/docs/a.md', 'App/A.swift', 'project.yml',
                'research/B4/server.go', 'ops/power/amph', 'ops/power/test_amph.py']:
            with self.subTest(path=path):
                self.assertIn('self-hosted', self.route(['ops/dial/a.py', path])['automerge'])

    def test_api_error_partial_duplicate_or_bad_files_fall_back(self):
        cases = [dict(files=[]), dict(files={'message': 'API error'}), dict(files=[['bad file']]),
                 dict(files=[[{'filename': 'docs/a.md'}]]),
                 dict(files=[[{'filename': 'docs/a.md'}, {'filename': 'docs/a.md'}]]),
                 dict(files=[[{'filename': 'docs/a.md'}, {'filename': ''}]]),
                 dict(runners=[]), dict(runners={'message': 'API error'}),
                 dict(runners=[{'runners': {}}]), dict(runners=[{'runners': [{}]}])]
        for overrides in cases:
            with self.subTest(overrides=overrides):
                self.assert_normal(self.route(['docs/a.md', 'docs/b.md'], **overrides))

    def test_rename_into_or_out_of_ops_checks_both_sides(self):
        for old, new, hosted in [('App/A.swift', 'ops/dial/a.py', False),
                                 ('ops/dial/a.py', 'docs/a.md', True),
                                 ('scripts/lane_guard.py', 'docs/a.md', False)]:
            with self.subTest(old=old, new=new):
                result = self.route([new], files=[[{'filename': new, 'previous_filename': old}]])
                self.assertEqual(result['automerge'] == ['ubuntu-latest'], hosted)
        self.assert_normal(self.route(['docs/a.md'], files=[[{
            'filename': 'docs/a.md', 'status': 'renamed'}]]))


class HostedExecutionTests(unittest.TestCase):
    def test_ops_run_real_folder_tests_without_fast_or_mac_tools(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            folder = root / 'ops/example'
            folder.mkdir(parents=True)
            test = folder / 'test_example.py'
            test.write_text('import unittest\nclass Example(unittest.TestCase):\n'
                            '    def test_example(self): self.assertTrue(True)\n')
            evidence = root / 'evidence'
            evidence.mkdir()
            with mock.patch.object(lane, 'ROOT', root):
                self.assertEqual(lane.run_ops(evidence)[0], 'PASS')
                test.write_text(test.read_text().replace('assertTrue(True)', 'assertTrue(False)'))
                self.assertEqual(lane.run_ops(evidence)[0], 'FAIL')

    def test_hosted_ratchet_runs_before_ops_tests(self):
        checked = {'tier': 'T1', 'why': ['ops'], 'files': [
            {'path': 'ops/dial/a.py', 'category': 'ops'}]}
        with tempfile.TemporaryDirectory() as temporary, mock.patch.object(lane, 'run_ops') as ops:
            result = lane.run_automerge(checked, Path(temporary), hosted=True,
                                       ratchet=lambda: ['over ceiling'])
            self.assertEqual(result[0], 'FAIL')
            ops.assert_not_called()

    def test_empty_ops_suite_cannot_pass(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / 'ops/example').mkdir(parents=True)
            (root / 'ops/example/test_empty.py').write_text('import unittest\n')
            with mock.patch.object(lane, 'ROOT', root):
                verdict, details = lane.run_ops(root)
            self.assertEqual(verdict, 'INCONCLUSIVE')
            self.assertIn('zero tests', details[-1])

    def test_hosted_cleanup_does_not_sweep_simulators(self):
        github = FakeGitHub(labels=('automerge',))
        with mock.patch.object(lane, 'sweep_runner_simulators') as sweep:
            lane.cleanup(github, 'run', 'auto', hosted=True)
        sweep.assert_not_called()
        self.assertTrue(github.posted[0].startswith('Lane: the automerge run stopped'))


class HostedMainTests(unittest.TestCase):
    run_main = runner_tests.MainFlowTests.run_main
    conflicts, role, attempt, state_dir, ops = [], '', '1', None, mock.Mock()

    def test_hosted_run_posts_report_and_done_without_mac_setup(self):
        github = FakeGitHub(labels=('automerge',))
        with mock.patch.object(lane, 'run_auto', return_value=('PASS', 'hosted', 'ops tests', [])) as auto, \
                mock.patch.object(lane, 'drop_workspace_builds') as drop:
            self.assertEqual(self.run_main(github, HEAD, 'PASS', '--mode', 'auto', '--hosted'), 0)
        self.assertTrue(auto.call_args.kwargs['hosted'])
        self.auto_revert.assert_not_called()
        drop.assert_not_called()
        self.assertIn('(on a GitHub-hosted Linux runner)', github.posted[0])
        self.assertEqual(github.label_changes, [('lane:done', 'lane:done')])


class HostedMergeTests(unittest.TestCase):
    def setUp(self):
        # The Actions runner exports the repository's LANE_HOSTED_* rollout variables; these tests mean the defaults (#2525, #2526).
        env = {key: value for key, value in os.environ.items() if not key.startswith('LANE_HOSTED_')}
        patcher = mock.patch.dict(os.environ, env, clear=True)
        patcher.start()
        self.addCleanup(patcher.stop)

    def run_auto(self, paths, inherited=(), checked=None):
        github = FakeGitHub(labels=('automerge',))
        classified = scope.classify(paths)
        with tempfile.TemporaryDirectory() as temporary, \
                mock.patch.object(lane, 'TESTED_RECORD', Path(temporary) / 'tested.json'), \
                mock.patch.object(lane, 'build_merge_commit', return_value=(MERGE, [])), \
                mock.patch.object(lane, 'base_policy', return_value=scope), \
                mock.patch.object(lane, 'diff_scope', return_value=classified), \
                mock.patch.object(lane, 'inherited_check', return_value=lambda comments: list(inherited)), \
                mock.patch.object(lane, 'hot_file_violations', return_value=[]), \
                mock.patch.object(lane, 'host_build_folders') as folders, \
                mock.patch.object(lane, 'sweep_merge_audit'), \
                mock.patch.object(lane, 'checks_stand', return_value=True), \
                mock.patch.object(lane, 'untested_moves', return_value=([], 'unchanged')), \
                mock.patch.object(lane, 'run_ops', return_value=('PASS', [])) as ops, \
                mock.patch.object(lane, 'push_merge', return_value=(True, '')) as push:
            result = lane.run_auto(github, {}, 5, 'next', HEAD, MERGE, Path(temporary), [],
                                   checked=checked, hosted=True)
        folders.assert_not_called()
        return result, github, push, ops

    def test_docs_and_ops_post_the_existing_merge_check_and_merge(self):
        for paths, runs_ops in [(['docs/a.md'], False), (['ops/dial/a.py', 'docs/a.md'], True)]:
            with self.subTest(paths=paths):
                result, github, push, ops = self.run_auto(paths)
                self.assertEqual(result[0], 'PASS')
                self.assertTrue(github.posted[0].startswith('**Merge check (triage desk)'))
                push.assert_called_once()
                self.assertEqual(ops.called, runs_ops)

    def test_inherited_audit_still_holds_a_hosted_merge(self):
        result, github, push, ops = self.run_auto(['docs/a.md'], ['it inherits a blocking audit finding'])
        self.assertEqual(result[0], 'PASS')
        self.assertIn('not merged by the runner: it inherits', '\n'.join(result[3]))
        push.assert_not_called()

    def test_latest_scope_rejects_mac_diff_even_if_a_previous_check_passed(self):
        checked = {'next': MERGE, 'ran': 'old checks', 'where': 'hosted'}
        for previous in (None, checked):
            with self.subTest(reused=bool(previous)):
                result, github, push, ops = self.run_auto(['scripts/lane_slots.py'], checked=previous)
                self.assertEqual(result[0], 'INCONCLUSIVE')
                push.assert_not_called()
                ops.assert_not_called()


if __name__ == '__main__':
    unittest.main()
