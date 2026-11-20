"""Step limits from measured durations, and the drift alarm (scripts/ci_step_budgets.py, 2026-11-20)."""
from datetime import datetime, timedelta, timezone
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import ci_step_budgets as b  # noqa: E402

NOW = datetime(2026, 11, 20, 12, tzinfo=timezone.utc)


def sample(run, step, seconds, days_ago=0.0, job='hosted fast: portable', kind='plan-step'):
    created = (NOW - timedelta(days=days_ago)).isoformat().replace('+00:00', 'Z')
    return {'run': run, 'event': 'merge_group', 'created': created, 'kind': kind, 'job': job, 'step': step,
            'seconds': seconds}


class StepLineTests(unittest.TestCase):
    def test_reads_passed_step_lines_with_or_without_the_actions_timestamp(self):
        log = '\n'.join([
            '2026-11-20T20:45:28.5390406Z runner-tests: 1141.672s — passed',
            'ops-away: 0.114s — passed',
            '2026-11-20T20:41:12.4048700Z package-core: 538.905s — FAILED',
            'contracts: skipped (no reason)',
            'Ran 12 tests in 4.2s',
        ])
        self.assertEqual(b.plan_steps(log), [('runner-tests', 1141.672), ('ops-away', 0.114)])

    def test_the_line_matches_what_verify_tests_prints(self):
        source = (Path(b.ROOT) / 'scripts' / 'verify-tests.py').read_text()
        self.assertIn("print(f'{name}: {entry[\"seconds\"]}s — {\"FAILED\" if errors else \"passed\"}'", source)


class PercentileTests(unittest.TestCase):
    def test_linear_between_ranks(self):
        self.assertEqual(b.percentile([1, 2, 3, 4, 5], 0.5), 3)
        self.assertAlmostEqual(b.percentile([743, 809, 1141, 1180], 0.95), 1174.15, places=2)
        self.assertIsNone(b.percentile([], 0.95))


class DeriveTests(unittest.TestCase):
    def test_limit_is_one_and_a_half_p95_rounded_up_to_a_minute(self):
        samples = [sample(i, 'runner-tests', 700 + 10 * i, days_ago=i / 10) for i in range(30)]
        limit = b.derive(samples)['limits']['RUNNER_TESTS_CEILING']
        p95 = b.percentile([700 + 10 * i for i in range(30)], 0.95)
        self.assertEqual(limit['seconds'], int(-(-1.5 * p95 // 60)) * 60)
        self.assertEqual(limit['samples'], 30)
        self.assertEqual(limit['runs'], list(range(30)))

    def test_only_the_newest_window_counts(self):
        old_slow = [sample(100 + i, 'runner-tests', 5000, days_ago=20 + i) for i in range(10)]
        new = [sample(i, 'runner-tests', 700, days_ago=i / 10) for i in range(30)]
        limit = b.derive(old_slow + new)['limits']['RUNNER_TESTS_CEILING']
        self.assertEqual(limit['seconds'], 1080)
        self.assertNotIn(100, limit['runs'])

    def test_never_below_the_floor(self):
        samples = [sample(i, 'runner-tests', 30, days_ago=i / 10) for i in range(30)]
        self.assertEqual(b.derive(samples)['limits']['RUNNER_TESTS_CEILING']['seconds'],
                         b.LIMITS['RUNNER_TESTS_CEILING']['floor'])

    def test_too_few_samples_keeps_the_previous_value(self):
        samples = [sample(i, 'package-core', 400) for i in range(b.MIN_SAMPLES - 1)]
        previous = {'PARALLEL_CORE_CEILING': {'seconds': 900, 'runs': [1]}}
        limit = b.derive(samples, previous)['limits']['PARALLEL_CORE_CEILING']
        self.assertEqual(limit['seconds'], 900)
        self.assertIn('fewer than', limit['note'])

    def test_a_step_run_by_two_jobs_counts_the_slower_one_per_run(self):
        samples = []
        for i in range(30):
            samples.append(sample(i, 'runner-tests', 1000, days_ago=i / 10))
            samples.append(sample(i, 'runner-tests', 30, days_ago=i / 10, job='hosted fast: Mac rest'))
        limit = b.derive(samples)['limits']['RUNNER_TESTS_CEILING']
        self.assertEqual(limit['p50'], 1000)
        self.assertEqual(limit['samples'], 30)

    def test_the_slowest_of_several_steps_bounds_a_shared_limit(self):
        samples = [sample(i, 'package', 300, days_ago=i / 10, job='hosted fast: Mac rest') for i in range(30)]
        samples += [sample(i, 'package-core-serial', 1200, days_ago=i / 10, job='hosted fast: Mac rest') for i in range(30)]
        limit = b.derive(samples)['limits']['PACKAGE_TEST_CEILING']
        self.assertEqual(limit['bounded_by'], 'package-core-serial')
        self.assertEqual(limit['seconds'], 1800)


class DriftTests(unittest.TestCase):
    def test_a_p50_rise_over_two_weeks_is_reported(self):
        samples = [sample(i, 'research', 100, days_ago=15 + i / 10) for i in range(6)]
        samples += [sample(10 + i, 'research', 130, days_ago=i / 10) for i in range(6)]
        findings = b.drift(samples, {}, {}, now=NOW)
        self.assertEqual(len(findings), 1)
        self.assertIn('p50 rose 30%', findings[0])

    def test_a_small_rise_or_too_few_runs_is_not(self):
        samples = [sample(i, 'research', 100, days_ago=15 + i / 10) for i in range(6)]
        samples += [sample(10 + i, 'research', 120, days_ago=i / 10) for i in range(6)]
        self.assertEqual(b.drift(samples, {}, {}, now=NOW), [])
        few = [sample(i, 'research', 100, days_ago=15) for i in range(3)] + [sample(9, 'research', 500)] * 6
        self.assertEqual(b.drift(few, {}, {}, now=NOW), [])

    def test_a_p95_past_three_quarters_of_its_limit_is_reported(self):
        samples = [sample(i, 'runner-tests', 1400, days_ago=i / 10) for i in range(12)]
        findings = b.drift(samples, {'RUNNER_TESTS_CEILING': {'seconds': 1800}}, {}, now=NOW)
        self.assertEqual(len(findings), 1)
        self.assertIn('78% of its limit', findings[0])
        self.assertEqual(b.drift(samples, {'RUNNER_TESTS_CEILING': {'seconds': 2400}}, {}, now=NOW), [])

    def test_a_job_is_held_to_its_timeout_minutes(self):
        samples = [sample(i, '', 2400, days_ago=i / 10, kind='job') for i in range(12)]
        findings = b.drift(samples, {}, {'hosted fast: portable': 2700}, now=NOW)
        self.assertEqual(len(findings), 1)
        self.assertIn('timeout-minutes of "hosted fast: portable"', findings[0])

    def test_reads_job_timeouts_from_the_workflow(self):
        timeouts = b.job_timeouts()
        self.assertIn('hosted fast: portable', timeouts)
        self.assertIn('hosted fast: Mac rest', timeouts)
        self.assertTrue(all(seconds >= 60 for seconds in timeouts.values()))


class ChooseRunsTests(unittest.TestCase):
    def run_at(self, rid, days_ago, event='pull_request'):
        created = (NOW - timedelta(days=days_ago)).isoformat().replace('+00:00', 'Z')
        return {'id': rid, 'event': event, 'created_at': created}

    def test_reads_the_newest_of_each_event_in_the_recent_and_baseline_weeks(self):
        runs = [self.run_at(i, i / 10) for i in range(200)]  # 20 days of PR runs, ten a day
        runs += [self.run_at(1000 + i, i, 'merge_group') for i in range(3)]
        chosen = {run['id'] for run in b.choose_runs(runs, NOW, per_window=5)}
        self.assertEqual(chosen & set(range(5)), set(range(5)))  # newest PR runs
        self.assertEqual(len(chosen & set(range(140, 200))), 5)  # five from 14 to 20 days ago
        self.assertEqual(chosen & {1000, 1001, 1002}, {1000, 1001, 1002})  # every merge group
        self.assertEqual(len(chosen), 13)

    def test_a_quiet_week_reaches_back_for_enough_runs(self):
        runs = [self.run_at(i, 8 + i, 'merge_group') for i in range(10)]
        chosen = {run['id'] for run in b.choose_runs(runs, NOW, per_window=4)}
        self.assertTrue({0, 1, 2, 3} <= chosen)


class ThinDataTests(unittest.TestCase):
    def test_a_limit_with_too_few_recent_samples_is_named(self):
        samples = [sample(i, 'runner-tests', 900, days_ago=i / 10) for i in range(b.MIN_SAMPLES)]
        samples += [sample(100 + i, 'package-core-serial', 400, days_ago=i / 10) for i in range(b.MIN_SAMPLES)]
        samples += [sample(200 + i, 'package-core', 400, days_ago=10) for i in range(b.MIN_SAMPLES)]  # too old
        self.assertEqual(b.thin_data(samples, now=NOW), ['PARALLEL_CORE_CEILING'])
        self.assertEqual(b.thin_data([], now=NOW), list(b.LIMITS))


class TableTests(unittest.TestCase):
    def test_the_checked_in_table_names_every_limit_with_its_runs(self):
        table = json.loads(b.TABLE.read_text())
        self.assertEqual(set(table['limits']), set(b.LIMITS))
        for name, value in table['limits'].items():
            self.assertGreaterEqual(value['seconds'], b.LIMITS[name]['floor'], name)
            self.assertTrue(value.get('runs'), f'{name} cites no runs')

    def test_verify_tests_takes_its_ceilings_from_the_table(self):
        spec = importlib.util.spec_from_file_location('verify_tests_for_budgets', b.ROOT / 'scripts' / 'verify-tests.py')
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        table = json.loads(b.TABLE.read_text())['limits']
        for name in b.LIMITS:
            self.assertEqual(getattr(module, name), table[name]['seconds'], name)

    def test_a_table_only_change_is_a_mac_and_lane_change(self):
        # Its numbers bound Mac-only steps, so a regeneration PR must not skip the Mac checks or the lane-file rules.
        spec = importlib.util.spec_from_file_location('test_scope_for_budgets', b.ROOT / 'scripts' / 'test-scope.py')
        scope = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(scope)
        self.assertIsNotNone(scope.mac_check_reason('scripts/ci_step_budgets.json'))
        self.assertIn('scripts/ci_step_budgets.json', scope.LANE_FILES)

    def test_table_writes_and_keeps_previous_values_it_cannot_derive(self):
        with tempfile.TemporaryDirectory() as temporary:
            out = Path(temporary)
            samples = [sample(i, 'runner-tests', 800, days_ago=i / 10) for i in range(30)]
            (out / 'samples.json').write_text(json.dumps({'samples': samples}))
            path = out / 'table.json'
            path.write_text(json.dumps({'limits': {'PACKAGE_TEST_CEILING': {'seconds': 1500, 'runs': [7]}}}))
            b.table(out=out, path=path)
            written = json.loads(path.read_text())['limits']
        self.assertEqual(written['RUNNER_TESTS_CEILING']['seconds'], 1200)
        self.assertEqual(written['PACKAGE_TEST_CEILING']['seconds'], 1500)


if __name__ == '__main__':
    unittest.main()
