"""#2459: merging runs on hosted Linux and on three hosted checks, so the owner's Mac runs no automerge job.

Before: every automerge job for a Mac diff queued for the build Mac (21 queued on 2026-10-22), waited there up to 15
minutes for the hosted pair, ran --plan fast-mac-rest for about 8 minutes, and a PR held for T3 then reported held.
"""
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))
import test_lane_runner as runner_tests
import test_test_scope as scope_tests

FakeGitHub, HEAD, MERGE, lane, comment = (runner_tests.FakeGitHub, runner_tests.HEAD, runner_tests.MERGE,
                                          runner_tests.lane, runner_tests.comment)
scope = scope_tests.scope
ON = {'LANE_HOSTED_FAST': 'on'}
CHECKS = {**lane.HOSTED_FAST_CHECKS, **lane.HOSTED_REST_CHECK}
STOOD = {name: {'plan': plan, 'tree': 'a' * 40, 'base': MERGE, 'head': HEAD, 'url': f'https://example.test/{plan}',
                'runner': 'GitHub-hosted'} for name, plan in CHECKS.items()}
RUNNING = f'"hosted fast: Mac rest" {lane.NOT_FINISHED} on {HEAD[:7]}'
STALE = f'"hosted fast: portable" tested it on main at {MERGE[:7]}, and main since: its commits touch build inputs (x)'
FAILED = f'"hosted fast: Mac rest" ended failure on {HEAD[:7]}'
MISSING = f'no "hosted fast: Mac rest" check ran on {HEAD[:7]}'


class Clock:
    def __init__(self):
        self.now = 0.0

    def __call__(self):
        return self.now

    def sleep(self, seconds):
        self.now += seconds


class RoutingTests(unittest.TestCase):
    MAC = {'lane': ['self-hosted', 'macOS', 'sm-lane'], 'automerge': ['self-hosted', 'macOS', 'sm-lane-build']}

    def test_every_automerge_job_goes_to_hosted_linux_once_all_three_checks_are_hosted(self):
        routed = scope.hosted_merge_routing(dict(self.MAC), ON)
        self.assertEqual(routed['automerge'], ['ubuntu-latest'])
        self.assertEqual(routed['lane'], self.MAC['lane'])  # T3 requests keep the Mac
        # Never the priority runner (#2147) or any Mac: the automerge job asks for no self-hosted label at all.
        self.assertNotIn('self-hosted', routed['automerge'])

    def test_the_switches_keep_todays_mac_route(self):
        for env in ({}, {'LANE_HOSTED_FAST': 'off'}, {**ON, 'LANE_HOSTED_MAC_REST': 'off'},
                    {**ON, 'LANE_HOSTED_MAC_REST': ' OFF '}):
            with self.subTest(env=env):
                self.assertEqual(scope.hosted_merge_routing(dict(self.MAC), env), self.MAC)

    def test_the_route_and_the_runner_read_the_switches_the_same_way(self):
        for env in ({}, ON, {**ON, 'LANE_HOSTED_MAC_REST': 'off'}, {**ON, 'LANE_HOSTED_MAC_REST': 'on'},
                    {'LANE_HOSTED_MAC_REST': 'on'}):
            with self.subTest(env=env):
                hosted = scope.hosted_merge_routing(dict(self.MAC), env)['automerge'] == ['ubuntu-latest']
                self.assertEqual(hosted, lane.hosted_rest_on(env))


class HostedRestChecksTests(unittest.TestCase):
    def wait(self, answers, alive=lambda: None, dispatch_result='', wait=3600):
        """hosted_rest_checks over a scripted sequence of (found, why) answers, on a fake clock."""
        answers, clock, dispatched = list(answers), Clock(), []
        def once(*args, **kwargs):
            self.assertEqual(set(args[-1]), set(CHECKS))  # all three checks, the Mac rest among them
            return answers.pop(0) if len(answers) > 1 else answers[0]
        def dispatch():
            dispatched.append(clock.now)
            return dispatch_result
        with mock.patch.object(lane, '_hosted_fast_checks_once', side_effect=once):
            result = lane.hosted_rest_checks(FakeGitHub(), Path('.'), 'main', HEAD, MERGE, alive=alive,
                                             dispatch=dispatch, env=ON, wait=wait, poll=30, clock=clock,
                                             sleep=clock.sleep, out=open('/dev/null', 'w'))
        return result, clock.now, dispatched

    def test_it_waits_on_linux_for_a_running_check_and_takes_all_three(self):
        (found, why), waited, dispatched = self.wait([(None, RUNNING)] * 20 + [(STOOD, '')])
        self.assertEqual(found, STOOD)
        self.assertEqual(waited, 20 * 30)  # longer than the Mac's old 15-minute limit would have mattered for
        self.assertEqual(dispatched, [])

    def test_a_failed_check_ends_the_wait_at_once(self):
        (found, why), waited, _ = self.wait([(None, FAILED)])
        self.assertIsNone(found)
        self.assertEqual(waited, 0)
        self.assertEqual(lane.hosted_checks_missing(why)[0], 'FAIL')

    def test_stale_checks_are_run_again_on_the_newest_base_once_and_then_taken(self):
        (found, why), _, dispatched = self.wait([(None, STALE), (None, STALE), (None, RUNNING), (STOOD, '')])
        self.assertEqual(found, STOOD)
        self.assertEqual(dispatched, [0.0])  # one dispatch: the second stale answer was the old run still newest

    def test_checks_still_stale_after_a_fresh_run_are_run_again_up_to_the_limit(self):
        cycle = [(None, STALE), (None, RUNNING)]
        (found, why), _, dispatched = self.wait(cycle * (lane.HOSTED_REDISPATCHES + 1) + [(None, STALE)])
        self.assertIsNone(found)
        self.assertEqual(len(dispatched), lane.HOSTED_REDISPATCHES)
        self.assertEqual(lane.hosted_checks_missing(why)[0], lane.NEEDS_MAC)

    def test_a_dispatch_github_refuses_goes_to_the_mac_fallback(self):
        (found, why), _, dispatched = self.wait([(None, STALE)], dispatch_result='HTTP 422: Unexpected inputs')
        self.assertIsNone(found)
        self.assertIn('HTTP 422', why)
        self.assertEqual(lane.hosted_checks_missing(why)[0], lane.NEEDS_MAC)

    def test_a_missing_check_is_waited_for_only_a_few_minutes(self):
        (found, why), waited, _ = self.wait([(None, MISSING)])
        self.assertIsNone(found)
        self.assertLessEqual(waited, lane.HOSTED_MISSING_GRACE + 30)
        self.assertEqual(lane.hosted_checks_missing(why)[0], lane.NEEDS_MAC)

    def test_a_pr_that_moved_on_stops_the_wait(self):
        (found, why), waited, _ = self.wait([(None, RUNNING)], alive=lambda: lane.MOVED_ON + 'the PR moved on')
        self.assertIsNone(found)
        self.assertTrue(why.startswith(lane.MOVED_ON))
        self.assertEqual(waited, 0)

    def test_outside_a_lane_job_it_never_sleeps(self):
        with mock.patch.object(lane, '_hosted_fast_checks_once', return_value=(None, RUNNING)), \
                mock.patch.object(lane.time, 'sleep', side_effect=AssertionError('slept')):
            found, why = lane.hosted_rest_checks(FakeGitHub(), Path('.'), 'main', HEAD, MERGE, alive=lambda: None,
                                                 dispatch=lambda: '', env=ON)
        self.assertIsNone(found)


class HostedRunAutoTests(unittest.TestCase):
    T3_ASKED = comment('/lane T3\ncommit: ' + HEAD[:7] + '\ntests: SourceLinkImportTests')

    def run_auto(self, comments=(), found=(STOOD, ''), paths=('Packages/SessionKit/Sources/SessionKit/A.swift',)):
        github = FakeGitHub(labels=('automerge',), comments=comments)
        with tempfile.TemporaryDirectory() as temporary, \
                mock.patch.dict(lane.os.environ, ON), \
                mock.patch.object(lane, 'TESTED_RECORD', Path(temporary) / 'tested.json'), \
                mock.patch.object(lane, 'build_merge_commit', return_value=(MERGE, [])), \
                mock.patch.object(lane, 'base_policy', return_value=scope), \
                mock.patch.object(lane, 'diff_scope', return_value=scope.classify(list(paths))), \
                mock.patch.object(lane, 'inherited_check', return_value=lambda comments: []), \
                mock.patch.object(lane, 'hot_file_violations', return_value=[]), \
                mock.patch.object(lane, 'host_build_folders') as folders, \
                mock.patch.object(lane, 'sweep_merge_audit'), \
                mock.patch.object(lane, 'dispatch_hosted_integration', return_value=''), \
                mock.patch.object(lane, 'hosted_rest_checks', return_value=found) as wait, \
                mock.patch.object(lane, 'hosted_fast_checks') as pair, \
                mock.patch.object(lane, 'run_fast') as fast, \
                mock.patch.object(lane, 'run_mac_rest') as rest, \
                mock.patch.object(lane, 'run_ops') as ops, \
                mock.patch.object(lane, 'push_merge', return_value=(True, '')) as push:
            result = lane.run_auto(github, {'head': {'ref': 'ws/1-x'}}, 5, 'main', HEAD, MERGE, Path(temporary),
                                   list(comments), labels=('automerge',), hosted=True)
        for runner in (folders, pair, fast, rest, ops):  # no Mac setup and no test of its own, ever
            runner.assert_not_called()
        return result, github, wait, push

    def test_a_pr_held_for_t3_is_reported_held_without_waiting_or_testing(self):
        (verdict, where, ran, details), github, wait, push = self.run_auto([self.T3_ASKED])
        self.assertEqual(verdict, 'INCONCLUSIVE')
        self.assertTrue(any(lane.PENDING_T3_HOLD.match(line) for line in details), details)
        self.assertEqual(ran, 'nothing')
        wait.assert_not_called()
        push.assert_not_called()

    def test_the_three_hosted_checks_merge_it_with_no_test_here(self):
        (verdict, where, ran, details), github, wait, push = self.run_auto()
        self.assertEqual(verdict, 'PASS')
        push.assert_called_once()
        self.assertIn('none on the Mac', ran)
        self.assertIn(f'merged into main as {MERGE[:7]}', details)
        self.assertTrue(any('"hosted fast: Mac rest": PASS' in line for line in details), details)

    def test_checks_it_cannot_get_hand_the_run_to_the_mac_fallback(self):
        (verdict, *_), github, wait, push = self.run_auto(found=(None, MISSING))
        self.assertEqual(verdict, lane.NEEDS_MAC)
        push.assert_not_called()
        self.assertEqual(github.posted, [])

    def test_a_failed_hosted_check_is_the_prs_fail(self):
        (verdict, where, ran, details), github, wait, push = self.run_auto(found=(None, FAILED))
        self.assertEqual(verdict, 'FAIL')
        push.assert_not_called()

    def test_ops_and_docs_diffs_still_test_themselves_on_linux(self):
        github = FakeGitHub(labels=('automerge',))
        with tempfile.TemporaryDirectory() as temporary, \
                mock.patch.dict(lane.os.environ, ON), \
                mock.patch.object(lane, 'TESTED_RECORD', Path(temporary) / 'tested.json'), \
                mock.patch.object(lane, 'build_merge_commit', return_value=(MERGE, [])), \
                mock.patch.object(lane, 'base_policy', return_value=scope), \
                mock.patch.object(lane, 'diff_scope', return_value=scope.classify(['ops/dial/a.py'])), \
                mock.patch.object(lane, 'inherited_check', return_value=lambda comments: []), \
                mock.patch.object(lane, 'hot_file_violations', return_value=[]), \
                mock.patch.object(lane, 'sweep_merge_audit'), \
                mock.patch.object(lane, 'dispatch_hosted_integration', return_value=''), \
                mock.patch.object(lane, 'hosted_rest_checks') as wait, \
                mock.patch.object(lane, 'run_ops', return_value=('PASS', [])) as ops, \
                mock.patch.object(lane, 'push_merge', return_value=(True, '')):
            verdict = lane.run_auto(github, {}, 5, 'main', HEAD, MERGE, Path(temporary), [], hosted=True)[0]
        self.assertEqual(verdict, 'PASS')
        ops.assert_called_once()
        wait.assert_not_called()


class HostedMainTests(unittest.TestCase):
    run_main = runner_tests.MainFlowTests.run_main
    conflicts, role, attempt, state_dir, ops = [], '', '1', None, mock.Mock()

    def test_needs_mac_posts_nothing_and_tells_the_workflow(self):
        github = FakeGitHub(labels=('automerge',))
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / 'out'
            with mock.patch.dict(lane.os.environ, {'GITHUB_OUTPUT': str(output)}), \
                    mock.patch.object(lane, 'run_auto', return_value=(lane.NEEDS_MAC, 'hosted Linux runner', 'nothing',
                                                                      ['the hosted checks do not stand: x'])):
                self.assertEqual(self.run_main(github, HEAD, 'PASS', '--mode', 'auto', '--hosted'), 0)
            self.assertIn('needs_mac=true', output.read_text())
            self.assertNotIn('reported=true', output.read_text())
        self.assertEqual(github.posted, [])
        self.assertEqual(github.label_changes, [])


class MergeAfterT3Tests(unittest.TestCase):
    def test_a_t3_pass_merges_on_standing_hosted_checks_instead_of_handing_off_to_the_mac(self):
        held = runner_tests.runner_report('INCONCLUSIVE', lane.identity('auto', HEAD, MERGE, []))
        held['body'] = held['body'].replace('crashes:', 'not merged: held for T3: waiting.\ncrashes:')
        github = FakeGitHub(labels=('automerge',), comments=[held])
        hand_off = mock.Mock(return_value='https://example.test/release')
        with tempfile.TemporaryDirectory() as temporary, \
                mock.patch.dict(lane.os.environ, ON), \
                mock.patch.object(lane, 'TESTED_RECORD', Path(temporary) / 'tested.json'), \
                mock.patch.object(lane, 'clean_tree'), \
                mock.patch.object(lane, 'fetch_base', return_value=MERGE), \
                mock.patch.object(lane, 'hosted_rest_checks', return_value=(STOOD, '')), \
                mock.patch.object(lane, 'run_auto', return_value=('PASS', 'host only', 'x',
                                                                   [f'merged into main as {MERGE[:7]}'])) as auto:
            self.assertTrue(lane.held_for_t3(github.comments(), HEAD))
            lane.merge_after_t3(github, 5, 'main', HEAD, 'r1', Path(temporary) / 'e', MERGE, 'started by T3',
                                hand_off=hand_off)
        hand_off.assert_not_called()
        self.assertTrue(auto.call_args.kwargs.get('rest_hosted'))
        self.assertEqual(auto.call_args.kwargs.get('rest_wait'), 0)


if __name__ == '__main__':
    unittest.main()
