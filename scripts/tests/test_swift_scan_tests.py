"""scripts/swift_scan_tests.py: the Swift source scans the PR quick tier runs (#5220).

#5157 passed its PR checks and was dropped by the merge queue for three scan failures, because the quick tier ran no
runner tests at all. These tests keep the scan list complete and keep the quick tier running it.
"""
import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))

import swift_scan_tests as scans  # noqa: E402

spec = importlib.util.spec_from_file_location('verification_for_scans', SCRIPTS / 'verify-tests.py')
verification = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verification)


class ScanListTests(unittest.TestCase):
    def test_every_test_that_reads_the_swift_tree_is_a_scan_or_left_out_with_a_reason(self):
        found = scans.swift_tree_readers()
        listed = set(scans.SCANS) | set(scans.NOT_SCANS)
        missing = {module: why for module, why in found.items() if module not in listed}
        self.assertEqual(missing, {}, 'add each to SCANS in scripts/swift_scan_tests.py, or to NOT_SCANS with a reason')

    def test_the_lists_name_real_modules_once(self):
        self.assertEqual(len(scans.SCANS), len(set(scans.SCANS)))
        self.assertEqual(set(scans.SCANS) & set(scans.NOT_SCANS), set())
        for module in [*scans.SCANS, *scans.NOT_SCANS]:
            with self.subTest(module):
                self.assertTrue((SCRIPTS / 'tests' / f'{module}.py').is_file())
        for module, reason in scans.NOT_SCANS.items():
            with self.subTest(module):
                self.assertTrue(reason.strip())

    def test_the_named_scans_from_the_issue_are_listed(self):
        for module in ('test_mini_player_keep_out', 'test_outer_tap_frame', 'test_share_export_glyphs',
                       'test_container_identifiers', 'test_test_clock_ceilings'):
            self.assertIn(module, scans.SCANS)

    def test_the_finder_sees_a_new_scan_directly_and_through_a_guard(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / 'tests').mkdir()
            (root / 'tests/test_direct.py').write_text('SOURCES = ROOT / "App" / "Sources"\nFILES = SOURCES.rglob("*.swift")\n')
            (root / 'a_guard.py').write_text('SCAN = ("Packages",)\nGLOB = "*.swift"\n')
            (root / 'tests/test_via_guard.py').write_text('import a_guard\n')
            (root / 'tests/test_plain.py').write_text('import json\n')
            found = scans.swift_tree_readers(root)
        self.assertEqual(found, {'test_direct': ['itself'], 'test_via_guard': ['a_guard']})


class QuickTierTests(unittest.TestCase):
    def test_the_quick_tier_runs_the_scan_list_as_its_runner_tests(self):
        self.assertIn('runner-tests', verification.PR_QUICK_RUNNER_TESTS)
        self.assertEqual(verification.PR_QUICK_RUNNER_TESTS['runner-tests'][-1], 'scripts/swift_scan_tests.py')

    def test_the_runner_prints_the_unittest_summary_the_zero_tests_check_reads(self):
        # verify-tests.py reads "Ran N tests" from the runner-tests log; a run that prints none fails the step.
        self.assertIn('TextTestRunner', (SCRIPTS / 'swift_scan_tests.py').read_text())


if __name__ == '__main__':
    unittest.main()
