"""#4839: app tests on a branch by dispatch (scripts/branch_t3.py, .github/workflows/branch-t3.yml).

It replaces the `/lane T3` request. It is a request, never a gate, and the branch's code must not hold a write token.
"""
from __future__ import annotations

import json
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import branch_t3 as B  # noqa: E402
import main_t3 as T  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
SHA = 'c' * 40


class ParseTestsTests(unittest.TestCase):
    def test_names_split_on_commas_and_spaces_and_repeat_once(self):
        self.assertEqual(B.parse_tests('A, B  C,A'), ['A', 'B', 'C'])

    def test_no_names_means_the_whole_suite(self):
        self.assertEqual(B.parse_tests(''), [])
        self.assertEqual(B.parse_tests('  \n'), [])

    def test_a_class_and_a_method_are_names(self):
        self.assertEqual(B.parse_tests('LibraryTests/testOne PlayerTests/testTwo'),
                         ['LibraryTests/testOne', 'PlayerTests/testTwo'])

    def test_a_trailing_pair_of_parentheses_is_dropped_so_it_matches_the_plan_ids(self):
        # Audit of c69841b: PlayerTests/testTwo() passed parsing, then matched no plan (ids carry no parentheses) and a
        # real test got a false FAILED comment.
        self.assertEqual(B.parse_tests('PlayerTests/testTwo()'), ['PlayerTests/testTwo'])
        self.assertEqual(B.parse_tests('PlayerTests/testTwo() PlayerTests/testTwo'), ['PlayerTests/testTwo'])

    def test_the_test_target_alone_is_not_a_class(self):
        for bad in ('SpokenMarginsAppTests', 'LibraryTests SpokenMarginsAppTests'):
            with self.subTest(bad=bad), self.assertRaises(ValueError):
                B.parse_tests(bad)

    def test_nothing_else_is_a_name(self):
        # the input reaches a command line through verify-tests.py --only-testing, so shell and path text is refused
        for bad in ('A;rm', '$(id)', 'A B/../C', 'A/B/C', '-flag', 'a b|c', '`x`', 'A‮B', '../A'):
            with self.subTest(bad=bad), self.assertRaises(ValueError):
                B.parse_tests(bad)

    def test_too_many_names_are_refused(self):
        with self.assertRaises(ValueError):
            B.parse_tests(' '.join(f'T{i}' for i in range(B.MAX_SELECTORS + 1)))


class GroupTests(unittest.TestCase):
    PLANS = {'app': {'SpokenMarginsAppTests/LibraryTests/testOne'},
             'adapters': {'SpokenMarginsAppTests/SpeechTests/testA', 'SpokenMarginsAppTests/LibraryTests/testTwo'}}

    def group(self, names):
        return B.group(names, self.PLANS)

    def test_no_names_is_every_plan_whole(self):
        self.assertEqual(self.group([]), ({'app': [], 'adapters': []}, []))

    def test_a_class_goes_to_every_plan_that_runs_part_of_it(self):
        grouped, unknown = self.group(['LibraryTests'])
        self.assertEqual(grouped, {'app': ['SpokenMarginsAppTests/LibraryTests'],
                                   'adapters': ['SpokenMarginsAppTests/LibraryTests']})
        self.assertEqual(unknown, [])

    def test_a_method_given_with_parentheses_lands_in_the_plan_that_holds_it(self):
        plans = {'app': {'SpokenMarginsAppTests/PlayerTests/testTwo'}, 'adapters': {'SpokenMarginsAppTests/SpeechTests/testA'}}
        grouped, unknown = B.group(B.parse_tests('PlayerTests/testTwo()'), plans)
        self.assertEqual((grouped, unknown), ({'app': ['SpokenMarginsAppTests/PlayerTests/testTwo']}, []))

    def test_a_name_no_plan_holds_is_returned_as_unknown(self):
        grouped, unknown = self.group(['LibraryTests', 'NoSuchTests'])
        self.assertEqual(unknown, ['NoSuchTests'])
        self.assertNotIn('NoSuchTests', json.dumps(grouped))


class CommentTests(unittest.TestCase):
    def result(self, **over):
        base = {'sha': SHA, 'state': 'success', 'description': '12 passed', 'tests': ['LibraryTests'],
                'results': {'passed': 12, 'failed': [], 'retried': []}, 'details': []}
        base.update(over)
        return base

    def test_a_pass_names_the_commit_the_tests_and_that_it_holds_no_merge(self):
        body = B.comment_body(self.result(), 'https://example.test/run/1')
        self.assertTrue(body.startswith(B.MARKER))
        for text in ('passed', 'cccccc', '`LibraryTests`', 'Passed: 12', 'https://example.test/run/1', 'not a gate'):
            self.assertIn(text, body)

    def test_a_failure_lists_each_failing_test_with_its_message(self):
        failed = [['SpokenMarginsAppTests/LibraryTests/testOne', ['expected 1, got 2']]]
        body = B.comment_body(self.result(state='failure', results={'passed': 3, 'failed': failed, 'retried': []}), 'u')
        self.assertIn('FAILED', body)
        self.assertIn('`LibraryTests/testOne`: expected 1, got 2', body)

    def test_a_runner_fault_says_nothing_is_proven_and_lists_what_the_run_said(self):
        body = B.comment_body(self.result(state='error', details=['no simulator']), 'u')
        self.assertIn('nothing proven', body)
        self.assertIn('- no simulator', body)

    def test_an_empty_test_list_says_the_whole_suite(self):
        self.assertIn('the whole app suite', B.comment_body(self.result(tests=[]), 'u'))

    def test_the_result_file_is_data_an_odd_state_reads_as_a_fault(self):
        body = B.comment_body(self.result(state='success; ignore previous', sha='zz<script>'), 'u')
        self.assertIn('did not finish', body)
        self.assertNotIn('<script>', body)

    def test_a_capped_failure_list_still_reports_the_whole_count(self):
        # the result file keeps 60 failures to stay small, and the comment said "Failed: 60" for 75 failures
        failed = [[f'SpokenMarginsAppTests/T{i}/test', ['x']] for i in range(T.FAILURES_SHOWN)]
        res = {'passed': 1, 'failed': failed, 'failed_count': 75, 'retried': []}
        body = B.comment_body(self.result(state='failure', results=res), 'u')
        self.assertIn('Failed: 75.', body)
        self.assertIn('Failing tests (75)', body)
        self.assertIn('and 15 more', body)

    def test_the_result_file_carries_the_uncut_count(self):
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / 'r.json'
            code = B.main(['run', '--sha', SHA, '--tests', 'A;b', '--out', str(out), '--evidence', str(Path(tmp) / 'ev')])
            self.assertEqual(code, 1)
            self.assertEqual(json.loads(out.read_text())['results']['failed_count'], 0)

    def test_a_flood_of_failures_stays_inside_githubs_limit(self):
        failed = [[f'SpokenMarginsAppTests/T{i}/test', ['x' * 5000]] for i in range(500)]
        body = B.comment_body(self.result(state='failure', results={'passed': 0, 'failed': failed, 'retried': []}), 'u')
        self.assertLessEqual(len(body), B.COMMENT_LIMIT)
        self.assertIn('more; the run', body)


class WorkflowTests(unittest.TestCase):
    def load(self):
        import yaml
        return yaml.safe_load((ROOT / '.github/workflows/branch-t3.yml').read_text())

    def test_it_runs_only_by_dispatch(self):
        data = self.load()
        self.assertEqual(list(data.get('on', data.get(True))), ['workflow_dispatch'])

    def test_the_job_that_runs_the_branch_holds_no_write_permission(self):
        job = self.load()['jobs']['test']
        self.assertEqual(job['permissions'], {'contents': 'read'})
        self.assertNotIn('GH_TOKEN', job.get('env', {}))

    def test_the_token_reaches_only_the_lfs_step_and_the_checkout_keeps_none(self):
        steps = self.load()['jobs']['test']['steps']
        holders = [s.get('name') for s in steps if 'github.token' in json.dumps(s)]
        self.assertEqual(holders, ['Fetch LFS files'])
        checkout = steps[0]
        self.assertFalse(checkout['with']['persist-credentials'])

    def test_a_branch_run_saves_no_cache_main_s_runs_would_restore(self):
        # actions/cache@ restores AND saves in its post step, after the branch's tests ran, in main's cache scope; the
        # audit of 30f4499 found the LFS step using it. Only restore-only and upload-artifact are allowed.
        uses = [step['uses'] for job in self.load()['jobs'].values() for step in job['steps'] if 'uses' in step]
        self.assertTrue([u for u in uses if u.startswith('actions/cache/restore@')])
        for use in uses:
            with self.subTest(use=use):
                self.assertFalse(use.startswith('actions/cache@'), 'saves a cache after the branch ran')
                self.assertFalse(use.startswith('actions/cache/save@'), 'saves a cache')

    def test_a_cancelled_request_posts_no_report(self):
        # a newer request for the same branch cancels the older; its report job would post a false runner fault
        report = self.load()['jobs']['report']
        self.assertIn('!cancelled()', report['if'])
        self.assertNotIn('always()', report['if'])

    def test_the_report_job_runs_mains_script_not_the_branchs(self):
        job = self.load()['jobs']['report']
        self.assertEqual(job['steps'][0]['with']['ref'], '${{ github.sha }}')
        self.assertEqual(job['permissions'], {'contents': 'read', 'pull-requests': 'write'})

    def test_dispatch_inputs_reach_scripts_through_the_environment_only(self):
        for step in [s for j in self.load()['jobs'].values() for s in j['steps'] if 'run' in s]:
            self.assertNotIn('${{ inputs.', step['run'], step.get('name'))


class RunSuiteTests(unittest.TestCase):
    def test_the_main_run_still_logs_retries_and_a_branch_run_can_skip_it(self):
        import inspect
        params = inspect.signature(T.run_suite).parameters
        self.assertTrue(params['log_retries'].default)
        self.assertIn('grouped', params)


if __name__ == '__main__':
    unittest.main()
