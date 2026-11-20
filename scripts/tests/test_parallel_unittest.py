"""scripts/parallel_unittest.py (#4769): runner-tests one module per process, a few at a time."""
import importlib.util
import io
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / 'scripts' / 'parallel_unittest.py'
spec = importlib.util.spec_from_file_location('parallel_unittest', SCRIPT)
parallel = importlib.util.module_from_spec(spec)
spec.loader.exec_module(parallel)


def tree(files):
    temporary = tempfile.TemporaryDirectory()
    tests = Path(temporary.name) / 'scripts' / 'tests'
    tests.mkdir(parents=True)
    for name, body in files.items():
        (tests / name).write_text(body)
    return temporary


def run(cwd, *args):
    return subprocess.run([sys.executable, str(SCRIPT), '--jobs', '3', *args], cwd=cwd, capture_output=True,
                          text=True, timeout=120)


PASSING = 'import unittest\nclass A(unittest.TestCase):\n    def test_one(self): pass\n    def test_two(self): pass\n'


class ParallelUnittestTests(unittest.TestCase):
    def test_every_module_runs_and_the_total_reads_like_unittest(self):
        with tree({'test_a.py': PASSING, 'test_b.py': PASSING, 'test_c.py': PASSING, 'helper.py': 'x = 1\n'}) as cwd:
            done = run(cwd)
        self.assertEqual(done.returncode, 0, done.stdout)
        self.assertRegex(done.stdout, r'(?m)^Ran 6 tests in [0-9.]+s$')
        self.assertRegex(done.stdout, r'(?m)^OK$')
        for name in ('test_a', 'test_b', 'test_c'):
            self.assertIn(f'{name}: 2 tests in ', done.stdout)

    def test_a_failure_fails_the_step_and_prints_unittests_own_block(self):
        failing = 'import unittest\nclass B(unittest.TestCase):\n    def test_bad(self): self.assertEqual(1, 2)\n'
        with tree({'test_a.py': PASSING, 'test_b.py': failing}) as cwd:
            done = run(cwd)
        self.assertEqual(done.returncode, 1)
        self.assertIn('FAIL: test_bad (test_b.B', done.stdout)  # verify-tests.py unittest_failures reads this
        self.assertRegex(done.stdout, r'(?m)^Ran 3 tests in ')
        self.assertIn('FAILED (failures=1, errors=0; modules: test_b)', done.stdout)

    def test_a_module_that_cannot_import_or_dies_fails_the_step(self):
        with tree({'test_a.py': PASSING, 'test_broken.py': 'import no_such_module_here\n',
                   'test_exit.py': 'import os\nos._exit(3)\n'}) as cwd:
            done = run(cwd)
        self.assertEqual(done.returncode, 1)
        self.assertIn('test_broken: 1 tests in', done.stdout)
        self.assertIn('test_exit: no tests in', done.stdout)
        self.assertIn('modules: test_broken, test_exit', done.stdout)

    def test_leave_out_drops_ids_and_skips_whole_modules(self):
        apple = 'import unittest\nclass A(unittest.TestCase):\n    def test_xcode(self): self.fail("xcode")\n'
        other = ('import unittest\nclass B(unittest.TestCase):\n    def test_runs(self): pass\n'
                 '    def test_xcode_too(self): self.fail("xcode")\n')
        with tree({'test_apple.py': apple, 'test_other.py': other}) as cwd:
            done = run(cwd, '--leave-out', 'test_apple.', 'test_other.B.test_xcode_too')
            self.assertEqual(done.returncode, 0, done.stdout)
            self.assertRegex(done.stdout, r'(?m)^Ran 1 test in ')
            self.assertNotIn('test_apple:', done.stdout)  # never started
            failing = run(cwd, '--leave-out', 'test_apple.')
        self.assertEqual(failing.returncode, 1)  # a test that is not listed still fails the step

    def test_no_modules_reports_zero_tests(self):
        with tree({}) as cwd:
            done = run(cwd)
        self.assertRegex(done.stdout, r'(?m)^Ran 0 tests in ')  # verify-tests.py turns this into its zero-tests error

    def test_slowest_first_and_unknown_modules_before_known_ones(self):
        self.assertEqual(parallel.order(['test_a', 'test_b', 'test_new', 'test_c'],
                                        {'test_a': 5.0, 'test_b': 50.0, 'test_c': 1.0}),
                         ['test_new', 'test_b', 'test_a', 'test_c'])

    def test_the_summary_reads_unittests_last_lines(self):
        output = '...\n----\nRan 12 tests in 3.2s\n\nFAILED (failures=2, errors=1, skipped=4)\n'
        self.assertEqual(parallel.summary(output), (12, {'failures': 2, 'errors': 1, 'skipped': 4}))
        self.assertEqual(parallel.summary('Traceback ...\n'), (None, {}))

    def test_the_weights_name_real_modules(self):
        import json
        weights = json.loads((ROOT / 'scripts' / 'runner_test_seconds.json').read_text())['seconds']
        real = set(parallel.modules(ROOT / 'scripts' / 'tests'))
        self.assertLessEqual(len(set(weights) - real), len(weights) // 4,
                             'most entries name modules that are gone: refresh it with --times-out')


if __name__ == '__main__':
    unittest.main()
