"""The slow tier (#5145): slow tests that never fail leave PRs and run nightly and before builds on main.

What must hold: the list never names a packet, database or owner-data guard or a test that no longer exists; a PR run
under --leave-out-slow leaves out exactly the listed tests and says so; --plan slow runs exactly those; every
hosted-portable plan passes the flag; and a failing nightly names the merges since the last green run.
"""
import datetime
import importlib.util
import re
import subprocess
import sys
import tempfile
import types
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
ROOT = SCRIPTS.parent
sys.path.insert(0, str(SCRIPTS))

import main_slow  # noqa: E402
import slow_tier  # noqa: E402


def load(name, file):
    spec = importlib.util.spec_from_file_location(name, SCRIPTS / file)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


verification = load('verification_slow_tier', 'verify-tests.py')


class TheListTests(unittest.TestCase):
    def test_every_listed_test_exists_and_none_is_a_guard(self):
        self.assertEqual(slow_tier.problems(), [])

    def test_a_guard_or_a_vanished_test_is_refused(self):
        guard = 'SessionKitCoreTests/Build29PersistedShapeTests/testEveryEnumBuild29PersistsStillHasExactlyTheRawValuesBuild29Knew'
        for extra in (guard, 'SessionKitCoreTests/SharingPacketTests/testAnything',
                      'SessionKitCoreTests/KittenFrontEndTests/testThatWasDeleted', 'NotATarget/X/testY'):
            with self.subTest(extra=extra):
                saved = dict(slow_tier.SLOW_SWIFT_TESTS)
                slow_tier.SLOW_SWIFT_TESTS[extra] = 'test'
                try:
                    found = slow_tier.problems()
                finally:
                    slow_tier.SLOW_SWIFT_TESTS.clear()
                    slow_tier.SLOW_SWIFT_TESTS.update(saved)
                self.assertTrue(any(line.startswith(extra) for line in found), found)

    def test_a_vanished_runner_module_is_refused(self):
        with tempfile.TemporaryDirectory() as folder:
            found = slow_tier.problems(Path(folder))
        self.assertTrue(any('no scripts/tests/test_sm_status.py' in line for line in found), found)

    def test_the_swift_regex_names_exactly_the_listed_tests(self):
        tests = set(slow_tier.SLOW_SWIFT_TESTS)
        pattern = re.compile(slow_tier.swift_regex(tests))
        for name in tests:
            target, cls, test = name.split('/')
            self.assertTrue(pattern.search(f'{target}.{cls}/{test}'), name)
            self.assertFalse(pattern.search(f'{target}.{cls}/{test}Too'), name)  # anchored: no prefix matches
            self.assertFalse(pattern.search(f'{target}.{cls}/testOther'), name)
        self.assertFalse(pattern.search('SessionKitCoreTests.KittenFrontEndTests/testHugeNumbersAreReadDigitByDigit'))


class LeaveOutTests(unittest.TestCase):
    def fake_run(self, leave_out):
        saved = []
        run = types.SimpleNamespace(manifest={'leave_out_slow': True} if leave_out else {}, save=lambda: saved.append(1))
        return run

    def test_without_the_flag_nothing_is_left_out(self):
        run = self.fake_run(False)
        expected = {'SessionKitCoreTests/KittenFrontEndTests/testSeededWordsAndNormalizerInputsMatchTheReference', 'X/Y/testZ'}
        self.assertEqual(verification.Run.slow_left_out(run, expected, ('SessionKitCoreTests',)), (expected, []))
        self.assertEqual(verification.Run.runner_leave_out(run), [])

    def test_with_the_flag_the_listed_tests_of_those_targets_leave_and_are_named(self):
        run = self.fake_run(True)
        core = {t for t in slow_tier.SLOW_SWIFT_TESTS if t.startswith('SessionKitCoreTests/')}
        other = 'SessionKitCoreTests/KittenFrontEndTests/testHugeNumbersAreReadDigitByDigit'
        rest = 'SessionKitTests/KittenRendererTests/testALongArticleThroughTheFallbackVoiceNeverPausesOverOneSecond'
        expected, args = verification.Run.slow_left_out(run, core | {other, rest}, ('SessionKitCoreTests',))
        self.assertEqual(expected, {other, rest})  # another target's test is that target's step's business
        self.assertEqual(args[0], '--skip')
        self.assertEqual(sorted(run.manifest['slow_tier_left_out']), sorted(core))
        self.assertEqual(verification.Run.runner_leave_out(run), ['test_sm_status'])

    def test_the_flag_goes_only_with_the_split_plans(self):
        done = subprocess.run([sys.executable, str(SCRIPTS / 'verify-tests.py'), '--plan', 'fast', '--leave-out-slow',
                               '--list'], capture_output=True, text=True, cwd=ROOT)
        self.assertNotEqual(done.returncode, 0)
        self.assertIn('--leave-out-slow goes with', done.stderr)

    def test_the_slow_plan_lists_the_tier(self):
        done = subprocess.run([sys.executable, str(SCRIPTS / 'verify-tests.py'), '--plan', 'slow', '--list'],
                              capture_output=True, text=True, cwd=ROOT)
        self.assertEqual(done.returncode, 0, done.stderr)
        for name in [*slow_tier.SLOW_RUNNER_MODULES, *slow_tier.SLOW_SWIFT_TESTS]:
            self.assertIn(name, done.stdout)

    def test_every_hosted_portable_plan_leaves_the_tier_out(self):
        workflow = (ROOT / '.github/workflows/hosted-portable.yml').read_text()
        plans = re.findall(r'\.venv/bin/python scripts/verify-tests\.py --plan (\S+)([^\n]*)', workflow)
        self.assertGreaterEqual(len(plans), 4)
        for plan, rest in plans:
            self.assertIn('--leave-out-slow', rest, plan)

    def test_the_sessionkit_runner_passes_a_skip_to_each_split_run(self):
        script = (SCRIPTS / 'run-sessionkit-tests.sh').read_text()
        for mode in ('--core-parallel)', '--core-serial)', '--rest)'):
            block = script[script.index(f'  {mode}'):]
            block = block[:block.index(';;')]
            self.assertIn('${SKIP[@]+"${SKIP[@]}"}', block, mode)
        self.assertIn('--filter "$2"', script[script.index('  --only)'):])


class MainSlowTests(unittest.TestCase):
    now = datetime.datetime(2026, 11, 23, 12, tzinfo=datetime.timezone.utc)

    def test_decide_reads_only_its_own_context(self):
        t3 = [{'context': 'main-t3', 'state': 'success', 'created_at': '2026-11-23T10:00:00Z'}]
        self.assertTrue(main_slow.should_run(t3, self.now)[0])
        ours = t3 + [{'context': 'main-slow', 'state': 'failure', 'created_at': '2026-11-23T10:00:00Z'}]
        self.assertFalse(main_slow.should_run(ours, self.now)[0])
        self.assertEqual(main_slow.main_t3.CONTEXT, 'main-t3')  # main_t3's own context is left as it was

    def test_a_manifest_gives_the_state_and_the_failing_tests(self):
        green = {'status': 'verified', 'steps': [{'name': 'slow-swift', 'tests': {'A/B/testC': {'status': 'passed'}}}]}
        self.assertEqual(main_slow.results_from_manifest(green, 0)[0], 'success')
        red = {'status': 'failed_or_incomplete', 'steps': [
            {'name': 'slow-runner-tests', 'errors': ['Process exit 1; Failed: test_x (test_sm_status.T.test_x) at f.py:3']},
            {'name': 'slow-swift', 'tests': {'SessionKitCoreTests/K/testA': {'status': 'failed'}}}]}
        state, failed, _ = main_slow.results_from_manifest(red, 1)
        self.assertEqual(state, 'failure')
        self.assertEqual(sorted(failed), ['SessionKitCoreTests/K/testA', 'test_sm_status.T.test_x'])
        self.assertEqual(main_slow.results_from_manifest({}, 1)[0], 'error')  # never started: a runner fault
        fault = {'status': 'failed_or_incomplete', 'lane_fault': 'no audio output: stuck', 'steps': [{'name': 'x'}]}
        self.assertEqual(main_slow.results_from_manifest(fault, 1)[0], 'error')  # a stuck output is not main's

    def test_the_failure_issue_names_the_merges_since_the_last_green(self):
        merges = ['abc1234 Merge pull request #5001 from x/y', 'def5678 Merge pull request #5002 from x/z']
        body = main_slow.issue_body('f' * 40, 'https://run', ['SessionKitCoreTests/K/testA'], [], 'e' * 40, merges)
        self.assertIn(main_slow.MARKER, body)
        self.assertIn('Last green `main-slow`: `' + 'e' * 40, body)
        for merge in merges:
            self.assertIn(merge, body)
        self.assertEqual(main_slow.issue_state({'body': body})['last_green'], 'e' * 40)
        self.assertIn('none in the last', main_slow.issue_body('f' * 40, 'u', [], ['x'], None, []))

    def test_the_last_green_is_the_newest_success_other_than_the_commit_itself(self):
        nodes = [{'oid': 'a', 'status': {'context': {'state': 'SUCCESS'}}},
                 {'oid': 'b', 'status': {'context': {'state': 'FAILURE'}}},
                 {'oid': 'c', 'status': {'context': {'state': 'SUCCESS'}}}]
        self.assertEqual(main_slow.last_green(nodes, exclude='a'), 'c')
        self.assertIn('"main-slow"', main_slow.HISTORY_QUERY)

    def test_the_workflow_runs_the_slow_plan_on_a_schedule_and_reports(self):
        workflow = (ROOT / '.github/workflows/main-slow.yml').read_text()
        self.assertEqual(len(re.findall(r"- cron: '", workflow)), 3)
        self.assertIn('verify-tests.py --plan slow', workflow)
        self.assertIn('scripts/main_slow.py report', workflow)
        self.assertIn('scripts/main_slow.py lost', workflow)
        lost = workflow[workflow.index('- name: Record a lost run'):]
        self.assertIn("steps.report.outcome != 'success'", lost[:lost.index('run:')])  # a failed report still clears pending
        self.assertIn('fetch-depth: 0', workflow)  # the merges since the last green need history


if __name__ == '__main__':
    unittest.main()
