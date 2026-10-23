"""hosted_t3_check.py: a hosted T3 passes only when every requested test completed and passed (#2138)."""
import io
import json
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import hosted_t3_check as hosted  # noqa: E402

CLASS = 'SourceLinkImportTests'
TARGET = 'SpokenMarginsAppTests'


def passed(*names):
    return {name: {'status': 'passed', 'seconds': 0.1} for name in names}


class SelectTests(unittest.TestCase):
    def test_a_misspelled_class_is_refused_before_anything_runs(self):
        with self.assertRaisesRegex(RuntimeError, 'Not in the AppBehavior test plan: .*SourceLinkImprtTests'):
            hosted.select('SourceLinkImprtTests', 'AppBehavior')

    def test_a_misspelled_method_is_refused(self):
        with self.assertRaisesRegex(RuntimeError, 'Not in the AppBehavior test plan'):
            hosted.select(f'{CLASS}/testNoSuchThing', 'AppBehavior')

    def test_a_real_class_expects_each_of_its_planned_tests(self):
        selectors, expected = hosted.select(f' {CLASS} ,', 'AppBehavior')
        self.assertEqual(selectors, [f'{TARGET}/{CLASS}'])
        self.assertTrue(expected)
        self.assertTrue(all(test.startswith(f'{TARGET}/{CLASS}/') for test in expected))

    def test_a_method_with_parentheses_selects_that_method(self):
        _, expected = hosted.select(f'{CLASS}', 'AppBehavior')
        method = sorted(expected)[0].rsplit('/', 1)[1]
        selectors, only = hosted.select(f'{CLASS}/{method}()', 'AppBehavior')
        self.assertEqual(only, {f'{TARGET}/{CLASS}/{method}'})
        self.assertEqual(selectors, [f'{TARGET}/{CLASS}/{method}'])

    def test_a_class_the_plan_skips_is_refused(self):
        with self.assertRaisesRegex(RuntimeError, 'Not in the AppBehavior test plan'):
            hosted.select('MediaPlaybackInterruptionTests', 'AppBehavior')

    def test_anything_but_a_name_is_refused(self):
        for text in ('Foo;rm -rf /', 'Foo Bar', '-only-testing:X', 'Foo/bar/baz', '../x'):
            with self.subTest(text=text), self.assertRaisesRegex(ValueError, 'Not a test class'):
                hosted.select(text, 'AppBehavior')

    def test_no_tests_is_t2_only(self):
        self.assertEqual(hosted.select(' , ', 'AppBehavior'), ([], set()))


class CheckTests(unittest.TestCase):
    expected = {'T/A/testOne', 'T/A/testTwo'}

    def test_every_expected_test_passed(self):
        self.assertEqual(hosted.check(self.expected, passed(*self.expected)), [])

    def test_one_passed_one_skipped_fails(self):
        records = passed('T/A/testOne')
        records['T/A/testTwo'] = {'status': 'skipped', 'seconds': 0}
        self.assertEqual(hosted.check(self.expected, records), ['Unexpected skip: T/A/testTwo'])

    def test_a_requested_test_that_never_ran_fails(self):
        errors = hosted.check(self.expected, passed('T/A/testOne'))
        self.assertEqual(len(errors), 1)
        self.assertIn('Missing 1 tests', errors[0])

    def test_nothing_ran_fails(self):
        self.assertIn('No completed tests recorded', hosted.check(self.expected, {}))

    def test_a_failure_fails(self):
        records = passed(*self.expected)
        records['T/A/testOne']['status'] = 'failed'
        self.assertEqual(hosted.check(self.expected, records), ['Failed: T/A/testOne'])

    def test_a_test_outside_the_request_fails(self):
        errors = hosted.check(self.expected, passed(*self.expected, 'T/B/testOther'))
        self.assertIn('Unexpected 1 tests', errors[0])


class CommandLineTests(unittest.TestCase):
    def run_main(self, *argv):
        out = io.StringIO()
        with redirect_stdout(out):
            code = hosted.main(list(argv))
        return code, out.getvalue()

    def test_select_writes_selectors_and_expected(self):
        with tempfile.TemporaryDirectory() as folder:
            code, _ = self.run_main('select', '--tests', CLASS, '--plan', 'AppBehavior', '--out', folder)
            self.assertEqual(code, 0)
            self.assertEqual(Path(folder, 'selectors.txt').read_text(), f'-only-testing:{TARGET}/{CLASS}\n')
            self.assertTrue(json.loads(Path(folder, 'expected.json').read_text()))

    def test_select_reports_a_misspelling_as_an_error(self):
        with tempfile.TemporaryDirectory() as folder:
            code, out = self.run_main('select', '--tests', 'NoSuchTests', '--out', folder)
            self.assertEqual(code, 1)
            self.assertIn('::error::Not in the AppBehavior test plan', out)

    def test_reconcile_without_a_bundle_judges_the_log_and_fails_a_skip(self):
        with tempfile.TemporaryDirectory() as folder:
            expected = Path(folder, 'expected.json')
            expected.write_text(json.dumps(['T/A/testOne', 'T/A/testTwo']))
            log = Path(folder, 'tests.log')
            log.write_text("Test Case '-[T.A testOne]' passed (0.100 seconds).\n"
                           "Test Case '-[T.A testTwo]' skipped (0.001 seconds).\n")
            code, out = self.run_main('reconcile', '--expected', str(expected), '--log', str(log),
                                      '--bundle', str(Path(folder, 'none.xcresult')))
            self.assertEqual(code, 1)
            self.assertIn('1 passed, 0 failed, 1 skipped', out)
            self.assertIn('::error::Unexpected skip: T/A/testTwo', out)


if __name__ == '__main__':
    unittest.main()
