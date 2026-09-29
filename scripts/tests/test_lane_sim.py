import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest import mock

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
import lane_sim  # noqa: E402
import lane_slots  # noqa: E402

FAKE_SIMCTL = r'''#!/usr/bin/env python3
import json, os, sys, time
args = sys.argv[1:]
def log(entry):
    with open(os.environ["FAKE_RECORD"], "a") as handle:
        handle.write(json.dumps(entry) + "\n")
if args[:2] == ["list", "devices"]:
    booted = [u for u in os.environ.get("FAKE_BOOTED", "").split(",") if u]
    print(json.dumps({"devices": {"iOS-26-5": [{"udid": u} for u in booted]}}))
elif args[:2] == ["list", "runtimes"]:
    print(json.dumps({"runtimes": [{"isAvailable": True, "platform": "iOS", "version": "26.5",
                                    "identifier": "com.apple.CoreSimulator.SimRuntime.iOS-26-5"}]}))
elif args[0] == "create":
    log({"create": args[1]})
    print("FRESH-0000-0000")
elif args[0] == "boot":
    start = time.time()
    gate = os.environ.get("FAKE_BOOT_GATE")
    if gate:  # hold the boot open until the test says so
        open(gate + ".started", "w").close()
        deadline = time.time() + 60
        while not os.path.exists(gate + ".release") and time.time() < deadline:
            time.sleep(0.02)
    time.sleep(float(os.environ.get("FAKE_BOOT_SECONDS", "0.1")))
    log({"boot": args[1], "start": start, "end": time.time()})
    if os.environ.get("FAKE_BOOT") == "invalid":
        sys.stderr.write("Unable to boot device in current state: Shutdown\nInvalid argument\n")
        sys.exit(149)
elif args[0] == "bootstatus":
    if os.environ.get("FAKE_CRASH"):
        time.sleep(0.2)
        with open(os.path.join(os.environ["SM_LANE_CRASH_REPORTS"], "SpringBoard-2026-09-29-095801.ips"), "w") as handle:
            handle.write("FBSystemShellInitialize com.apple.CoreSimulator.SimDevice." + args[1])
        time.sleep(60)
    time.sleep(float(os.environ.get("FAKE_READY_SECONDS", "0.1")))
elif args[0] == "shutdown":
    log({"shutdown": args[1], "at": time.time()})
elif args[0] == "delete":
    log({"delete": args[1], "at": time.time()})
'''

PS_OUTPUT = """41094     1 launchd_sim /Users/me/Library/Developer/CoreSimulator/Devices/7E6701FC-0783-4C87-90D8-180CCDAC5280/data/var/run/launchd_bootstrap.plist
41105 41094 /Library/Developer/CoreSimulator/Volumes/iOS_23F77/Library/Developer/CoreSimulator/Profiles/Runtimes/iOS 26.5.simruntime/Contents/Resources/RuntimeRoot/System/Library/CoreServices/SpringBoard.app/SpringBoard
51000     1 launchd_sim /Users/me/Library/Developer/CoreSimulator/Devices/AAAAAAAA-0000-0000-0000-000000000000/data/var/run/launchd_bootstrap.plist
  900     1 /System/Library/CoreServices/SpringBoard.app/SpringBoard
"""


def sequence(*states):
    """A processes() stand-in that returns each (launchd, springboard) state once, then repeats the last."""
    states = list(states)
    return lambda udid: states.pop(0) if len(states) > 1 else states[0]

UDID = '11111111-2222-3333-4444-555555555555'


class LaneSimTests(unittest.TestCase):
    """Boot rules from two crash floods (#184): one at a time, quiet Mac, no retry, stop at first crash."""

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        folder = Path(self.temporary.name)
        fake = folder / 'simctl'
        fake.write_text(FAKE_SIMCTL)
        fake.chmod(0o755)
        (folder / 'reports').mkdir()
        self.record = folder / 'record.jsonl'
        self.env = {'SM_LANE_STATE_DIR': str(folder / 'state'), 'SM_LANE_SIMCTL': str(fake),
                    'SM_LANE_CRASH_REPORTS': str(folder / 'reports'), 'FAKE_RECORD': str(self.record),
                    'SM_LANE_MEMORY_PRESSURE': '1'}
        patches = [mock.patch.dict(os.environ, self.env), mock.patch.object(lane_sim, 'CRASH_POLL_SECONDS', 0.05),
                   mock.patch.object(lane_slots, 'POLL_SECONDS', 0.05)]
        for patch in patches:
            patch.start()
            self.addCleanup(patch.stop)
        self.quiet = open(os.devnull, 'w')
        self.addCleanup(self.quiet.close)

    def records(self):
        """What the fake simctl did, without timestamps (see timed() for those)."""
        return [{k: v for k, v in r.items() if k != 'at'} for r in self.timed()]

    def timed(self):
        return [json.loads(line) for line in self.record.read_text().splitlines()] if self.record.exists() else []

    def test_a_healthy_boot_returns_when_ready_and_marks_nothing(self):
        self.assertGreaterEqual(lane_sim.boot(UDID, 'test', out=self.quiet), 0)
        self.assertEqual([r.get('boot') for r in self.records() if 'boot' in r], [UDID])
        self.assertEqual(lane_sim.unsafe_devices(), {})

    def test_a_failed_boot_stops_marks_the_device_and_is_never_retried(self):
        with mock.patch.dict(os.environ, {'FAKE_BOOT': 'invalid'}):
            with self.assertRaisesRegex(lane_sim.BootError, 'Invalid argument.*do not retry'):
                lane_sim.boot(UDID, 'test', out=self.quiet)
        self.assertIn({'shutdown': UDID}, self.records())
        self.assertIn('Invalid argument', lane_sim.unsafe_devices()[UDID]['reason'])
        with self.assertRaisesRegex(lane_sim.BootError, 'marked unsafe'):
            lane_sim.boot(UDID, 'retry', out=self.quiet)
        self.assertEqual(sum('boot' in r for r in self.records()), 1)  # the retry never reached simctl

    def poll_loop(self, *, ready=(), springboard=((None, None),), reports=(), timeout=900):
        """Run wait_until_ready with scripted signals and a fake clock; returns (outcome, polls, stops)."""
        ready, reports = list(ready), list(reports)
        now, stops, polls = [0.0], [], [0]

        def is_ready():
            polls[0] += 1
            return ready.pop(0) if ready else False

        def sleep(seconds):
            now[0] += seconds

        monitor = lane_sim.SpringBoardMonitor(UDID, sequence(*springboard), clock=lambda: now[0])
        with mock.patch.object(lane_sim, 'stop', side_effect=lambda udid, reason: stops.append(reason)):
            try:
                lane_sim.wait_until_ready(UDID, is_ready, monitor, lambda: reports.pop(0) if reports else None,
                                          timeout, clock=lambda: now[0], sleep=sleep, poll=1.0)
                outcome = 'ready'
            except lane_sim.BootError as error:
                outcome = str(error)
        return outcome, polls[0], stops

    def test_a_crash_while_booting_stops_at_the_first_report(self):
        report = Path('SpringBoard-2026-09-29-095801.ips')
        outcome, polls, stops = self.poll_loop(reports=[None, None, report])
        self.assertIn('SpringBoard-2026-09-29-095801.ips while booting', outcome)
        self.assertEqual(polls, 3)  # stopped at the first report, not later
        self.assertEqual(stops, ['crashed during boot: SpringBoard-2026-09-29-095801.ips'])

    def test_a_springboard_restart_stops_the_boot_before_any_report_arrives(self):
        outcome, polls, stops = self.poll_loop(springboard=[(10, 20), (10, 20), (10, 21)])
        self.assertIn('SpringBoard restarted (pid 20 -> 21) while booting', outcome)
        self.assertEqual((polls, stops), (3, ['SpringBoard restarted (pid 20 -> 21) during boot']))

    def test_a_device_that_never_gets_ready_is_shut_down_but_not_marked(self):
        outcome, _, stops = self.poll_loop(timeout=5)
        self.assertIn('not ready after 5s', outcome)
        self.assertEqual(stops, [])
        self.assertIn({'shutdown': UDID}, self.records())

    def test_a_device_that_gets_ready_returns(self):
        self.assertEqual(self.poll_loop(ready=[False, False, True]), ('ready', 3, []))

    def test_new_crash_finds_only_new_reports_for_this_device(self):
        folder = Path(self.env['SM_LANE_CRASH_REPORTS'])
        (folder / 'old.ips').write_text(f'com.apple.CoreSimulator.SimDevice.{UDID}')
        baseline = lane_sim.crash_snapshot(folder)
        (folder / 'other-device.ips').write_text('com.apple.CoreSimulator.SimDevice.99999999-0000')
        self.assertIsNone(lane_sim.new_crash(folder, baseline, UDID))
        (folder / 'SpringBoard-new.ips').write_text(f'FBSystemShellInitialize com.apple.CoreSimulator.SimDevice.{UDID}')
        self.assertEqual(lane_sim.new_crash(folder, baseline, UDID).name, 'SpringBoard-new.ips')

    def test_boot_wires_the_real_report_folder_into_the_watch(self):
        # End to end with the fake simctl: its bootstatus writes a report and then waits 60 s, so only the
        # crash watch can end the boot. No timing bounds; the deterministic rules are tested above.
        with mock.patch.dict(os.environ, {'FAKE_CRASH': '1'}):
            with self.assertRaisesRegex(lane_sim.BootError, 'SpringBoard-2026-09-29-095801.ips while booting'):
                lane_sim.boot(UDID, 'test', out=self.quiet)
        self.assertIn({'shutdown': UDID}, self.records())
        self.assertIn('crashed during boot', lane_sim.unsafe_devices()[UDID]['reason'])

    def test_no_build_can_start_while_a_simulator_boots(self):
        # Deterministic: the fake boot holds itself open until released, so the build attempt always lands
        # mid-boot, however slowly this Mac starts processes (it once failed at a load average of 235).
        gate = str(Path(self.temporary.name) / 'gate')
        with mock.patch.dict(os.environ, {'FAKE_BOOT_GATE': gate}):
            booting = threading.Thread(target=lane_sim.boot, args=(UDID, 'test'), kwargs={'out': self.quiet})
            booting.start()
            for _ in range(3000):
                if os.path.exists(gate + '.started'):
                    break
                time.sleep(0.02)
            else:
                self.fail('the fake boot never started')
            try:
                with self.assertRaises(TimeoutError):
                    with lane_slots.build_slot('a stream build', out=self.quiet, max_wait=0.3):
                        pass
            finally:
                open(gate + '.release', 'w').close()
                booting.join(60)
        with lane_slots.build_slot('after the boot', out=self.quiet, max_wait=5):
            pass

    def test_a_boot_waits_for_normal_memory_pressure_but_never_fails_on_it(self):
        now = [0.0]
        levels = iter([4, 2, 1])
        name, waited = lane_sim.wait_for_normal_pressure(600, poll=10, level=lambda: next(levels),
                                                         clock=lambda: now[0], sleep=lambda s: now.__setitem__(0, now[0] + s))
        self.assertEqual((name, waited), ('normal', 20))
        now[0] = 0.0
        name, waited = lane_sim.wait_for_normal_pressure(600, poll=10, level=lambda: 2, clock=lambda: now[0],
                                                         sleep=lambda s: now.__setitem__(0, now[0] + s))
        self.assertEqual((name, waited), ('warn', 600))  # gives up waiting, boots anyway

    def test_the_boot_records_memory_pressure_and_failures_name_it(self):
        info = {}
        lane_sim.boot(UDID, 'test', out=self.quiet, info=info)
        self.assertEqual(info, {'pressure': 'normal', 'pressure_waited': 0})
        other = '22222222-0000-0000-0000-000000000000'
        with mock.patch.dict(os.environ, {'FAKE_BOOT': 'invalid', 'SM_LANE_MEMORY_PRESSURE': '4'}), \
                mock.patch.object(lane_sim, 'PRESSURE_WAIT', 0):
            with self.assertRaisesRegex(lane_sim.BootError, 'Invalid argument.*Memory pressure at boot: critical'):
                lane_sim.boot(other, 'test', out=self.quiet)

    def test_it_waits_while_another_simulator_is_booted(self):
        with mock.patch.dict(os.environ, {'FAKE_BOOTED': 'X'}):
            with self.assertRaisesRegex(lane_sim.BootError, 'another simulator stayed booted'):
                lane_sim.wait_for_room(UDID, max_wait=0.1, poll=0.02)
        seen = iter([{'X'}, set()])
        lane_sim.wait_for_room(UDID, max_wait=5, poll=0.01, booted=lambda: next(seen))

    def test_builds_get_one_slot_while_a_simulator_job_runs(self):
        with lane_slots.build_slot('first', out=self.quiet), lane_slots.build_slot('second', out=self.quiet, max_wait=1):
            pass  # two at once without a simulator job
        with lane_slots.simulator_slot('a T4 job', out=self.quiet):
            self.assertTrue(lane_slots.simulator_job_running())
            with lane_slots.build_slot('first', out=self.quiet):
                with self.assertRaisesRegex(TimeoutError, 'only 1 of 2 while a simulator job runs'):
                    with lane_slots.build_slot('second', out=self.quiet, max_wait=0.3):
                        pass
        self.assertFalse(lane_slots.simulator_job_running())

    def test_the_runner_does_not_start_a_simulator_while_another_job_holds_the_slot(self):
        import importlib.util
        spec = importlib.util.spec_from_file_location('lane_runner_for_slot', SCRIPTS / 'lane-runner.py')
        runner = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(runner)
        with mock.patch.object(runner, 'RUNNER_SLOT_WAIT', 0.2), \
                mock.patch.object(lane_sim, 'create_temporary', side_effect=AssertionError('made a simulator')), \
                lane_slots.simulator_slot('the Test Desk', out=self.quiet), mock.patch('sys.stdout', self.quiet):
            verdict, _, _, details, _, _ = runner.run_t3(['AppNavigationStateTests'], 'r1', Path(self.temporary.name))
        self.assertEqual(verdict, 'INCONCLUSIVE')
        self.assertIn('one simulator slot stayed busy', details[0])

    def test_a_second_simulator_job_waits_until_the_first_is_done(self):
        helper = [sys.executable, str(SCRIPTS / 'lane-sim-boot')]
        first = subprocess.run(helper + ['A-1'], env=dict(os.environ), capture_output=True, text=True, timeout=60)
        self.assertEqual(first.returncode, 0, first.stderr)
        self.assertTrue(lane_slots.simulator_job_running())  # the watcher holds it after the helper exited
        second = subprocess.Popen(helper + ['B-2'], env=dict(os.environ), stdout=subprocess.PIPE,
                                  stderr=subprocess.PIPE, text=True)
        time.sleep(1.5)
        self.assertIsNone(second.poll())
        self.assertNotIn('B-2', [r.get('boot') for r in self.records()])
        subprocess.run(helper + ['--done', 'A-1'], env=dict(os.environ), capture_output=True, timeout=60)
        out, err = second.communicate(timeout=60)
        self.assertEqual((second.returncode, out), (0, 'B-2\n'), err)
        self.assertIn('waiting for a simulator slot', err)
        timed = self.timed()
        released = next(r['at'] for r in timed if r.get('delete') == 'A-1')
        booted = next(r['start'] for r in timed if r.get('boot') == 'B-2')
        self.assertGreaterEqual(booted, released)
        subprocess.run(helper + ['--done', 'B-2'], env=dict(os.environ), capture_output=True, timeout=60)
        self.assertFalse(lane_slots.simulator_job_running())

    def test_fresh_boots_with_a_watcher_and_done_removes_both(self):
        helper = [sys.executable, str(SCRIPTS / 'lane-sim-boot')]
        booted = subprocess.run(helper + ['--fresh', 'SM Lane Desk pr220'], env=dict(os.environ),
                                capture_output=True, text=True, timeout=60)
        self.assertEqual((booted.returncode, booted.stdout), (0, 'FRESH-0000-0000\n'), booted.stderr)
        self.assertIn({'create': 'SM Lane Desk pr220'}, self.records())
        _, log, pid_file = lane_sim.watch_files('FRESH-0000-0000')
        watcher = int(pid_file.read_text())
        os.kill(watcher, 0)  # running
        done = subprocess.run(helper + ['--done', 'FRESH-0000-0000'], env=dict(os.environ), capture_output=True,
                              text=True, timeout=60)
        self.assertEqual(done.returncode, 0, done.stderr)
        for _ in range(50):
            try:
                os.kill(watcher, 0)
            except ProcessLookupError:
                break
            time.sleep(0.1)
        else:
            os.kill(watcher, 9)
            self.fail('the watcher outlived --done')
        self.assertIn({'shutdown': 'FRESH-0000-0000'}, self.records())
        self.assertIn({'delete': 'FRESH-0000-0000'}, self.records())
        self.assertIn('ended: released', log.read_text())
        self.assertEqual(lane_sim.unsafe_devices(), {})

    def test_processes_are_found_for_the_right_device_only(self):
        self.assertEqual(lane_sim.device_processes('7E6701FC-0783-4C87-90D8-180CCDAC5280', PS_OUTPUT), (41094, 41105))
        self.assertEqual(lane_sim.device_processes('AAAAAAAA-0000-0000-0000-000000000000', PS_OUTPUT), (51000, None))
        self.assertEqual(lane_sim.device_processes(UDID, PS_OUTPUT), (None, None))

    def test_the_monitor_sees_a_restart_or_a_vanished_springboard_but_not_a_shutdown(self):
        now = [0.0]
        clock = lambda: now[0]
        booting = lane_sim.SpringBoardMonitor(UDID, sequence((None, None), (10, None), (10, 20), (10, 20), (10, 21)), clock=clock)
        self.assertEqual([booting.check() for _ in range(5)][-1], 'SpringBoard restarted (pid 20 -> 21)')
        vanished = lane_sim.SpringBoardMonitor(UDID, sequence((10, 20), (10, None)), grace=3, clock=clock)
        self.assertIsNone(vanished.check())
        self.assertIsNone(vanished.check())  # gone, but within the grace
        now[0] = 5
        self.assertEqual(vanished.check(), 'SpringBoard (pid 20) vanished while the device kept running')
        shutdown = lane_sim.SpringBoardMonitor(UDID, sequence((10, 20), (10, None), (None, None)), grace=3, clock=clock)
        self.assertEqual([shutdown.check() for _ in range(3)], [None, None, 'shut down'])

    def test_boot_wires_the_springboard_monitor_into_the_watch(self):
        # End to end with the fake simctl: bootstatus waits 60 s, so only the monitor can end the boot.
        with mock.patch.dict(os.environ, {'FAKE_READY_SECONDS': '60'}), \
                mock.patch.object(lane_sim, 'device_processes', sequence((10, 20), (10, 20), (10, 21))):
            with self.assertRaisesRegex(lane_sim.BootError, 'SpringBoard restarted'):
                lane_sim.boot(UDID, 'test', out=self.quiet)
        self.assertIn('during boot', lane_sim.unsafe_devices()[UDID]['reason'])

    def test_the_watcher_stops_the_device_at_the_first_crash_and_leaves_a_released_one_alone(self):
        monitor = lane_sim.SpringBoardMonitor(UDID, sequence((10, 20), (10, 20), (10, 22)))
        self.assertIn('crash: SpringBoard restarted', lane_sim.watch(UDID, poll=0.01, monitor=monitor))
        self.assertIn({'shutdown': UDID}, self.records())
        self.assertIn('after boot', lane_sim.unsafe_devices()[UDID]['reason'])
        other = '99999999-0000-0000-0000-000000000000'
        stop_flag, _, _ = lane_sim.watch_files(other)
        stop_flag.parent.mkdir(parents=True, exist_ok=True)
        stop_flag.write_text('released')
        checks = []
        states = [(10, 20), (10, None), (None, None)]  # released: SpringBoard ends, then the device goes

        def processes(udid):
            checks.append(udid)
            return states.pop(0) if len(states) > 1 else states[0]

        self.assertEqual(lane_sim.watch(other, poll=0.01, monitor=lane_sim.SpringBoardMonitor(other, processes)),
                         'released')
        self.assertEqual(len(checks), 3)  # it held on (and held any slot) until the device was gone
        self.assertNotIn(other, lane_sim.unsafe_devices())

    def test_the_helper_refuses_an_unsafe_device_with_a_stop_message(self):
        lane_sim.mark_unsafe(UDID, 'simctl boot failed: Invalid argument')
        done = subprocess.run([sys.executable, str(SCRIPTS / 'lane-sim-boot'), UDID], env=dict(os.environ),
                              capture_output=True, text=True, timeout=60)
        self.assertEqual(done.returncode, 3)
        self.assertIn('STOP', done.stderr)
        self.assertEqual(self.records(), [])

    def test_the_runner_reports_why_it_could_not_boot(self):
        import importlib.util
        spec = importlib.util.spec_from_file_location('lane_runner_for_sim', SCRIPTS / 'lane-runner.py')
        runner = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(runner)
        with mock.patch.object(lane_sim, 'LOCK_WAIT', 0.2), \
                lane_slots.simulator_boot_lock('the Test Desk', out=self.quiet):
            problem, _ = runner.first_boot(UDID, self.quiet)
        self.assertIn('the lane stayed busy', problem)
        self.assertEqual(self.records(), [])


if __name__ == '__main__':
    unittest.main()
