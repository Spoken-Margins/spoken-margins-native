"""scripts/queue_guards.py, the list the merge group's first job runs. That `portable` runs every guard too is
test_fast_portable's QueueGuardsRunInPortableToo, beside the portable step table it reads."""
import io
import sys
import unittest
from pathlib import Path
from unittest import mock

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
import queue_guards  # noqa: E402


class GuardListTests(unittest.TestCase):
    def test_every_guard_is_a_test_module_here_once(self):
        self.assertTrue(queue_guards.GUARDS)
        for module in queue_guards.GUARDS:
            self.assertTrue((SCRIPTS / 'tests' / f'{module}.py').is_file(), module)
        self.assertEqual(len(set(queue_guards.GUARDS)), len(queue_guards.GUARDS))

    def test_the_repository_rules_and_every_scan_are_guards(self):
        for module in (*queue_guards.REPO_RULES, *queue_guards.SCANS):
            self.assertIn(module, queue_guards.GUARDS)


class MainTests(unittest.TestCase):
    def run_main(self, ran, passed):
        class Result:
            testsRun = ran

            def wasSuccessful(self):
                return passed
        with mock.patch.object(queue_guards, 'suite', return_value=unittest.TestSuite()), \
                mock.patch.object(queue_guards.unittest, 'TextTestRunner') as runner, \
                mock.patch('sys.stdout', io.StringIO()):
            runner.return_value.run.return_value = Result()
            return queue_guards.main([])

    def test_a_pass_with_tests_is_0_and_a_failure_or_no_tests_is_1(self):
        self.assertEqual(self.run_main(5, True), 0)
        self.assertEqual(self.run_main(5, False), 1)
        self.assertEqual(self.run_main(0, True), 1)

    def test_list_prints_the_modules_and_other_arguments_are_refused(self):
        with mock.patch('sys.stdout', io.StringIO()) as out:
            self.assertEqual(queue_guards.main(['--list']), 0)
        self.assertEqual(out.getvalue().split(), list(queue_guards.GUARDS))
        with mock.patch('sys.stderr', io.StringIO()):
            self.assertEqual(queue_guards.main(['--what']), 2)


if __name__ == '__main__':
    unittest.main()
