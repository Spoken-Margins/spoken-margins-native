"""#3529: SessionKitCoreTests on Linux in the portable job, so a red PR frees its hosted-Mac slot."""
import contextlib
import io
from pathlib import Path
import stat
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import linux_core_tests as core

ROOT = Path(__file__).resolve().parents[2]
PASS = "Test Case 'ASuite.testOne' passed (0.001 seconds)"
FAIL = "Test Case 'ASuite.testOne' failed (0.001 seconds)"


class ReadingResults(unittest.TestCase):
    def test_a_line_per_result_and_the_started_lines_ignored(self):
        text = ("Test Case 'A.testA' started at 2026-11-06\nTest Case 'A.testA' passed (0.1 seconds)\n"
                "sessionkit-core\t2026-11-06T17:43Z Test Case 'B.testB' skipped (0.0 seconds)\n"
                "Test Case 'C.testC' failed (0.0 seconds)\nnoise 'D.testD' passed\n")
        self.assertEqual(core.linux_results(text), {'A/testA': 'passed', 'B/testB': 'skipped', 'C/testC': 'failed'})

    def test_a_repeated_test_keeps_its_worst_result(self):
        for lines, want in ((("Test Case 'A.testA' failed (0 seconds)", "Test Case 'A.testA' passed (0 seconds)"), 'failed'),
                            (("Test Case 'A.testA' passed (0 seconds)", "Test Case 'A.testA' failed (0 seconds)"), 'failed'),
                            (("Test Case 'A.testA' passed (0 seconds)", "Test Case 'A.testA' skipped (0 seconds)"), 'skipped')):
            self.assertEqual(core.linux_results('\n'.join(lines)), {'A/testA': want})

    def test_the_mac_result_file(self):
        xml = ('<testsuites><testsuite>'
               '<testcase classname="SessionKitCoreTests.A" name="testA()" time="0.1"></testcase>'
               '<testcase classname="SessionKitCoreTests.A" name="testB" time="0.1"><failure message="x"></failure></testcase>'
               '<testcase classname="SessionKitCoreTests.A" name="testC" time="0.1"><skipped></skipped></testcase>'
               '<testcase classname="" name="testD" time="0"></testcase>'
               '<testcase classname="SessionKitCoreTests.A" name="helper" time="0"></testcase>'
               '</testsuite></testsuites>')
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / 'x.xml'
            path.write_text(xml)
            self.assertEqual(core.mac_results(path), {'A/testA': 'passed', 'A/testB': 'failed', 'A/testC': 'skipped'})


class RunningThem(unittest.TestCase):
    """Real processes and real files: a shell script stands in for the docker command and changes as it is run."""

    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.dir = Path(temporary.name)
        self.log = self.dir / 'logs/linux-core.log'
        self.resolved = self.dir / 'Package.resolved'
        self.resolved.write_text('the Mac copy')
        self.summary = self.dir / 'summary.md'

    def script(self, *attempts):
        """A command that does attempts[n] on its nth run, and rewrites Package.resolved each time, as SwiftPM does."""
        for number, body in enumerate(attempts):
            (self.dir / f'attempt{number}.sh').write_text(body)
        runner = self.dir / 'runner.sh'
        runner.write_text(f'#!/bin/sh\ncd {self.dir}\nn=$(cat count 2>/dev/null || echo 0)\necho $((n + 1)) > count\n'
                          f'echo rewritten > Package.resolved\n. ./attempt$n.sh\n')
        runner.chmod(runner.stat().st_mode | stat.S_IEXEC)
        return [str(runner)]

    def run_it(self, *attempts):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = core.run_tests(self.script(*attempts), self.log, self.resolved,
                                  environ={'GITHUB_STEP_SUMMARY': str(self.summary)})
        return code, out.getvalue()

    def attempts_made(self):
        return int((self.dir / 'count').read_text())

    def test_a_pass_runs_once_and_says_no_retry(self):
        code, out = self.run_it(f'echo "{PASS}"; exit 0')
        self.assertEqual((code, self.attempts_made()), (0, 1))
        self.assertNotIn('passed on retry', out)
        self.assertEqual(core.linux_results(self.log.read_text()), {'ASuite/testOne': 'passed'})

    def test_a_red_test_fails_after_its_one_rerun_and_is_named(self):
        code, out = self.run_it(f'echo "{FAIL}"; exit 1', f'echo "{FAIL}"; exit 1')
        self.assertEqual((code, self.attempts_made()), (1, 2))
        self.assertIn('Failed: SessionKitCoreTests/ASuite/testOne', out)
        self.assertNotIn('passed on retry', out)

    def test_a_test_that_passes_on_its_rerun_counts_as_a_pass_and_the_run_names_it(self):
        code, out = self.run_it(f'echo "{FAIL}"; exit 1', f'echo "{PASS}"; exit 0')
        self.assertEqual((code, self.attempts_made()), (0, 2))
        self.assertIn('passed on retry: SessionKitCoreTests/ASuite/testOne', out)
        self.assertIn('::warning title=linux-core-retry::', out)
        self.assertIn('passed on retry: SessionKitCoreTests/ASuite/testOne', self.summary.read_text())
        self.assertEqual(core.linux_results(self.log.read_text()), {'ASuite/testOne': 'passed'})
        self.assertEqual(core.linux_results(self.log.with_name('first-linux-core.log').read_text()),
                         {'ASuite/testOne': 'failed'})

    def test_a_crash_with_no_failed_test_reruns_and_says_it_stopped(self):
        code, out = self.run_it(f'echo "{PASS}"; exit 139', f'echo "{PASS}"; exit 0')
        self.assertEqual((code, self.attempts_made()), (0, 2))
        self.assertIn('the first run stopped with exit 139 after 1 tests', out)

    def test_a_build_failure_does_not_rerun(self):
        code, out = self.run_it('echo "error: no such module"; exit 1', f'echo "{PASS}"; exit 0')
        self.assertEqual((code, self.attempts_made()), (1, 1))
        self.assertIn('ran no tests', out)

    def test_a_clean_exit_with_no_tests_is_a_failure_not_a_pass(self):
        code, out = self.run_it('echo "Build complete"; exit 0')
        self.assertEqual((code, self.attempts_made()), (1, 1))
        self.assertIn('ran no tests', out)

    def test_a_rerun_that_runs_no_tests_is_a_failure(self):
        code, _ = self.run_it(f'echo "{FAIL}"; exit 1', 'echo "Build complete"; exit 0')
        self.assertEqual(code, 1)

    def test_the_macs_package_resolved_comes_back_whatever_happened(self):
        for attempts in ((f'echo "{PASS}"; exit 0',), (f'echo "{FAIL}"; exit 1', f'echo "{FAIL}"; exit 1'), ('exit 2',)):
            with self.subTest(attempts=attempts):
                (self.dir / 'count').unlink(missing_ok=True)
                self.run_it(*attempts)
                self.assertEqual(self.resolved.read_text(), 'the Mac copy')


class TheReport(unittest.TestCase):
    def test_it_names_every_test_on_only_one_side(self):
        linux = {'A/testBoth': 'passed', 'A/testLinux': 'passed', 'A/testSkipped': 'skipped', 'A/testRed': 'failed'}
        mac = {'A/testBoth': 'passed', 'A/testMac': 'passed', 'A/testSkipped': 'passed', 'A/testRed': 'passed'}
        text = core.report(linux, mac)
        self.assertIn('Only on Linux (1):\nA/testLinux\n', text)
        self.assertIn('Only on the Mac (1):\nA/testMac\n', text)
        self.assertIn('Skipped on Linux, listed on the Mac (1):\nA/testSkipped\n', text)
        self.assertIn('Failed on one side only (1):\nA/testRed\n', text)
        self.assertIn('A/testMac\t-\tpassed\n', text)
        self.assertIn('A/testLinux\tpassed\t-\n', text)
        self.assertIn('A/testBoth\tpassed\tpassed\n', text)

    def test_the_cli_writes_the_file_and_refuses_an_empty_side(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            (base / 'linux.log').write_text(PASS + '\n')
            (base / 'mac.xml').write_text('<testsuites><testsuite><testcase classname="M.ASuite" name="testOne"/>'
                                          '</testsuite></testsuites>')
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(core.main(['compare', '--linux', str(base / 'linux.log'), '--mac', str(base / 'mac.xml'),
                                            '--out', str(base / 'report.txt')]), 0)
            self.assertIn('Only on Linux (0):', (base / 'report.txt').read_text())
            (base / 'empty.log').write_text('nothing\n')
            with contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(core.main(['compare', '--linux', str(base / 'empty.log'), '--mac', str(base / 'mac.xml'),
                                            '--out', str(base / 'none.txt')]), 1)
            self.assertFalse((base / 'none.txt').exists())


class TheWorkflow(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        import yaml
        cls.yaml = yaml
        cls.jobs = yaml.safe_load((ROOT / '.github/workflows/hosted-portable.yml').read_text())['jobs']

    def steps(self, job):
        return self.jobs[job]['steps']

    def runs(self, job):
        return [step.get('run', '') for step in self.steps(job)]

    def test_the_portable_job_runs_the_tests_where_a_red_one_fails_the_check_it_records(self):
        runs = self.runs('portable')
        tests = next(i for i, run in enumerate(runs) if 'scripts/linux_core_tests.py run' in run)
        record = next(i for i, run in enumerate(runs) if 'title=lane-hosted-tested' in run)
        self.assertLess(tests, record)
        self.assertNotIn('if', self.steps('portable')[tests])
        self.assertNotIn('continue-on-error', self.steps('portable')[tests])
        self.assertFalse(any('swift build --build-tests' in run for run in runs), 'swift test builds them')

    def test_a_red_portable_job_stops_the_macs(self):
        self.assertEqual(self.jobs['stop-macs-on-red']['needs'], 'portable')
        self.assertIn("needs.portable.result == 'failure'", self.jobs['stop-macs-on-red']['if'])

    def test_the_mac_keeps_its_own_run_and_both_lists_are_kept(self):
        self.assertTrue(any('--plan fast-hosted-sessionkit' in run for run in self.runs('mac-rest')))
        for job, name, path in (('portable', 'linux-core-tests', 'artifacts/test-runs/linux-core/'),
                                ('mac-rest', 'mac-core-tests', 'artifacts/test-runs/*/package-core.xunit.xml')):
            step = next(s for s in self.steps(job) if s.get('with', {}).get('name') == name)
            self.assertEqual(step['if'], 'always()')
            self.assertEqual(step['with']['path'], path)

    def test_every_copy_of_the_swift_image_agrees(self):
        self.assertIn(f'sessionkit-linux-swift{core.IMAGE.partition(":")[2]}-', str(self.steps('portable')))
        by_hand = self.yaml.safe_load((ROOT / '.github/workflows/hosted-sessionkit-linux.yml').read_text())
        self.assertEqual(by_hand['jobs']['sessionkit-core']['container'], core.IMAGE)

    def test_the_command_mounts_the_checkout_and_tests_with_the_cached_build_folder(self):
        command = core.docker_command(Path('/here'))
        self.assertEqual(command[:7], ['docker', 'run', '--rm', '-v', '/here:/w', '-w', '/w/Packages/SessionKit'])
        self.assertIn(core.IMAGE, command)
        self.assertIn('swift test --scratch-path /w/.build-linux', command[-1])
        self.assertIn(f'path: {core.SCRATCH}\n', (ROOT / '.github/workflows/hosted-portable.yml').read_text())


if __name__ == '__main__':
    unittest.main()
