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
        time.sleep(10)
    time.sleep(float(os.environ.get("FAKE_READY_SECONDS", "0.1")))
elif args[0] == "shutdown":
    log({"shutdown": args[1]})
'''

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
                    'SM_LANE_CRASH_REPORTS': str(folder / 'reports'), 'FAKE_RECORD': str(self.record)}
        patches = [mock.patch.dict(os.environ, self.env), mock.patch.object(lane_sim, 'CRASH_POLL_SECONDS', 0.05),
                   mock.patch.object(lane_slots, 'POLL_SECONDS', 0.05)]
        for patch in patches:
            patch.start()
            self.addCleanup(patch.stop)
        self.quiet = open(os.devnull, 'w')
        self.addCleanup(self.quiet.close)

    def records(self):
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

    def test_a_crash_while_booting_stops_at_the_first_report(self):
        started = time.monotonic()
        with mock.patch.dict(os.environ, {'FAKE_CRASH': '1'}):
            with self.assertRaisesRegex(lane_sim.BootError, 'SpringBoard-2026-09-29-095801.ips while booting'):
                lane_sim.boot(UDID, 'test', out=self.quiet)
        self.assertLess(time.monotonic() - started, 5)
        self.assertIn({'shutdown': UDID}, self.records())
        self.assertIn('crashed during boot', lane_sim.unsafe_devices()[UDID]['reason'])

    def test_no_build_can_start_while_a_simulator_boots(self):
        with mock.patch.dict(os.environ, {'FAKE_BOOT_SECONDS': '1.5'}):
            booting = threading.Thread(target=lane_sim.boot, args=(UDID, 'test'), kwargs={'out': self.quiet})
            booting.start()
            time.sleep(0.5)
            with self.assertRaises(TimeoutError):
                with lane_slots.build_slot('a stream build', out=self.quiet, max_wait=0.3):
                    pass
            booting.join()
        with lane_slots.build_slot('after the boot', out=self.quiet, max_wait=1):
            pass

    def test_it_waits_while_two_other_simulators_are_booted(self):
        with mock.patch.dict(os.environ, {'FAKE_BOOTED': 'X,Y'}):
            with self.assertRaisesRegex(lane_sim.BootError, 'stayed booted'):
                lane_sim.wait_for_room(UDID, max_wait=0.1, poll=0.02)
        seen = iter([{'X', 'Y'}, {'X'}])
        lane_sim.wait_for_room(UDID, max_wait=5, poll=0.01, booted=lambda: next(seen))

    def test_two_boots_at_once_run_one_after_the_other(self):
        env = {**os.environ, 'FAKE_BOOT_SECONDS': '1'}
        boots = [subprocess.Popen([sys.executable, str(SCRIPTS / 'lane-sim-boot'), udid], env=env,
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True) for udid in ('A-1', 'B-2')]
        outputs = [b.communicate(timeout=60) for b in boots]
        self.assertEqual([b.returncode for b in boots], [0, 0], outputs)
        first, second = sorted((r for r in self.records() if 'boot' in r), key=lambda r: r['start'])
        self.assertGreaterEqual(second['start'], first['end'] - 0.05)
        self.assertIn('waiting for a simulator boot lock', ''.join(err for _, err in outputs))

    def test_fresh_creates_boots_and_prints_only_the_udid(self):
        done = subprocess.run([sys.executable, str(SCRIPTS / 'lane-sim-boot'), '--fresh', 'SM Lane Desk pr220'],
                              env=dict(os.environ), capture_output=True, text=True, timeout=60)
        self.assertEqual((done.returncode, done.stdout), (0, 'FRESH-0000-0000\n'), done.stderr)
        self.assertIn({'create': 'SM Lane Desk pr220'}, self.records())

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
            problem = runner.first_boot(UDID, self.quiet)
        self.assertIn('the lane stayed busy', problem)
        self.assertEqual(self.records(), [])


if __name__ == '__main__':
    unittest.main()
