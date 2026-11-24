"""scripts/swift_scan_tests.py: the Swift source scans the PR quick tier runs (#5220).

#5157 passed its PR checks and was dropped by the merge queue for three scan failures, because the quick tier ran no
runner tests at all. These tests keep the scan list complete and keep the quick tier running it.
"""
import importlib.util
import subprocess
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
    def test_the_lanes_readers_scope_runs_every_scan(self):
        self.assertEqual(set(scans.SCANS) - {r.split('.')[0] for r in verification.RUNNER_TEST_READERS}, set())

    def test_no_scan_is_one_the_quick_tier_cannot_run(self):
        # The quick tier passes no leave-out: a scan that drives an Apple tool or sits in the slow tier would run anyway.
        apple = {prefix.split('.')[0] for prefix in verification.PORTABLE_RUNNER_TESTS_LEFT_OUT}
        slow = {module.split('.')[0] for module in verification.slow_tier.SLOW_RUNNER_MODULES}
        self.assertEqual(set(scans.SCANS) & (apple | slow), set())

    def test_the_quick_tier_runs_the_scan_list_under_its_own_step_name(self):
        # Its own name keeps its timings out of runner-tests' limit in ci_step_budgets.py (audit on 41340ba).
        self.assertEqual(verification.PR_QUICK_STEPS, ('swift-scans',))
        self.assertEqual(verification.SWIFT_SCANS_COMMAND[-1], 'scripts/swift_scan_tests.py')
        budgets = (SCRIPTS / 'ci_step_budgets.py').read_text()
        self.assertNotIn("'swift-scans'", budgets)


def git(root, *args):
    return subprocess.run(['git', '-C', str(root), *args], capture_output=True, text=True, check=True).stdout.strip()


class MergeCommitChangesTests(unittest.TestCase):
    def repo(self, temporary):
        root = Path(temporary) / 'repo'
        root.mkdir()
        git(root, 'init', '-q', '-b', 'main')
        git(root, 'config', 'user.email', 't@example.com')
        git(root, 'config', 'user.name', 't')
        (root / 'README.md').write_text('base\n')
        git(root, 'add', '-A')
        git(root, 'commit', '-qm', 'base')
        return root

    def test_a_merge_commit_gives_what_its_second_parent_brings(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = self.repo(temporary)
            git(root, 'switch', '-q', '-c', 'pr')
            (root / 'App').mkdir()
            (root / 'App/X.swift').write_text('let x = 1\n')
            git(root, 'add', '-A')
            git(root, 'commit', '-qm', 'pr')
            git(root, 'switch', '-q', 'main')
            (root / 'docs.md').write_text('main moved\n')
            git(root, 'add', '-A')
            git(root, 'commit', '-qm', 'main')
            git(root, 'merge', '-q', '--no-ff', '--no-edit', 'pr')
            self.assertEqual(verification.merge_commit_changes(root), ['App/X.swift'])

    def test_a_plain_commit_or_a_missing_base_gives_none_so_everything_runs(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = self.repo(temporary)
            self.assertIsNone(verification.merge_commit_changes(root))
            self.assertIsNone(verification.merge_commit_changes(Path(temporary) / 'not-a-repo'))

    def test_a_shallow_checkout_fetches_the_base_then_diffs(self):
        with tempfile.TemporaryDirectory() as temporary:
            origin = self.repo(temporary)
            git(origin, 'switch', '-q', '-c', 'pr')
            (origin / 'notes.md').write_text('pr\n')
            git(origin, 'add', '-A')
            git(origin, 'commit', '-qm', 'pr')
            git(origin, 'switch', '-q', 'main')
            git(origin, 'merge', '-q', '--no-ff', '--no-edit', 'pr')
            git(origin, 'config', 'uploadpack.allowAnySHA1InWant', 'true')
            clone = Path(temporary) / 'clone'
            subprocess.run(['git', 'clone', '-q', '--depth=1', f'file://{origin}', str(clone)], check=True)
            self.assertEqual(verification.merge_commit_changes(clone), ['notes.md'])


    def test_the_runner_prints_the_unittest_summary_the_zero_tests_check_reads(self):
        # verify-tests.py reads "Ran N tests" from the runner-tests log; a run that prints none fails the step.
        self.assertIn('TextTestRunner', (SCRIPTS / 'swift_scan_tests.py').read_text())


if __name__ == '__main__':
    unittest.main()
