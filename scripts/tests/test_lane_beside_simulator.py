"""Trial: the build runner runs host-only jobs, and then builds, beside a simulator job when the Mac has room.

sm-lane-mac-2 sat in wait_for_room_to_build whenever any simulator job ran, the Test Desk's included:
394 idle minutes in the 24 hours to 2026-10-01, much of it for T0/T1 jobs that run no xcodebuild and
no simulator. Most automerge jobs build, so it still spent 6.9 of 12.7 busy hours (54%) waiting; a build
may now start beside one simulator job too, on the same terms, while the one build slot left is free.
"""
import contextlib
import fcntl
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))
import test_lane_runner  # noqa: E402
from test_lane_runner import FakeGitHub, HEAD, lane  # noqa: E402
import lane_slots  # noqa: E402

original = lane.run_auto  # the real one, for tests that wrap it

GIB = 2**30


class MemoryPressureReadingTests(unittest.TestCase):
    """The level the trial needs to read as normal: the kernel's, as `memory_pressure` reports it."""

    def level(self, output=None, error=None):
        def sysctl(command, text):
            self.assertEqual(command, ['sysctl', '-n', 'kern.memorystatus_vm_pressure_level'])
            if error:
                raise error
            return output
        with mock.patch.dict(os.environ, {'SM_LANE_MEMORY_PRESSURE': ''}), \
                mock.patch('subprocess.check_output', side_effect=sysctl):
            return lane_slots.memory_pressure_level()

    def test_the_kernel_s_levels_are_read(self):
        self.assertEqual(self.level('1\n'), 1)
        self.assertEqual(self.level('2\n'), 2)
        self.assertEqual(self.level('4'), 4)

    def test_an_unreadable_level_is_none_and_never_counts_as_normal_for_the_trial(self):
        self.assertIsNone(self.level('kern.memorystatus_vm_pressure_level: unknown oid\n'))
        self.assertIsNone(self.level(error=subprocess.CalledProcessError(1, 'sysctl')))
        self.assertIsNone(self.level(error=FileNotFoundError('sysctl')))
        self.assertFalse(lane.pressure_is_normal(None))
        self.assertTrue(lane.pressure_is_normal(1))
        self.assertFalse(lane.pressure_is_normal(2))


class HostRoomTests(unittest.TestCase):
    def wait(self, jobs, pressures, frees, max_wait=100):
        now = [0.0]
        states = {'jobs': list(jobs), 'pressure': list(pressures), 'free': list(frees)}
        take = lambda key: (states[key].pop(0) if len(states[key]) > 1 else states[key][0])
        with open(os.devnull, 'w') as quiet:
            result = lane.wait_for_room_to_test_on_host(
                out=quiet, max_wait=max_wait, poll=10, clock=lambda: now[0],
                sleep=lambda seconds: now.__setitem__(0, now[0] + seconds),
                simulator_jobs=lambda: take('jobs'), pressure=lambda: take('pressure'), free=lambda: take('free'))
        return result, now[0]

    def test_with_a_simulator_running_it_starts_at_once_when_pressure_is_normal_and_disk_is_free(self):
        (problem, beside), waited = self.wait([1], [1], [40 * GIB])
        self.assertEqual((problem, waited), (None, 0.0))
        self.assertIn('beside a simulator job', beside)
        self.assertIn('memory pressure normal', beside)
        self.assertIn('40 GiB free', beside)

    def test_beside_a_simulator_it_waits_for_normal_pressure_and_30_gib(self):
        (problem, beside), waited = self.wait([1], [2, 1, 1], [40 * GIB, 25 * GIB, 31 * GIB])
        self.assertIsNone(problem)
        self.assertIsNotNone(beside)
        self.assertEqual(waited, 20.0)  # pressure first, then the disk

    def test_an_unreadable_pressure_beside_a_simulator_is_waited_out_and_named(self):
        (problem, beside), _ = self.wait([1], [None], [40 * GIB], max_wait=60)
        self.assertIsNone(beside)
        self.assertIn('memory pressure is unreadable', problem)
        self.assertIn('a simulator job is running', problem)
        (problem, _), _ = self.wait([1], [1], [29 * GIB], max_wait=60)
        self.assertIn('less than 30 GiB of disk is free', problem)

    def test_without_a_simulator_the_rules_are_the_build_runner_s_and_nothing_is_noted(self):
        (problem, beside), waited = self.wait([0], [None], [21 * 10**9])
        self.assertEqual((problem, beside, waited), (None, None, 0.0))
        (problem, beside), _ = self.wait([0], [2], [10**12], max_wait=60)
        self.assertIn('memory pressure is above normal', problem)


class BuildRoomTests(unittest.TestCase):
    """A build (T2: simulator and device builds through the build slot, no simulator boot) beside a simulator job."""

    def wait(self, jobs, pressures, frees, builds, max_wait=100):
        now, notes = [0.0], []
        states = {'jobs': list(jobs), 'pressure': list(pressures), 'free': list(frees), 'builds': list(builds)}
        take = lambda key: (states[key].pop(0) if len(states[key]) > 1 else states[key][0])
        with open(os.devnull, 'w') as quiet:
            problem = lane.wait_for_room_to_build(
                out=quiet, max_wait=max_wait, poll=10, clock=lambda: now[0],
                sleep=lambda seconds: now.__setitem__(0, now[0] + seconds),
                simulator_jobs=lambda: take('jobs'), pressure=lambda: take('pressure'), free=lambda: take('free'),
                builds=lambda: take('builds'), note=notes.append)
        return problem, notes, now[0]

    def test_a_build_starts_beside_a_simulator_job_at_normal_pressure_and_says_so(self):
        problem, notes, waited = self.wait([1], [1], [40 * GIB], [0])
        self.assertEqual((problem, waited), (None, 0.0))
        self.assertEqual(notes, ['built beside a simulator job (trial): memory pressure normal, 40 GiB free'])

    def test_a_build_is_refused_beside_a_simulator_job_at_warn_or_unreadable_pressure(self):
        for level, named in ((2, 'above normal'), (4, 'above normal'), (None, 'unreadable')):
            with self.subTest(level=level):
                problem, notes, _ = self.wait([1], [level], [40 * GIB], [0], max_wait=60)
                self.assertIn(f'a simulator job is running and memory pressure is {named}', problem)
                self.assertEqual(notes, [])
        problem, notes, waited = self.wait([1], [2, 2, 1], [40 * GIB], [0])  # it starts once pressure is normal
        self.assertEqual((problem, waited), (None, 20.0))
        self.assertEqual(len(notes), 1)

    def test_during_a_simulator_job_it_waits_while_the_one_build_slot_is_taken(self):
        problem, notes, _ = self.wait([1], [1], [40 * GIB], [1], max_wait=60)
        self.assertIn('the one build slot it leaves is taken', problem)
        self.assertEqual(notes, [])
        problem, notes, waited = self.wait([1], [1], [40 * GIB], [1, 1, 0])
        self.assertEqual((problem, waited), (None, 20.0))

    def test_never_beside_two_simulator_jobs_or_short_of_30_gib(self):
        problem, _, _ = self.wait([2], [1], [40 * GIB], [0], max_wait=60)
        self.assertIn('two simulator jobs are running', problem)
        problem, _, _ = self.wait([1], [1], [29 * GIB], [0], max_wait=60)
        self.assertIn('less than 30 GiB of disk is free', problem)

    def test_with_no_simulator_job_the_old_rules_hold_and_nothing_is_noted(self):
        problem, notes, waited = self.wait([0], [None], [21 * 10**9], [2])
        self.assertEqual((problem, notes, waited), (None, [], 0.0))
        problem, _, _ = self.wait([0], [2], [10**12], [0], max_wait=60)
        self.assertIn('memory pressure is above normal', problem)

    def test_with_real_locks_a_simulator_job_leaves_one_build_and_the_runner_sees_it(self):
        with tempfile.TemporaryDirectory() as folder, \
                mock.patch.dict(os.environ, {'SM_LANE_STATE_DIR': folder, 'SM_LANE_MEMORY_PRESSURE': '1'}), \
                mock.patch.object(lane_slots, 'POLL_SECONDS', 0.05), \
                open(os.devnull, 'w') as quiet, contextlib.ExitStack() as held:
            room = lambda: lane.wait_for_room_to_build(out=quiet, max_wait=0, free=lambda: 40 * GIB)  # noqa: E731
            held.enter_context(lane_slots.simulator_slot('a T4', out=quiet))
            self.assertIsNone(room())
            held.enter_context(lane_slots.build_slot('the first build', out=quiet))
            self.assertEqual(lane_slots.build_jobs_running(), 1)
            self.assertIn('the one build slot it leaves is taken', room())
            with self.assertRaises(TimeoutError):  # lane_slots still caps it at one build
                with lane_slots.build_slot('a second build', out=quiet, max_wait=0.2):
                    self.fail('took a second build slot during a simulator job')


class OlderBranchLaneSlotsTests(unittest.TestCase):
    """#656 audit: the workflow runs next's lane-runner.py, but lane_slots comes from the PR's checkout. A branch
    that hasn't merged next since build_jobs_running landed must not crash the runner before it reports."""

    def test_the_runner_s_import_path_works_with_a_lane_slots_that_lacks_build_jobs_running(self):
        with tempfile.TemporaryDirectory() as folder, \
                mock.patch.dict(os.environ, {'SM_LANE_STATE_DIR': str(Path(folder) / 'state'),
                                             'SM_LANE_MEMORY_PRESSURE': '1'}), \
                open(os.devnull, 'w') as quiet, lane_slots.simulator_slot('a T4', out=quiet):
            runner_temp, tree = Path(folder) / 'runner-temp', Path(folder) / 'tree/scripts'
            runner_temp.mkdir()
            tree.mkdir(parents=True)
            # As the workflow does: the runner copied out of the base branch, apart from the checkout.
            (runner_temp / 'lane-runner.py').write_text((Path(lane.__file__)).read_text())
            source = (Path(lane_slots.__file__)).read_text() + '\ndel build_jobs_running  # an older branch\n'
            (tree / 'lane_slots.py').write_text(source)
            code = (f'import importlib.util, sys; sys.path.insert(0, {str(tree)!r}); '
                    f'spec = importlib.util.spec_from_file_location("l", {str(runner_temp / "lane-runner.py")!r}); '
                    'l = importlib.util.module_from_spec(spec); spec.loader.exec_module(l); '
                    'import lane_slots; assert not hasattr(lane_slots, "build_jobs_running"), lane_slots.__file__; '
                    f'print("RESULT", l.wait_for_room_to_build(max_wait=0, free=lambda: {40 * GIB}))')
            done = subprocess.run([sys.executable, '-c', code], capture_output=True, text=True, timeout=60)
        self.assertEqual(done.returncode, 0, done.stderr)
        result = next(line for line in done.stdout.splitlines() if line.startswith('RESULT'))
        # It can't count build slots, so it doesn't build beside the simulator job: it says why instead.
        self.assertIn("can't count build slots", result)
        self.assertIn('merge next into the branch', result)

    def test_without_a_simulator_job_an_older_lane_slots_still_builds(self):
        with open(os.devnull, 'w') as quiet:
            problem = lane.wait_for_room(quiet, 0, 10, lambda: 0.0, lambda _: None, lambda: 0, lambda: 1,
                                         lambda: 40 * GIB, lambda: None)
        self.assertEqual(problem, (None, None))


class BuildSlotRecheckTests(unittest.TestCase):
    """#656 audit: the room check ran only when the job started. A second simulator job could start during the
    host tests, and the build then took the one build slot beside two. Each build checks again as it takes it."""

    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.addCleanup(self.folder.cleanup)
        self.quiet = open(os.devnull, 'w')
        self.addCleanup(self.quiet.close)
        self.env = mock.patch.dict(os.environ, {'SM_LANE_STATE_DIR': self.folder.name, 'SM_LANE_MEMORY_PRESSURE': '1',
                                                'SM_LANE_RUNNER_ROLE': 'build', 'SM_LANE_XCODEBUILD': '/usr/bin/true'})
        self.env.start()
        self.addCleanup(self.env.stop)
        self.held = contextlib.ExitStack()
        self.addCleanup(self.held.close)

    def build(self, timeout):
        with tempfile.TemporaryDirectory() as evidence, \
                mock.patch.object(lane, 'BUILD_TIMEOUT', timeout), mock.patch.object(lane, 'INTERRUPT_GRACE', 5):
            verdict, builds, details = lane.run_t2(Path(evidence))
            logs = ''.join(log.read_text() for log in sorted(Path(evidence).glob('t2-*.log')))
        return verdict, builds, details, logs

    def test_a_second_simulator_job_that_starts_during_host_tests_holds_the_build(self):
        self.held.enter_context(lane_slots.simulator_slot('a T4', out=self.quiet))
        noted = []
        self.assertIsNone(lane.wait_for_room_to_build(out=self.quiet, max_wait=0, free=lambda: 40 * GIB,
                                                      note=noted.append))  # the job starts beside one
        self.assertEqual(len(noted), 1)
        self.held.enter_context(lane_slots.simulator_slot('a second T4, during host tests', out=self.quiet))
        verdict, builds, _, logs = self.build(timeout=4)  # the real xcodebuild-lane, xcodebuild stubbed by `true`
        self.assertEqual(verdict, 'INCONCLUSIVE', builds)
        self.assertIn('timed out', builds)
        self.assertIn('2 simulator jobs are running', logs)
        self.assertNotIn('build slot 1/2 acquired', logs)

    def test_memory_pressure_that_rises_during_host_tests_holds_the_build(self):
        self.held.enter_context(lane_slots.simulator_slot('a T4', out=self.quiet))
        self.assertIsNone(lane.wait_for_room_to_build(out=self.quiet, max_wait=0, free=lambda: 40 * GIB))
        with mock.patch.dict(os.environ, {'SM_LANE_MEMORY_PRESSURE': '2'}):
            verdict, builds, _, logs = self.build(timeout=4)
        self.assertEqual(verdict, 'INCONCLUSIVE', builds)
        self.assertIn('memory pressure is warn', logs)

    def test_beside_one_simulator_job_at_normal_pressure_the_builds_run(self):
        self.held.enter_context(lane_slots.simulator_slot('a T4', out=self.quiet))
        verdict, builds, details, logs = self.build(timeout=60)
        self.assertEqual(verdict, 'PASS', details)
        self.assertEqual(logs.count('build slot 1/2 acquired'), 2)

    def test_the_check_is_only_for_the_build_runner(self):
        self.assertEqual(lane.pr_code_env().get(lane.BUILD_NEEDS_ROOM_ENV), '1')
        with mock.patch.dict(os.environ, {'SM_LANE_RUNNER_ROLE': ''}):
            self.assertNotIn(lane.BUILD_NEEDS_ROOM_ENV, lane.pr_code_env())
            self.held.enter_context(lane_slots.simulator_slot('a T4', out=self.quiet))
            self.held.enter_context(lane_slots.simulator_slot('a second T4', out=self.quiet))
            with lane_slots.build_slot('a session build', out=self.quiet, max_wait=1):  # as before: one beside two
                pass

    def test_the_check_and_the_take_happen_under_the_simulator_slot_decision_lock(self):
        with mock.patch.dict(os.environ, {lane_slots.BUILD_NEEDS_ROOM_ENV: '1'}), \
                open(Path(self.folder.name) / lane_slots.SIMULATOR_DECISION, 'a+') as decision:
            fcntl.flock(decision, fcntl.LOCK_EX)  # a simulator job deciding whether to take its slot
            timer = threading.Timer(0.5, lambda: fcntl.flock(decision, fcntl.LOCK_UN))
            timer.start()
            started = time.monotonic()
            try:
                with lane_slots.build_slot('a build', out=self.quiet, max_wait=5):
                    waited = time.monotonic() - started
            finally:
                timer.join()
        self.assertGreaterEqual(waited, 0.4)


class BuildRunnerJobTests(unittest.TestCase):
    run_main = test_lane_runner.MainFlowTests.run_main
    conflicts, role, attempt = [], 'build', '1'

    def run_job(self, host_only, beside=None, problem=None, state=None):
        with tempfile.TemporaryDirectory() as folder, \
                mock.patch.dict(os.environ, {'SM_LANE_STATE_DIR': state or folder}), \
                mock.patch.object(lane, 'host_only_scope', return_value=host_only), \
                mock.patch.object(lane, 'run_auto', return_value=('PASS', 'host only', 'host tests', [])) as auto, \
                mock.patch.object(lane, 'wait_for_room_to_build', return_value=None) as builds, \
                mock.patch.object(lane, 'wait_for_room_to_test_on_host', return_value=(problem, beside)) as host:
            github = FakeGitHub(labels=('automerge',))
            self.run_main(github, HEAD, 'PASS', '--mode', 'auto')
            log = Path(state or folder) / lane.BESIDE_SIMULATOR_LOG
            lines = log.read_text().splitlines() if log.exists() else []
        return github, auto, builds, host, lines

    def test_a_host_only_job_takes_the_host_rules_and_logs_running_beside_a_simulator(self):
        note = 'ran beside a simulator job (trial): memory pressure normal, 41 GiB free'
        github, auto, builds, host, lines = self.run_job(True, beside=note)
        host.assert_called_once()
        builds.assert_not_called()
        auto.assert_called_once()
        self.assertIs(auto.call_args.kwargs['room_for_builds'].func, builds)  # builds after all still wait
        self.assertIn(note, github.posted[0])
        self.assertEqual(len(lines), 1)
        self.assertIn('pr5-r42', lines[0])
        self.assertIn('PR #5', lines[0])
        self.assertIn(note, lines[0])

    def test_a_job_that_builds_beside_a_simulator_reports_and_logs_it(self):
        text = 'built beside a simulator job (trial): memory pressure normal, 41 GiB free'
        with tempfile.TemporaryDirectory() as folder, \
                mock.patch.dict(os.environ, {'SM_LANE_STATE_DIR': folder}), \
                mock.patch.object(lane, 'host_only_scope', return_value=False), \
                mock.patch.object(lane, 'run_auto', return_value=('PASS', 'x', 'host tests; builds', [])) as auto, \
                mock.patch.object(lane, 'wait_for_room_to_build',
                                  side_effect=lambda note=None: note(text)) as builds:
            github = FakeGitHub(labels=('automerge',))
            self.run_main(github, HEAD, 'PASS', '--mode', 'auto')
            lines = (Path(folder) / lane.BESIDE_SIMULATOR_LOG).read_text().splitlines()
        builds.assert_called_once()
        auto.assert_called_once()
        self.assertIn(text, github.posted[0])
        self.assertEqual(len(lines), 1)
        self.assertIn('PR #5', lines[0])
        self.assertIn(text, lines[0])

    def test_a_host_only_job_with_no_simulator_running_logs_nothing(self):
        github, auto, _, _, lines = self.run_job(True, beside=None)
        auto.assert_called_once()
        self.assertEqual(lines, [])
        self.assertNotIn('beside a simulator', github.posted[0])

    def test_a_job_that_builds_waits_as_before(self):
        github, auto, builds, host, lines = self.run_job(False)
        builds.assert_called_once()
        host.assert_not_called()
        self.assertIsNone(auto.call_args.kwargs.get('room_for_builds'))

    def test_a_host_only_job_that_gets_no_room_reports_inconclusive(self):
        github, auto, _, _, _ = self.run_job(True, problem='the build runner waited 1h30m00s for room: memory '
                                                           'pressure is above normal')
        auto.assert_not_called()
        self.assertTrue(github.posted[0].startswith('Lane report pr5-r42 — INCONCLUSIVE'))

    def test_the_main_runner_never_waits(self):
        self.role = ''
        github, auto, builds, host, _ = self.run_job(True)
        builds.assert_not_called()
        host.assert_not_called()
        auto.assert_called_once()


class HostOnlyScopeTests(unittest.TestCase):
    def test_t0_and_t1_are_host_only_and_anything_else_or_an_error_is_not(self):
        for tier, expected in (('T0', True), ('T1', True), ('T2', False), ('T3', False)):
            with self.subTest(tier=tier), mock.patch.object(lane, 'diff_scope', return_value={'tier': tier}):
                self.assertIs(lane.host_only_scope(Path('.'), 'next'), expected)
        with mock.patch.object(lane, 'diff_scope', side_effect=RuntimeError('no policy')):
            self.assertFalse(lane.host_only_scope(Path('.'), 'next'))

    def test_a_merge_commit_that_needs_builds_after_all_waits_for_the_build_room_first(self):
        # The scope is read on the PR head before the job starts; the merge commit's is read again. If they
        # disagree, the builds still wait for no simulator job.
        calls = []
        harness = test_lane_runner.MergeTests_Runner('test_a_pass_posts_the_merge_check_then_pushes_the_tested_commit')
        for tier, problem, expected_verdict in (('T2', None, 'PASS'), ('T2', 'a simulator job is running', 'INCONCLUSIVE'),
                                                ('T1', 'never asked', 'PASS')):
            with self.subTest(tier=tier, problem=problem):
                calls.clear()
                scope = {'tier': tier, 'why': [], 'files': [{'path': 'App/X.swift', 'category': 'app-ui'}]}
                room = lambda: calls.append('room') or problem  # noqa: E731
                with mock.patch.object(lane, 'run_auto', wraps=lambda *a, **k: original(*a, room_for_builds=room, **k)):
                    (verdict, _, _, details), events = harness.run_auto(FakeGitHub(labels=('automerge',)), scope=scope)
                self.assertEqual(verdict, expected_verdict, details)
                self.assertEqual(calls, ['room'] if tier == 'T2' else [])
                if problem and tier == 'T2':
                    self.assertEqual(events, ['build'])


if __name__ == '__main__':
    unittest.main()
