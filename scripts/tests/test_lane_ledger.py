"""The lane's step ledger (#1200): each step's cost and catches, and an alarm on #337 the moment one looks wrong.

The per-PR app builds ran 140 times from 2026-10-02 to 10-09 (about 3.4 min each, ~8 runner-hours a week) and
caught no compile failure; nobody saw it until someone read a week of reports by hand (#1196).
"""
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))
import test_lane_runner  # noqa: E402
from test_lane_runner import FakeGitHub, HEAD, MERGE, NEWER, comment, lane  # noqa: E402
import lane_ledger  # noqa: E402

BASE, OTHER_BASE = 'd' * 40, 'e' * 40


class OutcomeTests(unittest.TestCase):
    def test_verdicts_map_to_pass_fail_or_runner_fault(self):
        self.assertEqual(lane_ledger.outcome('PASS'), 'pass')
        self.assertEqual(lane_ledger.outcome('FAIL'), 'fail')
        for verdict in ('INCONCLUSIVE', 'ERROR', '', None):
            with self.subTest(verdict=verdict):
                self.assertEqual(lane_ledger.outcome(verdict), 'fault')

    def test_a_pass_that_ran_no_test_is_a_fault_and_a_fail_that_ran_none_stays_a_fail(self):
        self.assertEqual(lane_ledger.outcome('PASS', zero_tests=True), 'fault')
        self.assertEqual(lane_ledger.outcome('FAIL', zero_tests=True), 'fail')  # a test target that doesn't compile


class RecordTests(unittest.TestCase):
    def setUp(self):
        self.ledger = lane_ledger.empty()

    def run_step(self, result, seconds=10.0, pr=1, head=HEAD, base=BASE, failed=(), step='host tests'):
        return lane_ledger.record(self.ledger, step, result, seconds, pr, head, base, failed)

    def test_runs_time_and_verdicts_are_counted_per_step(self):
        self.run_step('pass', 30)
        self.run_step('fail', 40)
        self.run_step('fault', 5)
        self.run_step('pass', 2, step='hot-file ratchet')
        step = self.ledger['steps']['host tests']
        self.assertEqual((step['runs'], step['seconds'], step['pass'], step['fail'], step['fault']), (3, 75.0, 1, 1, 1))
        self.assertEqual(self.ledger['steps']['hot-file ratchet']['runs'], 1)

    def test_a_fail_that_a_later_commit_on_the_same_pr_passes_is_a_catch(self):
        self.run_step('fail', pr=7, head=HEAD)
        self.run_step('pass', pr=8, head=NEWER)  # another PR's pass catches nothing
        self.assertEqual(self.ledger['steps']['host tests']['catches'], 0)
        self.run_step('pass', pr=7, head=NEWER)
        self.assertEqual(self.ledger['steps']['host tests']['catches'], 1)
        self.run_step('pass', pr=7, head=NEWER)  # counted once
        self.assertEqual(self.ledger['steps']['host tests']['catches'], 1)

    def test_a_fail_then_a_pass_on_the_same_head_is_a_flake_not_a_catch(self):
        self.run_step('fail', pr=7, head=HEAD)
        self.run_step('pass', pr=7, head=HEAD)
        self.run_step('pass', pr=7, head=NEWER)
        self.assertEqual(self.ledger['steps']['host tests']['catches'], 0)

    def test_twenty_runs_without_a_fail_at_over_a_minute_a_run_raise_the_waste_alarm_once(self):
        for _ in range(19):
            self.assertEqual(self.run_step('pass', 204), [])
        alarms = self.run_step('pass', 204)
        self.assertEqual(len(alarms), 1)
        self.assertTrue(alarms[0].startswith('**Lane step alarm: host tests may be waste.**'), alarms[0])
        self.assertIn('20 runs in a row without a FAIL', alarms[0])
        self.assertIn('3m24s a run', alarms[0])
        for _ in range(10):  # not repeated while the condition holds
            self.assertEqual(self.run_step('pass', 204), [])

    def test_the_waste_alarm_comes_back_only_after_a_fail_clears_it(self):
        for _ in range(20):
            self.run_step('pass', 120)
        self.assertEqual(self.run_step('fail', 120), [])
        raised = [alarm for _ in range(20) for alarm in self.run_step('pass', 120)]
        self.assertEqual(len(raised), 1)

    def test_a_cheap_step_never_raises_the_waste_alarm(self):
        raised = [alarm for _ in range(40) for alarm in self.run_step('pass', 30, step='hot-file ratchet')]
        self.assertEqual(raised, [])

    def test_runner_faults_count_toward_the_waste_streak_but_a_fail_resets_it(self):
        for _ in range(10):
            self.run_step('fault', 90, step='app tests (T3)')
            self.run_step('pass', 90, step='app tests (T3)')
        self.assertEqual(self.ledger['steps']['app tests (T3)']['since_fail_runs'], 20)
        self.run_step('fail', 90, step='app tests (T3)')
        self.assertEqual(self.ledger['steps']['app tests (T3)']['since_fail_runs'], 0)

    def test_three_runner_faults_in_a_row_raise_the_fault_alarm_once(self):
        self.assertEqual(self.run_step('fault'), [])
        self.assertEqual(self.run_step('fault'), [])
        alarms = self.run_step('fault', pr=9)
        self.assertEqual(len(alarms), 1)
        self.assertIn("failed for the lane's own reasons 3 times in a row", alarms[0])
        self.assertIn('PR #9', alarms[0])
        self.assertEqual(self.run_step('fault'), [])

    def test_the_fault_alarm_clears_on_a_pass_or_fail_and_can_come_back(self):
        for _ in range(3):
            self.run_step('fault')
        self.run_step('fail')
        self.assertEqual(self.run_step('fault') + self.run_step('fault'), [])
        self.assertEqual(len(self.run_step('fault')), 1)

    def test_faults_split_by_a_pass_raise_nothing(self):
        raised = []
        for result in ('fault', 'fault', 'pass', 'fault', 'fault', 'pass'):
            raised += self.run_step(result)
        self.assertEqual(raised, [])

    def test_the_same_test_failing_on_two_prs_against_the_same_next_raises_the_shared_alarm_once(self):
        self.assertEqual(self.run_step('fail', pr=1, failed=['T/testA', 'T/testB']), [])
        alarms = self.run_step('fail', pr=2, failed=['T/testA'])
        self.assertEqual(len(alarms), 1)
        self.assertIn('`T/testA` failed host tests on 2 different PRs** (#1, #2)', alarms[0])
        self.assertIn(f'next at `{BASE[:7]}`', alarms[0])
        self.assertEqual(self.run_step('fail', pr=2, failed=['T/testA']), [])  # not again
        self.assertEqual(self.run_step('fail', pr=3, failed=['T/testA']), [])

    def test_one_pr_failing_twice_or_two_prs_on_different_nexts_or_different_tests_raise_nothing(self):
        raised = self.run_step('fail', pr=1, failed=['T/testA'])
        raised += self.run_step('fail', pr=1, failed=['T/testA'], head=NEWER)
        raised += self.run_step('fail', pr=2, failed=['T/testA'], base=OTHER_BASE)
        raised += self.run_step('fail', pr=3, failed=['T/testC'])
        raised += self.run_step('fail', pr=4, failed=['T/testA'], step='app tests (T3)')
        self.assertEqual(raised, [])

    def test_the_shared_failure_memory_keeps_only_the_newest_nexts(self):
        for index in range(lane_ledger.KEEP_BASES + 5):
            self.run_step('fail', pr=1, failed=['T/testA'], base=f'{index:040x}')
        self.assertEqual(len(self.ledger['failures']), lane_ledger.KEEP_BASES)
        self.assertNotIn(f'host tests|{0:040x}', self.ledger['failures'])


class LedgerFileTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.addCleanup(self.folder.cleanup)
        self.state = Path(self.folder.name) / 'state'

    def test_runs_from_separate_jobs_add_up_in_one_file(self):
        run = {'step': 'host tests', 'result': 'fault', 'seconds': 5, 'base': BASE, 'failed': []}
        self.assertEqual(lane_ledger.record_runs(self.state, [run], 1, HEAD), [])
        self.assertEqual(lane_ledger.record_runs(self.state, [run], 2, HEAD), [])
        alarms = lane_ledger.record_runs(self.state, [run], 3, HEAD)
        self.assertEqual(len(alarms), 1)
        saved = json.loads((self.state / lane_ledger.LEDGER).read_text())
        self.assertEqual(saved['steps']['host tests']['fault'], 3)
        self.assertEqual(lane_ledger.record_runs(self.state, [run], 4, HEAD), [])  # the file remembers the alarm

    def test_a_damaged_ledger_is_kept_aside_and_a_new_one_started(self):
        self.state.mkdir()
        (self.state / lane_ledger.LEDGER).write_text('{not json')
        lane_ledger.record_runs(self.state, [{'step': 's', 'result': 'pass', 'seconds': 1}], 1, HEAD)
        self.assertEqual((self.state / (lane_ledger.LEDGER + '.damaged')).read_text(), '{not json')
        self.assertEqual(json.loads((self.state / lane_ledger.LEDGER).read_text())['steps']['s']['runs'], 1)


class RunnerStepTests(unittest.TestCase):
    """lane-runner.py notes each step it runs, and posts the ledger's alarms on #337 once the job has reported."""

    def setUp(self):
        lane.STEP_RUNS.clear()
        self.addCleanup(lane.STEP_RUNS.clear)

    def test_host_tests_are_noted_with_their_verdict_time_and_base(self):
        with tempfile.TemporaryDirectory() as evidence, mock.patch.object(lane, 'TESTED_BASE', BASE):
            verdict, _ = lane.run_fast(Path(evidence), runner=lambda command, log, timeout: None)
        self.assertEqual(verdict, 'INCONCLUSIVE')
        self.assertEqual(len(lane.STEP_RUNS), 1)
        run = lane.STEP_RUNS[0]
        self.assertEqual((run['step'], run['verdict'], run['base']), ('host tests', 'INCONCLUSIVE', BASE))
        self.assertGreaterEqual(run['seconds'], 0)

    def test_a_failed_host_test_suite_is_named_from_the_manifest(self):
        def failing(command, log, timeout):
            output = Path(command[command.index('--output') + 1])
            output.mkdir()
            (output / 'manifest.json').write_text(json.dumps({'status': 'failed', 'steps': [
                {'name': 'runner-tests', 'exit_code': 1}, {'name': 'swift', 'exit_code': 0},
                {'name': 'xunit', 'exit_code': 1, 'tests': {'S/testA': {'status': 'failed'},
                                                            'S/testB': {'status': 'passed'}}}]}))
            return 1
        with tempfile.TemporaryDirectory() as evidence:
            lane.run_fast(Path(evidence), runner=failing)
        self.assertEqual(lane.STEP_RUNS[0]['verdict'], 'FAIL')
        self.assertEqual(lane.STEP_RUNS[0]['failed'], ['runner-tests', 'S/testA'])

    def test_app_builds_name_the_build_that_failed(self):
        codes = iter([0, 2])
        with tempfile.TemporaryDirectory() as evidence:
            lane.run_t2(Path(evidence), runner=lambda *_: next(codes))
        self.assertEqual((lane.STEP_RUNS[0]['step'], lane.STEP_RUNS[0]['failed']), ('app builds', ['device build']))

    def test_a_step_that_raises_is_noted_as_a_runner_fault(self):
        with tempfile.TemporaryDirectory() as evidence, self.assertRaises(OSError):
            lane.run_fast(Path(evidence), runner=mock.Mock(side_effect=OSError('no python')))
        self.assertEqual(lane_ledger.outcome(lane.STEP_RUNS[0]['verdict']), 'fault')

    def test_the_hot_file_ratchet_is_noted_by_the_automerge_checks(self):
        lane.run_automerge({'tier': 'T0', 'why': []}, Path('/e'), ratchet=lambda: ['too big'])
        self.assertEqual([(r['step'], r['verdict']) for r in lane.STEP_RUNS], [('hot-file ratchet', 'FAIL')])

    def test_flush_posts_each_new_alarm_and_empties_the_job_s_runs(self):
        posted = []
        with tempfile.TemporaryDirectory() as state, mock.patch.dict(os.environ, {'SM_LANE_STATE_DIR': state}):
            for pr in (1, 2, 3):
                lane.note_step('app tests (T3)', 'INCONCLUSIVE', 600)
                lane.flush_ledger(pr, HEAD, posted.append)
                self.assertEqual(lane.STEP_RUNS, [])
        self.assertEqual(len(posted), 1)
        self.assertTrue(posted[0].startswith('**Lane step alarm: app tests (T3) failed'), posted[0])
        self.assertIn('after PR #3', posted[0])

    def test_flush_never_fails_the_job(self):
        with tempfile.TemporaryDirectory() as state, mock.patch.dict(os.environ, {'SM_LANE_STATE_DIR': state}), \
                mock.patch('builtins.print'):
            for _ in range(3):
                lane.note_step('host tests', 'INCONCLUSIVE', 1)
                lane.flush_ledger(1, HEAD, mock.Mock(side_effect=RuntimeError('gh: 502')))
            (Path(state) / lane_ledger.LEDGER).write_text('{}')
            (Path(state) / (lane_ledger.LEDGER + '.lock')).chmod(0)  # can't even lock
            lane.note_step('host tests', 'PASS', 1)
            self.assertEqual(lane.flush_ledger(1, HEAD, mock.Mock()), [])
            (Path(state) / (lane_ledger.LEDGER + '.lock')).chmod(0o600)


class MainPostsAlarmsTests(unittest.TestCase):
    """A lane job notes its steps and, after its report, posts any new alarm on #337 (OPS_ISSUE)."""
    run_main = test_lane_runner.MainFlowTests.run_main
    conflicts, role, attempt = [], '', '1'

    def test_three_jobs_in_a_row_with_a_runner_fault_post_one_alarm_on_337(self):
        def t2(evidence):
            lane.note_step('app builds', 'INCONCLUSIVE', 1800)
            return 'INCONCLUSIVE', 'simulator build (timed out), device build (timed out)', []
        with tempfile.TemporaryDirectory() as state:
            self.state_dir, self.ops = state, mock.Mock()
            reports = []
            for _ in range(3):
                github = FakeGitHub(comments=[comment('/lane T2')])
                self.run_main(github, t2=t2)
                reports += github.posted
            ledger = json.loads((Path(state) / lane_ledger.LEDGER).read_text())
        self.assertEqual(len(reports), 3)  # the reports went to the PR as before
        self.assertEqual(ledger['steps']['app builds']['fault'], 3)
        self.assertEqual(ledger['steps']['app builds']['open_fails'], {})
        self.ops.comment.assert_called_once()
        number, body = self.ops.comment.call_args.args
        self.assertEqual(number, lane.OPS_ISSUE)
        self.assertIn('app builds failed for the lane\'s own reasons 3 times in a row', body)
        self.assertIn(f'PR #5 at `{HEAD[:7]}`', body)

    def test_steps_are_noted_against_the_next_the_job_tested(self):
        def t2(evidence):
            lane.note_step('app builds', 'FAIL', 200, failed=['device build'])
            return 'FAIL', 'simulator build (pass), device build (fail)', []
        with tempfile.TemporaryDirectory() as state:
            self.state_dir, self.ops = state, mock.Mock()
            self.run_main(FakeGitHub(comments=[comment('/lane T2')]), t2=t2)
            ledger = json.loads((Path(state) / lane_ledger.LEDGER).read_text())
        self.assertEqual(ledger['failures'], {f'app builds|{MERGE}': {'device build': [5]}})
        self.assertEqual(ledger['steps']['app builds']['open_fails'], {'5': HEAD})


if __name__ == '__main__':
    unittest.main()
