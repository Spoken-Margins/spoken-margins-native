"""The hosted integration run gives the app plan an hour (#2596); the owner's Mac keeps PLANS' own budgets.

Before: the hosted Mac ran 928 tests of the app plan in 527 s of a 600 s budget, was cut off (exit 124) and the run
ended INCONCLUSIVE, so the job was red on every push to main for a timeout, not a bug.
"""
import importlib.util
import os
from pathlib import Path
import re
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
SCRIPTS = ROOT / 'scripts'


def verify_tests():
    import sys
    sys.path.insert(0, str(SCRIPTS))
    spec = importlib.util.spec_from_file_location('verify_tests_timeout', SCRIPTS / 'verify-tests.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class PlanTimeoutTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.vt = verify_tests()

    def timeout(self, env):
        clean = {k: v for k, v in os.environ.items() if k != self.vt.PLAN_TIMEOUT_ENV}
        with mock.patch.dict(os.environ, {**clean, **env}, clear=True):
            return self.vt.plan_timeout(self.vt.PLANS['app'][2])

    def test_without_the_variable_the_plan_keeps_its_own_budget(self):
        self.assertEqual(self.timeout({}), 600)

    def test_the_variable_sets_the_budget(self):
        self.assertEqual(self.timeout({self.vt.PLAN_TIMEOUT_ENV: '3600'}), 3600)

    def test_a_value_that_is_not_a_positive_whole_number_is_ignored(self):
        for raw in ('', ' ', '0', '-5', '12.5', 'an hour', '3600s'):
            with self.subTest(raw=raw):
                self.assertEqual(self.timeout({self.vt.PLAN_TIMEOUT_ENV: raw}), 600)

    def test_the_step_reads_the_budget_through_plan_timeout(self):
        source = (SCRIPTS / 'verify-tests.py').read_text()
        self.assertRegex(source, r"scheme, name, timeout = PLANS\[plan\]\n\s+timeout = plan_timeout\(timeout\)")


class HostedWorkflowTests(unittest.TestCase):
    TEXT = (ROOT / '.github/workflows/hosted-integration.yml').read_text()

    def test_the_integration_step_gives_the_app_plan_an_hour_inside_the_jobs_own_limit(self):
        self.assertIn("SM_PLAN_TIMEOUT_SECONDS: '3600'", self.TEXT)
        job_minutes = int(re.search(r'timeout-minutes: (\d+)', self.TEXT).group(1))
        self.assertGreater(job_minutes, 60 + 30)  # the plan, plus the build, the boot and the journeys

    def test_only_one_integration_run_holds_a_mac_at_a_time(self):
        # GitHub keeps one running and one pending; a newer pending run replaces the older, so only the latest tip waits.
        self.assertRegex(self.TEXT, r"concurrency:\n  group: hosted-integration\n  cancel-in-progress: false")


if __name__ == '__main__':
    unittest.main()
