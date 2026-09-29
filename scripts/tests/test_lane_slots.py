import contextlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest
import unittest.mock

SCRIPTS = Path(__file__).resolve().parents[1]

FAKE_XCODEBUILD = '''#!/usr/bin/env python3
import json, os, sys, time
record = os.environ["FAKE_RECORD"]
start = time.time()
time.sleep(float(os.environ.get("FAKE_SECONDS", "1.5")))
with open(record, "a") as handle:
    handle.write(json.dumps({"start": start, "end": time.time(), "argv": sys.argv[1:], "cwd": os.getcwd()}) + "\\n")
sys.exit(int(os.environ.get("FAKE_EXIT", "0")))
'''


class BuildSlotTests(unittest.TestCase):
    """Runs the real wrapper as separate processes against a fake xcodebuild and a private slot directory."""

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.dir = Path(self.temporary.name)
        fake = self.dir / 'xcodebuild'
        fake.write_text(FAKE_XCODEBUILD)
        fake.chmod(0o755)
        self.record = self.dir / 'record.jsonl'
        self.env = {**os.environ, 'SM_LANE_STATE_DIR': str(self.dir / 'state'), 'SM_LANE_XCODEBUILD': str(fake),
                    'FAKE_RECORD': str(self.record)}

    def tearDown(self):
        self.temporary.cleanup()

    def wrapper(self, *args, cwd=None, env=None):
        return subprocess.Popen([sys.executable, str(SCRIPTS / 'xcodebuild-lane'), *args], cwd=cwd or SCRIPTS.parent,
                                env=env or self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                                start_new_session=True)

    def runs(self):
        return [json.loads(line) for line in self.record.read_text().splitlines()]

    def test_three_builds_run_at_most_two_at_a_time_and_the_third_waits(self):
        processes = [self.wrapper('-scheme', 'S', 'build') for _ in range(3)]
        outputs = [p.communicate(timeout=60) for p in processes]
        self.assertEqual([p.returncode for p in processes], [0, 0, 0], outputs)
        runs = sorted(self.runs(), key=lambda r: r['start'])
        self.assertEqual(len(runs), 3)
        for run in runs:
            overlapping = sum(other['start'] < run['end'] and run['start'] < other['end'] for other in runs)
            self.assertLessEqual(overlapping, 2)
        self.assertGreaterEqual(runs[2]['start'], min(runs[0]['end'], runs[1]['end']) - 0.05)
        stderr = ''.join(err for _, err in outputs)
        self.assertIn('waiting for a build slot', stderr)
        self.assertEqual(stderr.count('acquired after'), 3)

    def test_derived_data_is_per_worktree_unless_given(self):
        process = self.wrapper('-scheme', 'S', 'build')
        process.communicate(timeout=30)
        argv = self.runs()[0]['argv']
        root = subprocess.check_output(['git', 'rev-parse', '--show-toplevel'], cwd=SCRIPTS.parent, text=True).strip()
        self.assertEqual(argv[-2:], ['-derivedDataPath', str(Path(root) / '.build/dd')])
        self.record.unlink()
        self.wrapper('-derivedDataPath', '/tmp/explicit', 'build').communicate(timeout=30)
        self.assertEqual(self.runs()[0]['argv'].count('-derivedDataPath'), 1)

    def test_information_calls_skip_the_queue_and_derived_data(self):
        process = self.wrapper('-version')
        _, err = process.communicate(timeout=30)
        self.assertEqual(self.runs()[0]['argv'], ['-version'])
        self.assertNotIn('build slot', err)

    def test_build_options_are_not_mistaken_for_information_calls(self):
        _, err = self.wrapper('-scheme', 'S', '-showBuildTimingSummary', 'build').communicate(timeout=30)
        self.assertIn('build slot 1/2 acquired', err)
        self.assertIn('-derivedDataPath', self.runs()[0]['argv'])

    def test_a_bounded_wait_gives_up_with_the_holders_named(self):
        sys.path.insert(0, str(SCRIPTS))
        import lane_slots
        with unittest.mock.patch.dict(os.environ, {'SM_LANE_STATE_DIR': str(self.dir / 'bounded')}), \
                unittest.mock.patch.object(lane_slots, 'POLL_SECONDS', 0.05), contextlib.ExitStack() as held:
            for _ in range(lane_slots.SLOTS):
                held.enter_context(lane_slots.build_slot('holder', out=open(os.devnull, 'w')))
            with self.assertRaisesRegex(TimeoutError, 'no build slot free within 0s: pid'):
                with lane_slots.build_slot('waiter', out=open(os.devnull, 'w'), max_wait=0.2):
                    self.fail('acquired a third slot')

    def test_exit_status_is_passed_through_and_the_slot_is_released(self):
        failing = self.wrapper('build', env={**self.env, 'FAKE_EXIT': '65', 'FAKE_SECONDS': '0.1'})
        failing.communicate(timeout=30)
        self.assertEqual(failing.returncode, 65)
        for process in [self.wrapper('build', env={**self.env, 'FAKE_SECONDS': '0.1'}) for _ in range(2)]:
            _, err = process.communicate(timeout=30)
            self.assertNotIn('waiting', err)  # both slots free again: no queue, however busy the Mac is

    def test_a_killed_holder_frees_its_slot(self):
        holders = [self.wrapper('build', env={**self.env, 'FAKE_SECONDS': '30'}) for _ in range(2)]
        deadline = time.monotonic() + 15
        state = self.dir / 'state'
        while time.monotonic() < deadline and sum(
                bool(p.read_text()) for p in state.glob('*.lock')) < 2:
            time.sleep(0.1)
        for holder in holders:
            os.killpg(holder.pid, signal.SIGKILL)  # the wrapper and its xcodebuild, as a crash would
            holder.communicate(timeout=30)
        quick = self.wrapper('build', env={**self.env, 'FAKE_SECONDS': '0.1'})
        _, err = quick.communicate(timeout=30)
        self.assertEqual(quick.returncode, 0)
        self.assertIn('build slot 1/2 acquired', err)
        self.assertNotIn('waiting', err)  # the killed holders' slots were free at once


@unittest.skipUnless(shutil.which('xcodebuild'), 'needs Xcode')
class VerifyTestsSlotTests(unittest.TestCase):
    def test_runner_xcodebuild_steps_take_a_slot_and_record_it(self):
        spec = importlib.util.spec_from_file_location('verification', SCRIPTS / 'verify-tests.py')
        verification = importlib.util.module_from_spec(spec)
        sys.path.insert(0, str(SCRIPTS))
        spec.loader.exec_module(verification)
        with tempfile.TemporaryDirectory() as temporary:
            state = Path(temporary) / 'state'
            with unittest.mock.patch.dict(os.environ, {'SM_LANE_STATE_DIR': str(state)}):
                run = verification.Run(Path(temporary) / 'run', 'test')
                run.command('xcode-version', ['xcodebuild', '-version'])
            entry = run.manifest['steps'][0]
            self.assertEqual(entry['build_slot']['slot'], 0)
            self.assertEqual(entry['exit_code'], 0)
            self.assertTrue((state / 'xcodebuild-slot-0.lock').exists())


if __name__ == '__main__':
    unittest.main()
