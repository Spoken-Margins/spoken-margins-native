import contextlib
import fcntl
import importlib.util
import io
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
                    'FAKE_RECORD': str(self.record), 'SM_BUILD_CACHE': 'off'}  # links nothing in this checkout

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

    def test_a_generic_simulator_build_on_apple_silicon_compiles_arm64_only(self):
        # #1326: a clean generic simulator build compiled 782 jobs for x86_64 beside 782 for arm64,
        # packages included; a project.yml ARCHS setting left the 445 package jobs in place.
        self.env['FAKE_SECONDS'] = '0'
        self.wrapper('-destination', 'generic/platform=iOS Simulator', 'build-for-testing').communicate(timeout=30)
        on_apple_silicon = __import__('platform').machine() == 'arm64'
        self.assertEqual('ARCHS=arm64' in self.runs()[0]['argv'], on_apple_silicon)

    def test_only_a_generic_simulator_build_that_sets_no_architecture_gets_arm64(self):
        loader = importlib.machinery.SourceFileLoader('xcodebuild_lane', str(SCRIPTS / 'xcodebuild-lane'))
        spec = importlib.util.spec_from_loader('xcodebuild_lane', loader)
        wrapper = importlib.util.module_from_spec(spec)
        loader.exec_module(wrapper)
        rows = [  # (arguments, machine, expected)
            (['-destination', 'generic/platform=iOS Simulator', 'build'], 'arm64', ['ARCHS=arm64']),
            (['-destination', 'generic/platform=iOS  Simulator', 'build'], 'arm64', ['ARCHS=arm64']),
            (['-destination', 'generic/platform=iOS Simulator,name=Any iOS Simulator Device'], 'arm64', ['ARCHS=arm64']),
            (['-destination', 'generic/platform=iOS', 'build'], 'arm64', []),  # device: arm64 already
            (['-destination', 'platform=iOS Simulator,id=ABC', 'test'], 'arm64', []),  # one device: active arch
            (['-destination', 'generic/platform=iOS Simulator', 'build', 'ARCHS=x86_64'], 'arm64', []),
            (['-destination', 'generic/platform=iOS Simulator', '-arch', 'x86_64', 'build'], 'arm64', []),
            (['-destination', 'generic/platform=iOS Simulator', 'build'], 'x86_64', []),  # an Intel host
            (['-scheme', 'S', 'build'], 'arm64', []),
            (['-destination'], 'arm64', []),
            ([], 'arm64', []),
        ]
        for args, machine, expected in rows:
            with self.subTest(args=args, machine=machine):
                self.assertEqual(wrapper.simulator_arch(args, machine), expected)

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


class HolderNoteTests(unittest.TestCase):
    """Wait messages name only live holders (#395): a note left on a free lock is not a holder."""

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.state = Path(self.temporary.name) / 'state'
        self.state.mkdir()
        patch = unittest.mock.patch.dict(os.environ, {'SM_LANE_STATE_DIR': str(self.state)})
        patch.start()
        self.addCleanup(patch.stop)
        sys.path.insert(0, str(SCRIPTS))
        import lane_slots
        self.slots = lane_slots
        self.quiet = open(os.devnull, 'w')
        self.addCleanup(self.quiet.close)
        exited = subprocess.Popen([sys.executable, '-c', 'pass'])
        exited.wait()
        self.dead_pid = exited.pid

    def note(self, name, pid, label):
        (self.state / name).write_text(json.dumps({'pid': pid, 'cwd': '/somewhere', 'label': label,
                                                   'started': '2026-09-29T10:00:00'}))

    def test_a_dead_pids_note_on_a_free_lock_is_not_named(self):
        # The Test Desk's case: the watcher exited, its slot was free, and its note stayed behind.
        self.note('b.lock', self.dead_pid, 'the exited watcher')
        live, _, _ = self.slots.acquire(['a.lock'], 'slot', 'the live job', out=self.quiet)
        self.addCleanup(self.slots.release_handle, live)
        waited = io.StringIO()
        with unittest.mock.patch.object(self.slots, 'POLL_SECONDS', 0.01):
            with self.assertRaises(TimeoutError) as raised:
                self.slots.acquire(['a.lock', 'b.lock'], 'slot', 'waiter', out=waited, max_wait=0.5,
                                   allowed=lambda: 1, why=lambda: 'only one allowed')
        for message in (str(raised.exception), waited.getvalue()):
            self.assertIn(f'pid {os.getpid()}', message)
            self.assertIn('the live job', message)
            self.assertNotIn(f'pid {self.dead_pid} ', message)
            self.assertNotIn('the exited watcher', message)

    def test_a_held_lock_whose_taker_exited_is_marked_gone(self):
        # lane-sim-boot takes the slot and exits; the watcher it started keeps the lock.
        with open(self.state / 'a.lock', 'a+') as inherited:
            fcntl.flock(inherited, fcntl.LOCK_EX)
            self.note('a.lock', self.dead_pid, 'lane-sim-boot T4')
            with self.assertRaises(TimeoutError) as raised:
                self.slots.acquire(['a.lock'], 'slot', 'waiter', out=self.quiet, max_wait=0)
        self.assertIn(f'pid {self.dead_pid} (gone', str(raised.exception))
        self.assertIn('lane-sim-boot T4', str(raised.exception))

    def test_a_free_lock_with_a_live_pids_note_is_not_named(self):
        self.note('a.lock', os.getpid(), 'stale note')
        self.assertEqual(self.slots._read_holders(['a.lock']), [])


@unittest.skipUnless(shutil.which('xcodebuild'), 'needs Xcode')
class HostSlotTests(unittest.TestCase):
    """Heavy host tests (#350): two at once, one while a simulator job runs, separate from builds."""

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.state = Path(self.temporary.name) / 'state'
        # --plan fast runs this suite inside its own host slot; these tests start outside one.
        env = {k: v for k, v in os.environ.items() if k != 'SM_LANE_HOST_SLOT'}
        env['SM_LANE_STATE_DIR'] = str(self.state)
        self.env = env
        patch = unittest.mock.patch.dict(os.environ, env, clear=True)
        patch.start()
        self.addCleanup(patch.stop)
        sys.path.insert(0, str(SCRIPTS))
        import lane_slots
        self.slots = lane_slots
        self.quiet = open(os.devnull, 'w')
        self.addCleanup(self.quiet.close)
        self.holders = []

    def hold(self, label, seconds=30):
        """A separate process holding a host slot through the real wrapper until it is killed."""
        ready = Path(self.temporary.name) / f'{label}.ready'
        holder = subprocess.Popen([sys.executable, str(SCRIPTS / 'host-test-lane'), sys.executable, '-c',
                                   f'import pathlib, time; pathlib.Path({str(ready)!r}).touch(); time.sleep({seconds})'],
                                  env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.holders.append(holder)
        self.addCleanup(lambda: (holder.kill(), holder.wait()))
        for _ in range(200):
            if ready.exists():
                return holder
            time.sleep(0.05)
        self.fail(f'{label} never got a slot')

    def test_two_run_at_once_and_a_third_waits_naming_the_holders(self):
        self.hold('first')
        self.hold('second')
        with self.assertRaises(TimeoutError) as raised:
            with self.slots.host_test_slot('third', out=self.quiet, max_wait=0.3):
                pass
        self.assertIn('host-test-lane', str(raised.exception))  # who holds them, as xcodebuild-lane says

    def test_only_one_runs_while_a_simulator_job_runs(self):
        with self.slots.simulator_slot('a journey', out=self.quiet):
            self.hold('first')
            with self.assertRaisesRegex(TimeoutError, 'only 1 of 2'):
                with self.slots.host_test_slot('second', out=self.quiet, max_wait=0.3):
                    pass

    def test_a_run_holding_a_slot_passes_it_to_its_own_swift_test(self):
        self.hold('other')
        with self.slots.host_test_slot('verify-tests fast', out=self.quiet, max_wait=1):
            self.assertEqual(os.environ.get('SM_LANE_HOST_SLOT'), 'verify-tests fast')
            inner = subprocess.run([sys.executable, str(SCRIPTS / 'host-test-lane'), sys.executable, '-c',
                                    'import os; print(os.environ["SM_LANE_HOST_SLOT"])'],
                                   capture_output=True, text=True, timeout=10)
            self.assertEqual((inner.returncode, inner.stdout.strip()), (0, 'verify-tests fast'))
        self.assertIsNone(os.environ.get('SM_LANE_HOST_SLOT'))

    def test_host_tests_and_builds_never_wait_on_each_other(self):
        with self.slots.build_slot_file(0, 'build a', out=self.quiet), \
                self.slots.build_slot_file(1, 'build b', out=self.quiet):
            with self.slots.host_test_slot('tests', out=self.quiet, max_wait=0.5) as held:
                self.assertEqual(held['slot'], 0)
        self.hold('first')
        self.hold('second')
        with self.slots.build_slot('a build', out=self.quiet, max_wait=0.5) as held:
            self.assertEqual(held['slot'], 0)

    def test_the_wrapper_passes_the_exit_code_through(self):
        done = subprocess.run([str(SCRIPTS / 'host-test-lane'), sys.executable, '-c', 'raise SystemExit(3)'],
                              env=self.env, capture_output=True, text=True, timeout=30)
        self.assertEqual(done.returncode, 3)
        self.assertIn('host-test slot 1/2 acquired', done.stderr)


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

    def test_plan_fast_holds_a_host_slot_for_its_host_steps_and_takes_no_build_slot(self):
        spec = importlib.util.spec_from_file_location('verification_host', SCRIPTS / 'verify-tests.py')
        verification = importlib.util.module_from_spec(spec)
        sys.path.insert(0, str(SCRIPTS))
        spec.loader.exec_module(verification)
        import lane_slots
        seen = {}
        with tempfile.TemporaryDirectory() as temporary:
            state = Path(temporary) / 'state'
            env = {k: v for k, v in os.environ.items() if k != 'SM_LANE_HOST_SLOT'}
            env['SM_LANE_STATE_DIR'] = str(state)
            with unittest.mock.patch.dict(os.environ, env, clear=True):
                run = verification.Run(Path(temporary) / 'run', 'fast')

                def host_steps():
                    seen['marker'] = os.environ.get('SM_LANE_HOST_SLOT')
                    seen['held'] = lane_slots._held('host-test-slot-0.lock')
                    with lane_slots.build_slot('meanwhile', out=open(os.devnull, 'w'), max_wait=0.5) as build:
                        seen['build'] = build['slot']

                # The hot-file ratchet is its own step with its own tests; here it would run on this checkout (#2180 audit).
                with unittest.mock.patch.object(run, 'host_steps', side_effect=host_steps), \
                        unittest.mock.patch.object(run, 'hot_file_ratchet'):
                    run.fast()
            self.assertEqual(run.manifest['host_test_slot']['slot'], 0)
        self.assertTrue(seen['held'])
        self.assertIn('verify-tests fast', seen['marker'])
        self.assertEqual(seen['build'], 0)  # holding a host slot leaves both build slots free


if __name__ == '__main__':
    unittest.main()
