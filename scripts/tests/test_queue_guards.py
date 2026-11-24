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
    def run_main(self, results):
        with mock.patch.object(queue_guards.parallel_unittest, 'run_all', return_value=results) as run_all, \
                mock.patch('sys.stdout', io.StringIO()):
            return queue_guards.main([]), run_all

    @staticmethod
    def every(ran=3, ok=True):
        return {module: {'ran': ran, 'ok': ok} for module in queue_guards.GUARDS}

    def test_each_guard_runs_in_its_own_process_as_portable_runs_it(self):
        # One process for all of them could fail on state an earlier module left, where `portable` (one module per
        # process, parallel_unittest.py) passes, and cancel a sound group (audit on 089d17c).
        code, run_all = self.run_main(self.every())
        self.assertEqual(code, 0)
        args, kwargs = run_all.call_args
        self.assertEqual(sorted(args[0]), sorted(queue_guards.GUARDS))
        self.assertEqual(Path(kwargs['cwd']), SCRIPTS.parent, 'the module loader finds scripts/tests from the root')
        self.assertEqual(tuple(kwargs.get('left_out', ())), ())

    def test_a_failed_missing_or_empty_module_is_1(self):
        failed = self.every()
        failed[queue_guards.GUARDS[0]]['ok'] = False
        self.assertEqual(self.run_main(failed)[0], 1)
        missing = self.every()
        missing.pop(queue_guards.GUARDS[-1])
        self.assertEqual(self.run_main(missing)[0], 1)
        self.assertEqual(self.run_main(self.every(ran=0))[0], 1)

    def test_list_prints_the_modules_and_other_arguments_are_refused(self):
        with mock.patch('sys.stdout', io.StringIO()) as out:
            self.assertEqual(queue_guards.main(['--list']), 0)
        self.assertEqual(out.getvalue().split(), list(queue_guards.GUARDS))
        with mock.patch('sys.stderr', io.StringIO()):
            self.assertEqual(queue_guards.main(['--what']), 2)


if __name__ == '__main__':
    unittest.main()
