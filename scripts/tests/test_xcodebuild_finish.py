"""#2053: an `xcodebuild test` that prints its summary and then hangs must not hold a build slot forever.

The wrapper and verify-tests.py run against fake xcodebuilds: one that reports its tests and then sleeps, the shape
the Test Desk met twice on 2026-10-18 (1 test passed in 55 s, then 4 minutes of nothing until killed by hand).
"""
import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
import unittest.mock

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
import xcodebuild_finish  # noqa: E402

SUMMARY = '''Test Case '-[SpokenMarginsAppUITests.J1 testStep]' passed (55.0 seconds).
Test Suite 'J1' passed at 2026-10-18 14:00:00.000.
\t Executed 1 test, with {failures} failures (0 unexpected) in 55.0 (55.0) seconds
Test Suite 'SpokenMarginsAppUITests.xctest' passed at 2026-10-18 14:00:00.000.
\t Executed 1 test, with {failures} failures (0 unexpected) in 55.0 (55.0) seconds
Test Suite 'Selected tests' {verdict} at 2026-10-18 14:00:00.001.
\t Executed 1 test, with {failures} failures (0 unexpected) in 55.0 (55.1) seconds
'''

# Prints the summary, then hangs. FAKE_IGNORE_INT makes it shrug off SIGINT, FAKE_GRANDCHILD leaves a
# descendant holding its output and exits at once, FAKE_INNER_ONLY prints only a class summary, pauses and exits.
FAKE_XCODEBUILD = f'''#!/usr/bin/env python3
import os, signal, subprocess, sys, time
summary = {SUMMARY!r}
failures = os.environ.get("FAKE_FAILURES", "0")
if os.environ.get("FAKE_IGNORE_INT"):
    signal.signal(signal.SIGINT, signal.SIG_IGN)
with open(os.environ["FAKE_PIDS"], "a") as handle:
    handle.write(str(os.getpid()) + "\\n")
if os.environ.get("FAKE_INNER_ONLY"):
    print("Test Suite 'J1' passed at 2026-10-18 14:00:00.000.")
    print("\\t Executed 1 test, with 0 failures (0 unexpected) in 1.0 (1.0) seconds", flush=True)
    time.sleep(float(os.environ["FAKE_INNER_ONLY"]))
    print("finished on its own", flush=True)
    sys.exit(0)
sys.stdout.write(summary.format(failures=failures, verdict="failed" if failures != "0" else "passed"))
sys.stdout.flush()
if os.environ.get("FAKE_GRANDCHILD"):
    child = subprocess.Popen(["sleep", "300"])
    with open(os.environ["FAKE_PIDS"], "a") as handle:
        handle.write(str(child.pid) + "\\n")
    sys.exit(0)
time.sleep(300)
'''


def alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    # A zombie still answers kill(0); ps says whether it has really gone.
    state = subprocess.run(['ps', '-o', 'stat=', '-p', str(pid)], capture_output=True, text=True).stdout.strip()
    return bool(state) and not state.startswith('Z')


class Fakes(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.dir = Path(self.temporary.name)
        self.bin = self.dir / 'bin'
        self.bin.mkdir()
        fake = self.bin / 'xcodebuild'
        fake.write_text(FAKE_XCODEBUILD)
        fake.chmod(0o755)
        self.pids = self.dir / 'pids'
        self.env = {**os.environ, 'SM_LANE_STATE_DIR': str(self.dir / 'state'), 'SM_LANE_XCODEBUILD': str(fake),
                    'FAKE_PIDS': str(self.pids), 'SM_TEST_FINISH_GRACE_SECONDS': '1'}

    def tearDown(self):
        # Never leave a fake behind, whatever the test did.
        for pid in self.fake_pids():
            try:
                os.kill(pid, 9)
            except ProcessLookupError:
                pass
        self.temporary.cleanup()

    def fake_pids(self):
        return [int(p) for p in self.pids.read_text().split()] if self.pids.exists() else []


# The Test Desk's own shape: one test in one bundle, so its summary is the whole run's.
ONE = '-only-testing:SpokenMarginsAppUITests/J1/testStep'


class WrapperTests(Fakes):
    def wrapper(self, *args, **extra):
        started = time.monotonic()
        result = subprocess.run([sys.executable, str(SCRIPTS / 'xcodebuild-lane'), '-scheme', 'S', *args],
                                cwd=SCRIPTS.parent, env={**self.env, **extra}, capture_output=True, text=True,
                                timeout=90)
        return result, time.monotonic() - started

    def test_a_passing_run_that_hangs_after_its_summary_is_stopped_and_passes(self):
        result, seconds = self.wrapper(ONE, 'test')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertLess(seconds, 45)
        self.assertIn('Executed 1 test, with 0 failures', result.stdout)  # output still reaches the caller
        self.assertIn('stopped it (forced, #2053)', result.stderr)
        self.assertIn('(1 tests, passed)', result.stderr)
        self.assertFalse(any(alive(pid) for pid in self.fake_pids()))

    def test_a_failing_run_that_hangs_returns_the_failure(self):
        result, _ = self.wrapper('test-without-building', FAKE_FAILURES='2')
        self.assertEqual(result.returncode, 65, result.stderr)
        self.assertIn('forced', result.stderr)

    def test_a_run_that_ignores_sigint_is_still_stopped(self):
        result, seconds = self.wrapper(ONE, 'test', FAKE_IGNORE_INT='1')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(any(alive(pid) for pid in self.fake_pids()))

    def test_the_slot_is_free_for_the_next_build_afterwards(self):
        self.wrapper('test')
        sys.path.insert(0, str(SCRIPTS))
        import lane_slots
        with unittest.mock.patch.dict(os.environ, {'SM_LANE_STATE_DIR': self.env['SM_LANE_STATE_DIR']}):
            with open(os.devnull, 'w') as quiet, lane_slots.build_slot('next', out=quiet, max_wait=2) as held:
                self.assertEqual(held['waited_seconds'], 0)

    def test_a_descendant_holding_the_output_does_not_hold_the_wrapper(self):
        result, seconds = self.wrapper(ONE, 'test', FAKE_GRANDCHILD='1')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertLess(seconds, 30)
        self.assertIn('still held its output', result.stderr)
        self.assertFalse(any(alive(pid) for pid in self.fake_pids()))

    def test_a_class_summary_alone_does_not_end_the_run(self):
        # Only the top-level summary says the run is done; a pause after one class's summary is not a hang.
        result, _ = self.wrapper('test', FAKE_INNER_ONLY='3')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('finished on its own', result.stdout)
        self.assertNotIn('forced', result.stderr)


    def test_a_forced_stop_after_one_bundle_of_two_does_not_pass(self):
        # The SpokenMarginsApp scheme has two test bundles, and each prints its own 'Selected tests' summary. A quiet
        # spell after the first (the UI runner launching) must not turn into a pass for tests that never ran.
        result, _ = self.wrapper('-only-testing:SpokenMarginsAppTests/ModelTests',
                                 '-only-testing:SpokenMarginsAppUITests/J1', 'test')
        self.assertEqual(result.returncode, 65, result.stderr)
        self.assertIn('forced', result.stderr)
        self.assertIn('every test bundle', result.stderr)
        self.assertFalse(any(alive(pid) for pid in self.fake_pids()))

    def test_a_forced_stop_with_no_selectors_does_not_pass(self):
        result, _ = self.wrapper('test')
        self.assertEqual(result.returncode, 65, result.stderr)
        self.assertIn('every test bundle', result.stderr)


class VerifyTestsTests(Fakes):
    def test_an_app_test_step_that_hangs_after_its_summary_is_stopped_and_passes(self):
        spec = importlib.util.spec_from_file_location('verification_finish', SCRIPTS / 'verify-tests.py')
        verification = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(verification)
        env = {**self.env, 'PATH': f'{self.bin}:{os.environ["PATH"]}'}
        with unittest.mock.patch.dict(os.environ, env), \
                unittest.mock.patch.object(xcodebuild_finish, 'GRACE_SECONDS', 1):
            run = verification.Run(self.dir / 'run', 'test')
            started = time.monotonic()
            run.command('xcode-tests', ['xcodebuild', '-scheme', 'S', 'test-without-building'], timeout=60, tests=True)
            seconds = time.monotonic() - started
        entry = run.manifest['steps'][0]
        self.assertEqual(entry['exit_code'], 0)
        self.assertLess(seconds, 45)
        self.assertIn('forced_after_summary', entry)
        self.assertNotIn('interrupted', entry)
        self.assertFalse(any(alive(pid) for pid in self.fake_pids()))


class FinishWatchTests(unittest.TestCase):
    def watch(self):
        self.now = 0.0
        return xcodebuild_finish.FinishWatch(grace=10, clock=lambda: self.now)

    def feed(self, watch, text):
        for line in text.splitlines():
            watch.feed(line)

    def test_quiet_after_the_top_level_summary_is_overdue(self):
        watch = self.watch()
        self.feed(watch, SUMMARY.format(failures=0, verdict='passed'))
        self.now = 9
        self.assertIsNone(watch.overdue())
        self.now = 11
        self.assertEqual(watch.overdue(), 11)
        self.assertEqual(watch.result(), 0)

    def test_new_output_restarts_the_quiet_period(self):
        watch = self.watch()
        self.feed(watch, SUMMARY.format(failures=0, verdict='passed'))
        self.now = 8
        watch.feed("Test Suite 'All tests' started at 2026-10-18")
        self.now = 15
        self.assertIsNone(watch.overdue())

    def test_a_bundle_that_starts_after_a_summary_is_not_cut_short(self):
        # A scheme's second bundle prints its own suites after the first one's summary; until it reports, a
        # quiet spell inside it (a long UI test) is not a hang.
        watch = self.watch()
        self.feed(watch, SUMMARY.format(failures=0, verdict='passed'))
        self.now = 5
        watch.feed("Test Suite 'Selected tests' started at 2026-10-18 14:01:00.000.")
        watch.feed("Test Suite 'SpokenMarginsAppUITests.xctest' started at 2026-10-18 14:01:00.000.")
        self.now = 500
        self.assertIsNone(watch.overdue())
        self.feed(watch, SUMMARY.format(failures=0, verdict='passed'))
        self.now = 511
        self.assertEqual(watch.overdue(), 11)

    def test_which_commands_a_summary_can_speak_for(self):
        rows = [
            (['-scheme', 'S', 'test'], False),  # no selectors: every bundle in the scheme runs
            (['-only-testing:SpokenMarginsAppUITests/J1/testStep', 'test'], True),
            (['-only-testing:A', 'test'], True),
            (['-only-testing:A/B', '-only-testing:A/C/d', 'test'], True),
            (['-only-testing', 'A/B', 'test'], True),
            (['-only-testing:A/B', '-only-testing:B/C', 'test'], False),
            (['-only-testing:A/B', '-only-testing', 'B/C', 'test'], False),
            (['-only-testing:A/B', '-skip-testing:A/B/c', 'test'], True),
            (['-only-testing:A/B', '-testPlan', 'P', 'test'], False),  # a plan can run each test per configuration
            (['-xctestrun', 'r.xctestrun', '-only-testing:A/B', 'test-without-building'], False),
            (['-only-testing:A/B', '-test-iterations', '3', 'test'], False),
            (['-only-testing:A/B', '-retry-tests-on-failure', 'test'], False),
            (['-only-testing:A/B', '-run-tests-until-failure', 'test'], False),
            (['-only-testing:', 'test'], False),
        ]
        for args, expected in rows:
            with self.subTest(args=args):
                self.assertEqual(xcodebuild_finish.one_bundle(args), expected)

    def test_a_forced_result_is_a_pass_only_when_the_summary_covers_the_run(self):
        one = ['-only-testing:A/B', 'test']
        watch = self.watch()
        self.feed(watch, SUMMARY.format(failures=0, verdict='passed'))
        self.assertEqual(watch.forced_result(one), (0, None))
        code, why = watch.forced_result(['test'])
        self.assertEqual(code, 65)
        self.assertIn('every test bundle', why)
        failed = self.watch()
        self.feed(failed, SUMMARY.format(failures=1, verdict='failed'))
        self.assertEqual(failed.forced_result(['test']), (65, None))
        banner = self.watch()
        banner.feed('** TEST SUCCEEDED **')  # xcodebuild's own last word covers every bundle
        self.assertEqual(banner.forced_result(['test']), (0, None))

    def test_inner_summaries_and_silence_before_any_summary_never_end_the_run(self):
        watch = self.watch()
        self.now = 1000
        self.assertIsNone(watch.overdue())
        self.feed(watch, "Test Suite 'J1' passed at x.\n\t Executed 3 tests, with 0 failures (0 unexpected) in 1 (1) seconds")
        self.now = 2000
        self.assertIsNone(watch.overdue())

    def test_failures_and_the_xcodebuild_banner(self):
        watch = self.watch()
        self.feed(watch, SUMMARY.format(failures=1, verdict='failed'))
        self.assertEqual(watch.result(), 65)
        banner = self.watch()
        banner.feed('** TEST FAILED **')
        self.now = 20
        self.assertIsNotNone(banner.overdue())
        self.assertEqual(banner.result(), 65)
        good = self.watch()
        good.feed('** TEST SUCCEEDED **')
        self.assertEqual(good.result(), 0)

    def test_an_inner_failure_counts_even_without_the_top_level_line(self):
        watch = self.watch()
        self.feed(watch, "Test Suite 'J1' failed at x.\n\t Executed 2 tests, with 1 failure (0 unexpected) in 1 (1) seconds\n"
                         '** TEST EXECUTE FAILED **')
        self.assertEqual(watch.result(), 65)


if __name__ == '__main__':
    unittest.main()
