"""#3529: SessionKitCoreTests on Linux in the portable job, so a red PR frees its hosted-Mac slot."""
import contextlib
import io
import re
from pathlib import Path
import stat
import subprocess
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


class ScriptedRuns(unittest.TestCase):
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
        self.output = self.dir / 'output.txt'
        with contextlib.redirect_stdout(out):
            code = core.run_tests(self.script(*attempts), self.log, self.resolved,
                                  environ={'GITHUB_STEP_SUMMARY': str(self.summary), 'GITHUB_OUTPUT': str(self.output)})
        return code, out.getvalue()

    def retried_output(self):
        """What the step hands the tally job (#2176), or None when it hands nothing."""
        lines = self.output.read_text().splitlines() if self.output.exists() else []
        return next((line.partition('=')[2] for line in lines if line.startswith('retried=')), None)

    def attempts_made(self):
        return int((self.dir / 'count').read_text())


class RunningThem(ScriptedRuns):
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
        self.assertEqual(self.retried_output(), 'SessionKitCoreTests/ASuite/testOne')

    def test_a_pass_or_a_red_run_hands_the_tally_nothing(self):
        for attempts in ((f'echo "{PASS}"; exit 0',), (f'echo "{FAIL}"; exit 1', f'echo "{FAIL}"; exit 1')):
            with self.subTest(attempts=attempts):
                (self.dir / 'count').unlink(missing_ok=True)
                (self.dir / 'output.txt').unlink(missing_ok=True)
                self.run_it(*attempts)
                self.assertIsNone(self.retried_output())

    def test_a_crash_with_no_failed_test_reruns_and_says_it_stopped(self):
        code, out = self.run_it(f'echo "{PASS}"; exit 139', f'echo "{PASS}"; exit 0')
        self.assertEqual((code, self.attempts_made()), (0, 2))
        self.assertIn('the first run stopped with exit 139 after 1 tests', out)
        self.assertEqual(self.retried_output(), 'SessionKitCoreTests')

    def test_a_crash_inside_the_very_first_test_reruns_and_names_that_test(self):
        started = "Test Case 'ASuite.testOne' started at 2026-11-07 13:00:00.000"
        code, out = self.run_it(f'echo "{started}"; exit 139', f'echo "{PASS}"; exit 0')
        self.assertEqual((code, self.attempts_made()), (0, 2))
        self.assertNotIn('ran no tests', out)
        self.assertIn('Stopped in: SessionKitCoreTests/ASuite/testOne', out)
        self.assertIn('passed on retry: SessionKitCoreTests/ASuite/testOne', out)
        self.assertEqual(self.retried_output(), 'SessionKitCoreTests/ASuite/testOne')

    def test_a_crash_in_a_later_test_names_both_the_red_one_and_the_one_it_stopped_in(self):
        started = "Test Case 'BSuite.testTwo' started at 2026-11-07 13:00:00.000"
        code, out = self.run_it(f'echo "{FAIL}"; echo "{started}"; exit 139', f'echo "{PASS}"; exit 0')
        self.assertEqual(code, 0)
        self.assertEqual(self.retried_output(), 'SessionKitCoreTests/ASuite/testOne,SessionKitCoreTests/BSuite/testTwo')

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


APT_DOWN = ("W: Failed to fetch http://archive.ubuntu.com/ubuntu/dists/noble/InRelease  "
            "Could not resolve 'archive.ubuntu.com'\\nE: Unable to locate package libsqlite3-dev")


class WhenTheContainerCannotReachApt(ScriptedRuns):
    """#4082: the image's SQLite headers come from apt, and a runner whose container has no DNS must not turn that
    into a red check about the PR's code."""

    def run_staged(self, staged_ok, *attempts):
        calls = []
        self.output = self.dir / 'output.txt'
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = core.run_tests(self.script(*attempts), self.log, self.resolved,
                                  environ={'GITHUB_OUTPUT': str(self.output)},
                                  stage=lambda: calls.append(1) or staged_ok)
        return code, out.getvalue(), len(calls)

    def test_apts_own_errors_are_a_setup_fault_not_a_build_failure(self):
        code, out, staged = self.run_staged(False, f'echo "{APT_DOWN}"; exit 100')
        self.assertEqual((code, self.attempts_made(), staged), (core.SETUP_FAULT_CODE, 1, 1))
        self.assertNotIn('ran no tests', out)
        self.assertNotIn('Failed:', out)
        self.assertIn('::error title=lane-fault::', out)
        self.assertIn('not this PR', out)

    def test_the_scripts_own_marker_and_exit_code_count_too(self):
        for body in (f'echo "{core.SETUP_FAULT_MARK} (three tries)"; exit 75', 'exit 75'):
            with self.subTest(body=body):
                (self.dir / 'count').unlink(missing_ok=True)
                code, out, _ = self.run_staged(False, body)
                self.assertEqual(code, core.SETUP_FAULT_CODE)
                self.assertIn('lane-fault', out)

    def test_the_hosts_debs_are_tried_and_the_tests_then_run_as_usual(self):
        code, out, staged = self.run_staged(True, f'echo "{APT_DOWN}"; exit 100', f'echo "{PASS}"; exit 0')
        self.assertEqual((code, self.attempts_made(), staged), (0, 2, 1))
        self.assertNotIn('lane-fault', out)
        self.assertIsNone(self.retried_output())  # a setup retry is not a test that passed on its rerun

    def test_a_red_test_after_the_hosts_debs_is_still_red(self):
        code, _, _ = self.run_staged(True, f'echo "{APT_DOWN}"; exit 100', f'echo "{FAIL}"; exit 1', f'echo "{FAIL}"; exit 1')
        self.assertEqual((code, self.attempts_made()), (1, 3))

    def test_the_hosts_debs_failing_too_is_still_a_setup_fault(self):
        code, out, staged = self.run_staged(True, f'echo "{APT_DOWN}"; exit 100', f'echo "{core.SETUP_FAULT_MARK}"; exit 75')
        self.assertEqual((code, self.attempts_made(), staged), (core.SETUP_FAULT_CODE, 2, 1))
        self.assertIn('lane-fault', out)

    def test_a_tests_own_output_that_mentions_the_network_is_not_a_setup_fault(self):
        text = f"{PASS}\nCould not resolve 'example.invalid'\n"
        self.assertFalse(core.setup_fault(1, text))
        self.assertFalse(core.setup_fault(75, text))
        self.assertTrue(core.setup_fault(100, "Could not resolve 'archive.ubuntu.com'"))
        self.assertFalse(core.setup_fault(1, 'error: no such module'))


class TheInstallScript(unittest.TestCase):
    """The shell itself, run for real with apt-get, dpkg and sleep replaced by scripts that count their calls."""

    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.dir = Path(temporary.name)
        self.bin = self.dir / 'bin'
        self.bin.mkdir()
        self.mount = self.dir / 'w'
        self.mount.mkdir()

    def fake(self, name, body):
        path = self.bin / name
        path.write_text(f'#!/bin/sh\necho {name} >> {self.dir}/calls\n{body}\n')
        path.chmod(path.stat().st_mode | stat.S_IEXEC)

    def install(self):
        env = {'PATH': f'{self.bin}:/usr/bin:/bin'}
        done = subprocess.run(['bash', '-c', core.install_script(str(self.mount))], env=env, text=True,
                              capture_output=True)
        calls = (self.dir / 'calls').read_text().split() if (self.dir / 'calls').exists() else []
        return done.returncode, done.stdout, calls

    def test_a_working_apt_runs_once_and_does_not_wait(self):
        self.fake('apt-get', 'exit 0')
        self.fake('sleep', 'exit 0')
        self.assertEqual(self.install(), (0, '', ['apt-get', 'apt-get']))

    def test_apt_that_fails_twice_and_then_works_gets_its_third_try(self):
        self.fake('apt-get', f'n=$(cat {self.dir}/n 2>/dev/null || echo 0); echo $((n + 1)) > {self.dir}/n; '
                             '[ "$1" = update ] && [ $n -lt 2 ] && exit 100; exit 0')
        self.fake('sleep', 'exit 0')
        code, _, calls = self.install()
        self.assertEqual(code, 0)
        self.assertEqual(calls.count('sleep'), 2)

    def test_apt_that_never_works_ends_in_the_setup_fault_after_three_tries(self):
        self.fake('apt-get', 'echo "Could not resolve archive.ubuntu.com" >&2; exit 100')
        self.fake('sleep', 'exit 0')
        code, out, calls = self.install()
        self.assertEqual(code, core.SETUP_FAULT_CODE)
        self.assertIn(core.SETUP_FAULT_MARK, out)
        self.assertEqual((calls.count('apt-get'), calls.count('sleep')), (3, 2))

    def test_staged_debs_are_installed_and_apt_is_never_asked(self):
        (self.mount / core.STAGED).mkdir()
        (self.mount / core.STAGED / 'libsqlite3-dev.deb').write_text('x')
        self.fake('apt-get', 'exit 100')
        self.fake('dpkg', 'exit 0')
        self.assertEqual(self.install(), (0, '', ['dpkg']))

    def test_staged_debs_that_will_not_install_are_a_setup_fault(self):
        (self.mount / core.STAGED).mkdir()
        (self.mount / core.STAGED / 'libsqlite3-dev.deb').write_text('x')
        self.fake('dpkg', 'exit 1')
        code, out, _ = self.install()
        self.assertEqual(code, core.SETUP_FAULT_CODE)
        self.assertIn(core.SETUP_FAULT_MARK, out)


class StagingTheDebs(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.dir = Path(temporary.name) / 'staged'

    def fake_run(self, debs, code=0):
        calls = []

        def run(command, cwd=None, check=True):
            calls.append(command)
            if 'download' in command:
                for name in debs:
                    (Path(cwd) / name).write_text('x')
            return subprocess.CompletedProcess(command, code if 'download' in command else 0)
        return run, calls

    def stage(self, run, which=lambda name: '/usr/bin/apt-get'):
        with contextlib.redirect_stdout(io.StringIO()):
            return core.stage_debs(self.dir, run=run, which=which)

    def test_both_packages_are_downloaded_on_the_host(self):
        run, calls = self.fake_run(['a.deb', 'b.deb'])
        self.assertTrue(self.stage(run))
        download = next(call for call in calls if 'download' in call)
        self.assertEqual(download[-2:], ['libsqlite3-dev', 'libsqlite3-0'])

    def test_a_failed_or_partial_download_is_not_staged(self):
        for debs, code in ((['a.deb', 'b.deb'], 100), (['a.deb'], 0), ([], 0)):
            with self.subTest(debs=debs, code=code):
                run, _ = self.fake_run(debs, code)
                self.assertFalse(self.stage(run))

    def test_a_host_with_no_apt_stages_nothing_and_does_not_try(self):
        run, calls = self.fake_run(['a.deb', 'b.deb'])
        self.assertFalse(self.stage(run, which=lambda name: None))
        self.assertEqual(calls, [])

    def test_an_old_staging_folder_is_cleared_first(self):
        self.dir.mkdir()
        (self.dir / 'old.deb').write_text('x')
        run, _ = self.fake_run(['a.deb', 'b.deb'])
        self.assertTrue(self.stage(run))
        self.assertEqual(sorted(path.name for path in self.dir.iterdir()), ['a.deb', 'b.deb'])


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

    def test_a_linux_retry_pass_reaches_the_tally_job_from_the_step_that_names_it(self):
        step = next(s for s in self.steps('portable') if 'scripts/linux_core_tests.py run' in s.get('run', ''))
        self.assertEqual(self.jobs['portable']['outputs']['retried'], f"${{{{ steps.{step['id']}.outputs.retried }}}}")
        job = self.jobs['linux-retry-tally']
        self.assertEqual(job['needs'], 'portable')
        self.assertIn("needs.portable.result == 'success'", job['if'])
        self.assertIn("needs.portable.outputs.retried != ''", job['if'])
        run = next(s for s in job['steps'] if 'linux_core_tally.py' in s.get('run', ''))
        self.assertEqual(run['env']['RETRIED'], '${{ needs.portable.outputs.retried }}')
        self.assertNotIn('${{', run['run'], 'the names arrive through env, never pasted into the script')
        self.assertIn('linux-retry-tally', self.jobs['owner-tap-alert']['needs'])

    def test_the_tally_job_runs_the_bases_scripts_with_a_token_that_writes_issues_only(self):
        job = self.jobs['linux-retry-tally']
        self.assertEqual(job['permissions'], {'contents': 'read', 'issues': 'write'})
        checkout = job['steps'][0]
        self.assertTrue(checkout['uses'].startswith('actions/checkout@'))
        self.assertIn('github.event.pull_request.base.sha', checkout['with']['ref'])
        self.assertIs(checkout['with']['persist-credentials'], False)
        sparse = set(checkout['with']['sparse-checkout'].split())
        # Every module the script imports from scripts/, all the way down, is in the sparse checkout.
        wanted, seen = ['linux_core_tally'], set()
        while wanted:
            module = wanted.pop()
            if module in seen:
                continue
            seen.add(module)
            for name in re.findall(r'^import (\w+)', (ROOT / 'scripts' / f'{module}.py').read_text(), re.M):
                if (ROOT / 'scripts' / f'{name}.py').exists():
                    wanted.append(name)
        self.assertEqual(sparse, {f'scripts/{module}.py' for module in seen})

    def test_every_copy_of_the_swift_image_agrees(self):
        self.assertIn(f'sessionkit-linux-swift{core.IMAGE.partition(":")[2]}-', str(self.steps('portable')))
        by_hand = self.yaml.safe_load((ROOT / '.github/workflows/hosted-sessionkit-linux.yml').read_text())
        self.assertEqual(by_hand['jobs']['sessionkit-core']['container'], core.IMAGE)

    def test_the_other_swift_container_jobs_retry_apt_too(self):
        for name in ('hosted-sessionkit-linux.yml', 'substack-canary.yml'):
            with self.subTest(workflow=name):
                text = (ROOT / '.github/workflows' / name).read_text()
                self.assertIn('for n in 1 2 3; do', text)
                self.assertNotIn('run: apt-get update -qq && apt-get install', text)

    def test_the_command_mounts_the_checkout_and_tests_with_the_cached_build_folder(self):
        command = core.docker_command(Path('/here'))
        self.assertEqual(command[:7], ['docker', 'run', '--rm', '-v', '/here:/w', '-w', '/w/Packages/SessionKit'])
        self.assertIn(core.IMAGE, command)
        self.assertIn('swift test --scratch-path /w/.build-linux', command[-1])
        self.assertIn(f'path: {core.SCRATCH}\n', (ROOT / '.github/workflows/hosted-portable.yml').read_text())


if __name__ == '__main__':
    unittest.main()
