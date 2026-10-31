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
ON = {'LANE_HOSTED_FAST': 'on', 'LANE_HOSTED_MAC_REST': 'on'}
PAIR_ONLY = {'LANE_HOSTED_FAST': 'on'}  # today's switches until #2469: the hosted pair, Mac rest on the build Mac
CHECKS = lane.HOSTED_MERGED_CHECKS  # #2596: SessionKit core runs inside the Mac-rest job, so two checks stand for a Swift diff
STOOD = {name: {'plan': plan, 'tree': 'a' * 40, 'base': MERGE, 'head': HEAD, 'url': f'https://example.test/{plan}',
                'runner': 'GitHub-hosted'} for name, plan in {**CHECKS, **lane.HOSTED_FAST_CHECKS}.items()}
# STOOD also holds the pair's SessionKit core record, which only the `sessionkit` job (LANE_HOSTED_MAC_REST off) writes.
RUNNING = f'"hosted fast: Mac rest" {lane.NOT_FINISHED} on {HEAD[:7]}'
STALE = f'"hosted fast: portable" tested it on main at {MERGE[:7]}, and main since: its commits touch build inputs (x)'
FAILED = f'"hosted fast: Mac rest" ended failure on {HEAD[:7]}'
MISSING = f'no "hosted fast: Mac rest" check ran on {HEAD[:7]}'
UNRECORDED = f'"hosted fast: portable" on {HEAD[:7]} did not record that it tested fast-portable on this head'
NEWER = '9' * 40


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

    def test_the_hosted_pair_alone_sends_the_automerge_job_to_hosted_linux_first(self):
        # Before: with LANE_HOSTED_MAC_REST off, every automerge job queued for the build Mac, where 12 in two days
        # took 155 Mac-minutes only to report "held for T3", and 11 more idled over 5 minutes for the pair.
        for env in (PAIR_ONLY, {**ON, 'LANE_HOSTED_MAC_REST': 'off'}, {**ON, 'LANE_HOSTED_MAC_REST': 'yes'}):
            with self.subTest(env=env):
                routed = scope.hosted_merge_routing(dict(self.MAC), env)
                self.assertEqual(routed['automerge'], ['ubuntu-latest'])
                self.assertEqual(routed['lane'], self.MAC['lane'])

    def test_the_switches_keep_todays_mac_route(self):
        for env in ({}, {**ON, 'LANE_HOSTED_FAST': 'off'}, {'LANE_HOSTED_MAC_REST': 'on'}):
            with self.subTest(env=env):
                self.assertEqual(scope.hosted_merge_routing(dict(self.MAC), env), self.MAC)

    def test_the_route_and_the_runner_read_the_switches_the_same_way(self):
        for env in ({}, ON, {**ON, 'LANE_HOSTED_MAC_REST': 'off'}, {**ON, 'LANE_HOSTED_FAST': ' On '},
                    {'LANE_HOSTED_MAC_REST': 'on'}, PAIR_ONLY, {'LANE_HOSTED_FAST': 'off'}):
            with self.subTest(env=env):
                hosted = scope.hosted_merge_routing(dict(self.MAC), env)['automerge'] == ['ubuntu-latest']
                self.assertEqual(hosted, lane.hosted_fast_on(env))


class HostedRestChecksTests(unittest.TestCase):
    def wait(self, answers, alive=lambda: None, dispatch_result='', wait=3600, checks=None, newest_base=None,
             seen=None):
        """hosted_rest_checks over a scripted sequence of (found, why) answers, on a fake clock."""
        answers, clock, dispatched = list(answers), Clock(), []
        def once(*args, **kwargs):
            # the portable check and the Mac rest, unless the caller asked for the pair alone
            self.assertEqual(set(args[-1]), set(CHECKS if checks is None else checks))
            if seen is not None:
                seen.append(args[4])  # the base tip this poll compared the checks with
            return answers.pop(0) if len(answers) > 1 else answers[0]
        def dispatch():
            dispatched.append(clock.now)
            return dispatch_result
        with mock.patch.object(lane, '_hosted_fast_checks_once', side_effect=once):
            result = lane.hosted_rest_checks(FakeGitHub(), Path('.'), 'main', HEAD, MERGE, alive=alive,
                                             dispatch=dispatch, env=ON, wait=wait, poll=30, clock=clock,
                                             sleep=clock.sleep, out=open('/dev/null', 'w'),
                                             newest_base=newest_base,
                                             **({} if checks is None else {'checks': checks}))
        return result, clock.now, dispatched

    def test_it_can_wait_for_the_hosted_pair_alone(self):
        pair = {name: STOOD[name] for name in lane.HOSTED_FAST_CHECKS}
        running = f'"hosted fast: portable" {lane.NOT_FINISHED} on {HEAD[:7]}'
        (found, why), waited, _ = self.wait([(None, running)] * 4 + [(pair, '')], checks=lane.HOSTED_FAST_CHECKS)
        self.assertEqual(found, pair)
        self.assertEqual(waited, 4 * 30)

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

    def test_a_check_that_wrote_no_notice_is_run_again_not_handed_to_the_mac(self):
        # #2596: a hosted check that passed but recorded nothing to match against went to the Mac fallback at once.
        self.assertTrue(lane.HOSTED_STALE.search(UNRECORDED))
        (found, why), _, dispatched = self.wait([(None, UNRECORDED), (None, RUNNING), (STOOD, '')])
        self.assertEqual(found, STOOD)
        self.assertEqual(dispatched, [0.0])

    def test_each_poll_compares_the_checks_with_the_newest_base(self):
        # main moved about every 20 minutes while a check took 10 to 25: comparing with the tip the job started on
        # made a fresh run stale before it was read.
        tips, seen = iter(['c' * 40, 'd' * 40, NEWER]), []
        (found, why), _, _ = self.wait([(None, RUNNING), (None, RUNNING), (STOOD, '')], seen=seen,
                                       newest_base=lambda: next(tips))
        self.assertEqual(found, STOOD)
        self.assertEqual(seen, ['c' * 40, 'd' * 40, NEWER])

    def test_a_base_that_cannot_be_fetched_keeps_the_tip_it_has(self):
        def broken():
            raise OSError('network down')
        seen = []
        (found, why), _, _ = self.wait([(STOOD, '')], seen=seen, newest_base=broken)
        self.assertEqual(found, STOOD)
        self.assertEqual(seen, [MERGE])

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


class AllChecks:
    """GitHub's check-run and annotation reads for any of the three hosted checks (test_lane_hosted_fast's FakeChecks
    knows only the pair)."""

    def __init__(self, records):
        self.repo, self.records = 'o/r', records  # check name -> (plan, tree, base, head), or absent: no run

    def api(self, path):
        names = list(CHECKS)
        if '/annotations' in path:
            plan, tree, base, head = self.records[names[int(path.split('/')[-2])]]
            return runner_tests.json.dumps([{'title': lane.HOSTED_TESTED_TITLE, 'annotation_level': 'notice',
                                             'message': f'plan={plan} tree={tree} parents={base} {head}'}])
        name = next(n for n in names if 'check_name=' + lane.urllib.parse.quote(n, safe='') + '&' in path)
        if name not in self.records:
            return runner_tests.json.dumps({'check_runs': []})
        return runner_tests.json.dumps({'check_runs': [{
            'id': names.index(name), 'status': 'completed', 'conclusion': 'success', 'app': {'slug': 'github-actions'},
            'started_at': '2026-10-22T10:00:00Z', 'html_url': f'https://example.test/{names.index(name)}'}]})


class MacRestIsAHardConditionTests(unittest.TestCase):
    """The merge never goes ahead without the Mac-rest check's record on this head and this merge tree: moving those
    tests after the merge would break the owner's 2026-10-21 rule that every test blocks a merge. Read through the
    real hosted_fast_records and tree match, not a stand-in."""
    TREE = 'e' * 40

    def stands(self, records):
        with mock.patch.object(lane, 'merged_tree', return_value=self.TREE):
            return lane.hosted_rest_checks(AllChecks(records), Path('.'), 'main', HEAD, MERGE, alive=lambda: None,
                                           dispatch=lambda: 'no dispatch here', env=ON, wait=0)

    def all_three(self, **changes):
        records = {name: (plan, self.TREE, MERGE, HEAD) for name, plan in CHECKS.items()}
        records.update(changes)
        return records

    def test_all_three_on_this_head_and_tree_stand(self):
        found, why = self.stands(self.all_three())
        self.assertEqual(set(found or {}), set(CHECKS), why)

    def test_the_hosted_pair_alone_never_stands(self):
        records = self.all_three()
        del records['hosted fast: Mac rest']
        found, why = self.stands(records)
        self.assertIsNone(found)
        self.assertIn('Mac rest', why)

    def test_a_mac_rest_record_for_another_head_tree_or_plan_never_stands(self):
        rest = 'hosted fast: Mac rest'
        plan = CHECKS[rest]
        for name, record in (('another head', (plan, self.TREE, MERGE, 'b' * 40)),
                             ('another tree', (plan, 'f' * 40, MERGE, HEAD)),
                             ('another plan', ('fast-portable', self.TREE, MERGE, HEAD)),
                             ('the old job, with no core tests', ('fast-mac-rest', self.TREE, MERGE, HEAD))):
            with self.subTest(name):
                found, why = self.stands(self.all_three(**{rest: record}))
                self.assertIsNone(found)
                self.assertIn(rest, why)


class HostedRunAutoTests(unittest.TestCase):
    T3_ASKED = comment('/lane T3\ncommit: ' + HEAD[:7] + '\ntests: SourceLinkImportTests')

    def run_auto(self, comments=(), found=(STOOD, ''), paths=('Packages/SessionKit/Sources/SessionKit/A.swift',),
                 env=ON, wait_effect=None, builds=None):
        github = FakeGitHub(labels=('automerge',), comments=comments)
        with tempfile.TemporaryDirectory() as temporary, \
                mock.patch.dict(lane.os.environ, env), \
                mock.patch.object(lane, 'TESTED_RECORD', Path(temporary) / 'tested.json'), \
                mock.patch.object(lane, 'build_merge_commit',
                                  side_effect=builds or [(MERGE, [])] * 3) as self.build, \
                mock.patch.object(lane, 'fetch_base', return_value=NEWER), \
                mock.patch.object(lane, 'base_policy', return_value=scope), \
                mock.patch.object(lane, 'diff_scope', return_value=scope.classify(list(paths))), \
                mock.patch.object(lane, 'committed_changes', return_value=(list(paths), {})), \
                mock.patch.object(lane, 'inherited_check', return_value=lambda comments: []), \
                mock.patch.object(lane, 'hot_file_violations', return_value=[]), \
                mock.patch.object(lane, 'host_build_folders') as folders, \
                mock.patch.object(lane, 'sweep_merge_audit'), \
                mock.patch.object(lane, 'dispatch_hosted_integration', return_value=''), \
                mock.patch.object(lane, 'hosted_rest_checks',
                                  side_effect=wait_effect or (lambda *args, **kwargs: found)) as wait, \
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

    def test_main_moving_while_it_waited_merges_on_the_tip_the_checks_were_compared_with(self):
        def newest(*args, **kwargs):
            self.assertEqual(kwargs['newest_base'](), NEWER)
            return STOOD, ''
        (verdict, where, ran, details), github, wait, push = self.run_auto(wait_effect=newest)
        self.assertEqual(verdict, 'PASS')
        self.assertEqual(self.build.call_count, 2)  # once on the tip the job started on, again on the newest
        push.assert_called_once()

    def test_main_not_moving_builds_the_merge_once(self):
        (verdict, *_), github, wait, push = self.run_auto()
        self.assertEqual(verdict, 'PASS')
        self.assertEqual(self.build.call_count, 1)

    def test_a_clash_with_the_newest_base_is_reported_not_merged(self):
        def newest(*args, **kwargs):
            kwargs['newest_base']()
            return STOOD, ''
        (verdict, where, ran, details), github, wait, push = self.run_auto(
            wait_effect=newest, builds=[(MERGE, []), (None, ['scripts/x.py'])])
        push.assert_not_called()
        self.assertEqual(verdict, 'INCONCLUSIVE')
        self.assertTrue(any('does not merge cleanly' in line for line in details), details)

    def test_checks_it_cannot_get_hand_the_run_to_the_mac_fallback(self):
        (verdict, *_), github, wait, push = self.run_auto(found=(None, MISSING))
        self.assertEqual(verdict, lane.NEEDS_MAC)
        push.assert_not_called()
        self.assertEqual(github.posted, [])

    def test_a_failed_hosted_check_is_the_prs_fail(self):
        (verdict, where, ran, details), github, wait, push = self.run_auto(found=(None, FAILED))
        self.assertEqual(verdict, 'FAIL')
        push.assert_not_called()

    def test_with_mac_rest_off_a_pr_held_for_t3_is_reported_held_on_linux(self):
        # Before: "The current diff requires the Mac", and the build Mac ran its host tests only to report held.
        with mock.patch.dict(lane.os.environ, {'LANE_HOSTED_MAC_REST': ''}):
            (verdict, where, ran, details), github, wait, push = self.run_auto([self.T3_ASKED], env=PAIR_ONLY)
        self.assertEqual(verdict, 'INCONCLUSIVE')
        self.assertTrue(any(lane.PENDING_T3_HOLD.match(line) for line in details), details)
        self.assertEqual((where, ran), ('hosted Linux runner', 'nothing'))
        wait.assert_not_called()
        push.assert_not_called()

    def test_with_mac_rest_off_the_mac_gets_the_run_only_after_the_pair_passed(self):
        pair = {name: STOOD[name] for name in lane.HOSTED_FAST_CHECKS}
        with mock.patch.dict(lane.os.environ, {'LANE_HOSTED_MAC_REST': ''}):
            (verdict, where, ran, details), github, wait, push = self.run_auto(found=(pair, ''), env=PAIR_ONLY)
        self.assertEqual(verdict, lane.NEEDS_MAC)
        self.assertEqual(wait.call_args.kwargs.get('checks'), lane.HOSTED_FAST_CHECKS)  # never the Mac-rest check
        self.assertTrue(any('fast-mac-rest' in line for line in details), details)
        push.assert_not_called()
        self.assertEqual(github.posted, [])

    def test_with_mac_rest_off_a_failed_pair_is_the_prs_fail_and_takes_no_mac(self):
        failed = f'"hosted fast: portable" ended failure on {HEAD[:7]}'
        with mock.patch.dict(lane.os.environ, {'LANE_HOSTED_MAC_REST': ''}):
            (verdict, *_), github, wait, push = self.run_auto(found=(None, failed), env=PAIR_ONLY)
        self.assertEqual(verdict, 'FAIL')
        push.assert_not_called()

    def test_with_mac_rest_off_a_pair_it_cannot_get_goes_to_the_mac(self):
        with mock.patch.dict(lane.os.environ, {'LANE_HOSTED_MAC_REST': ''}):
            (verdict, *_), github, wait, push = self.run_auto(found=(None, MISSING), env=PAIR_ONLY)
        self.assertEqual(verdict, lane.NEEDS_MAC)
        self.assertEqual(github.posted, [])

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
