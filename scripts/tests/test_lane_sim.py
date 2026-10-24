import json
import os
from pathlib import Path
import signal
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
    counter = os.environ.get("FAKE_CREATE_COUNTER")
    if counter:  # each new device gets its own UDID: FRESH-0001, FRESH-0002, ...
        made = (int(open(counter).read()) if os.path.exists(counter) else 0) + 1
        open(counter, "w").write(str(made))
        print("FRESH-%04d" % made)
    else:
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
    if args[1] in os.environ.get("FAKE_STALL", "").split(","):  # a boot stall: never ready (stalling() below)
        time.sleep(60)
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


def stalling(*udids):
    """A device_processes() stand-in: the listed devices' SpringBoard restarts twice while they boot (a stall that
    even a first boot's tolerance of one change doesn't cover), every other device stays steady. Pair it with
    FAKE_STALL, so the fake simctl's bootstatus never reports those devices ready."""
    calls = {}

    def processes(udid):
        calls[udid] = calls.get(udid, 0) + 1
        return (10, 20 + min(calls[udid] - 1, 2)) if udid in udids else (10, 20)
    return processes


class DeviceTypeTests(unittest.TestCase):
    """The phone to create comes from what this Xcode has, not a fixed name (#2557 audit)."""

    @staticmethod
    def listing(*names):
        return {'devicetypes': [{'name': n, 'identifier': f'com.apple.CoreSimulator.SimDeviceType.{n}'} for n in names]}

    def test_the_usual_phone_is_kept_when_the_image_has_it(self):
        listing = self.listing('iPhone-17', 'iPhone-18', 'iPad-Pro')
        self.assertEqual(lane_sim.pick_device_type(listing), lane_sim.DEVICE_TYPE)

    def test_without_it_the_newest_plain_iPhone_is_used(self):
        # Pro, Air, SE and the iPad are not what the lane tests on; iPhone-9 must not beat iPhone-18 (numbers, not text).
        listing = self.listing('iPhone-9', 'iPhone-18', 'iPhone-18-Pro', 'iPhone-Air', 'iPhone-SE-3rd-generation', 'iPad-Pro')
        self.assertEqual(lane_sim.pick_device_type(listing), 'com.apple.CoreSimulator.SimDeviceType.iPhone-18')

    def test_with_no_plain_iPhone_it_fails_and_names_what_the_image_has(self):
        with self.assertRaises(lane_sim.BootError) as caught:
            lane_sim.pick_device_type(self.listing('iPad-Pro', 'Apple-Watch-Series-10'))
        message = str(caught.exception)
        self.assertIn('iPhone-17', message)
        self.assertIn('SimDeviceType.iPad-Pro', message)
        with self.assertRaises(lane_sim.BootError):
            lane_sim.pick_device_type({'devicetypes': []})

    def test_only_a_type_the_runtime_supports_is_picked(self):
        # The hosted xcode-27 image lists iPhone-17 but its iOS 27 runtime rejects it ("Incompatible device", simctl
        # 403, then exit 147): the first hosted T3 runs never started a simulator (#2557 follow-up).
        listing = self.listing('iPhone-17', 'iPhone-18', 'iPad-Pro')
        supported = {'com.apple.CoreSimulator.SimDeviceType.iPhone-18'}
        self.assertEqual(lane_sim.pick_device_type(listing, supported=supported),
                         'com.apple.CoreSimulator.SimDeviceType.iPhone-18')
        with self.assertRaises(lane_sim.BootError) as caught:
            lane_sim.pick_device_type(listing, supported={'com.apple.CoreSimulator.SimDeviceType.iPad-Pro'})
        self.assertIn('runtime', str(caught.exception))

    def test_the_runtime_listing_from_simctl_limits_the_types(self):
        runtime = 'com.apple.CoreSimulator.SimRuntime.iOS-27-1'
        types = self.listing('iPhone-17', 'iPhone-18')
        runtimes = {'runtimes': [
            {'identifier': 'com.apple.CoreSimulator.SimRuntime.iOS-27-0', 'supportedDeviceTypes': [
                {'identifier': 'com.apple.CoreSimulator.SimDeviceType.iPhone-17'}]},
            {'identifier': runtime, 'supportedDeviceTypes': [
                {'identifier': 'com.apple.CoreSimulator.SimDeviceType.iPhone-18'}]}]}
        with tempfile.TemporaryDirectory() as directory:
            fake = Path(directory) / 'simctl'
            fake.write_text('#!/bin/sh\nif [ "$2" = runtimes ]; then echo \'' + json.dumps(runtimes) + '\'\n'
                            'else echo \'' + json.dumps(types) + '\'; fi\n')
            fake.chmod(0o755)
            with mock.patch.dict(os.environ, {'SM_LANE_SIMCTL': str(fake)}):
                self.assertEqual(lane_sim.device_type(runtime), 'com.apple.CoreSimulator.SimDeviceType.iPhone-18')
                self.assertEqual(lane_sim.device_type('com.apple.CoreSimulator.SimRuntime.iOS-27-0'), lane_sim.DEVICE_TYPE)
                # A runtime the listing does not mention (or one with no list) does not limit the choice.
                self.assertEqual(lane_sim.device_type('com.apple.CoreSimulator.SimRuntime.iOS-99-0'), lane_sim.DEVICE_TYPE)

    def test_a_simctl_that_cannot_list_types_keeps_the_usual_phone(self):
        for fake in ('true', 'false', 'echo not-json'):
            with self.subTest(fake=fake), mock.patch.dict(os.environ, {'SM_LANE_SIMCTL': fake}):
                self.assertEqual(lane_sim.device_type(), lane_sim.DEVICE_TYPE)

    def test_the_listing_from_simctl_decides(self):
        with tempfile.TemporaryDirectory() as directory:
            fake = Path(directory) / 'simctl'
            fake.write_text('#!/bin/sh\necho \'' + json.dumps(self.listing('iPhone-18', 'iPad-Pro')) + '\'\n')
            fake.chmod(0o755)
            with mock.patch.dict(os.environ, {'SM_LANE_SIMCTL': str(fake)}):
                self.assertEqual(lane_sim.device_type(), 'com.apple.CoreSimulator.SimDeviceType.iPhone-18')


class RuntimePairTests(unittest.TestCase):
    """The runtime and the phone are chosen together: a runtime that cannot take any usual phone is not picked while
    another can (the hosted xcode-27 image has iOS 27.0 and 27.1, and 27.1 offered only iPhone-Duo)."""

    PREFIX = 'com.apple.CoreSimulator.'

    def runtimes(self, **versions):
        """versions: 'iOS-27-1' -> list of supported type names, or None for a runtime that does not list any."""
        entries = []
        for name, types in versions.items():
            platform, *numbers = name.split('-')
            entry = {'identifier': f'{self.PREFIX}SimRuntime.{name}', 'isAvailable': True, 'platform': platform,
                     'version': '.'.join(numbers)}
            if types is not None:
                entry['supportedDeviceTypes'] = [{'identifier': f'{self.PREFIX}SimDeviceType.{t}'} for t in types]
            entries.append(entry)
        return {'runtimes': entries}

    def pick(self, listing, major=27):
        return lane_sim.pick_runtime(listing, major)

    def test_table(self):
        rows = [
            ('the pinned phone is only on the older runtime', {'iOS-27-0': ['iPhone-17', 'iPhone-Air'], 'iOS-27-1': ['iPhone-Duo']},
             'iOS-27-0'),
            ('both have it: the newest runtime', {'iOS-27-0': ['iPhone-17'], 'iOS-27-1': ['iPhone-17', 'iPhone-18']}, 'iOS-27-1'),
            ('no runtime has it: the newest with a plain phone', {'iOS-27-0': ['iPhone-16'], 'iOS-27-1': ['iPhone-18']}, 'iOS-27-1'),
            ('a Duo-only newest is passed over for a plain phone', {'iOS-27-0': ['iPhone-16', 'iPad-Pro'], 'iOS-27-1': ['iPhone-Duo']},
             'iOS-27-0'),
            ('Pro and Air are not plain phones', {'iOS-27-0': ['iPhone-17-Pro', 'iPhone-Air'], 'iOS-27-1': ['iPhone-18-Pro']},
             'iOS-27-1'),
            ('a runtime that lists nothing is not limited', {'iOS-27-0': ['iPhone-Duo'], 'iOS-27-1': None}, 'iOS-27-1'),
            ('no usable phone anywhere: the newest, so the clone step reports it', {'iOS-27-0': ['iPhone-Duo'],
                                                                                    'iOS-27-1': ['iPad-Pro']}, 'iOS-27-1'),
            ('other platforms are ignored', {'iOS-27-0': ['iPhone-17'], 'tvOS-27-0': ['Apple-TV-4K']}, 'iOS-27-0'),
        ]
        for label, versions, expected in rows:
            with self.subTest(label):
                self.assertEqual(self.pick(self.runtimes(**versions)), f'{self.PREFIX}SimRuntime.{expected}')

    def test_only_the_pinned_major_and_available_runtimes_count(self):
        listing = self.runtimes(**{'iOS-26-4': ['iPhone-17'], 'iOS-27-0': ['iPhone-17']})
        self.assertEqual(self.pick(listing, 26), f'{self.PREFIX}SimRuntime.iOS-26-4')
        self.assertIsNone(self.pick(listing, 28))
        listing['runtimes'][1]['isAvailable'] = False
        self.assertIsNone(self.pick(listing, 27))

    def test_the_failure_lists_every_runtime_and_its_phones(self):
        listing = self.runtimes(**{'iOS-27-0': ['iPhone-Duo', 'iPad-Pro'], 'iOS-27-1': ['iPhone-Duo']})
        with tempfile.TemporaryDirectory() as directory:
            fake = Path(directory) / 'simctl'
            fake.write_text('#!/bin/sh\nif [ "$2" = runtimes ]; then echo \'' + json.dumps(listing) + '\'\n'
                            'else echo \'' + json.dumps(DeviceTypeTests.listing('iPhone-17', 'iPhone-Duo', 'iPad-Pro')) + '\'; fi\n')
            fake.chmod(0o755)
            with mock.patch.dict(os.environ, {'SM_LANE_SIMCTL': str(fake), 'SM_LANE_IOS_MAJOR': '27'}):
                runtime = lane_sim.newest_runtime(27)
                with self.assertRaises(lane_sim.BootError) as caught:
                    lane_sim.device_type(runtime)
        message = str(caught.exception)
        self.assertIn('iOS-27-0: iPhone-Duo', message)
        self.assertIn('iOS-27-1: iPhone-Duo', message)


class TemplateTests(unittest.TestCase):
    def test_failed_template_is_deleted_without_clone_or_completion_marker(self):
        commands = []

        def command(args, **kw):
            commands.append(args)
            if args == ['xcodebuild', '-version']:
                return 'Xcode test'
            if args[2] == 'list':
                return '{"devices": {}}'
            return 'T'

        def boot(udid, label, **kw):
            kw['info']['boot_window'] = (1, 2)

        for stage in ('boot', 'watcher'):
            with self.subTest(stage=stage), tempfile.TemporaryDirectory() as temporary, \
                    mock.patch.dict(os.environ, {'SM_LANE_STATE_DIR': temporary}), \
                    mock.patch.object(lane_sim.subprocess, 'check_output', side_effect=command), \
                    mock.patch.object(lane_sim, 'boot', side_effect=lane_sim.BootError('flood') if stage == 'boot' else boot) as guarded, \
                    mock.patch.object(lane_sim, 'unsafe_devices', return_value={'T': {'reason': 'flood'}}), \
                    mock.patch.object(lane_sim, 'start_watcher'), \
                    mock.patch.object(lane_sim, 'late_report', return_value=None), \
                    mock.patch.object(lane_sim.time, 'sleep'), \
                    mock.patch.object(lane_sim, 'release') as release:
                with self.assertRaisesRegex(lane_sim.BootError, 'flood' if stage == 'boot' else 'unsafe'):
                    lane_sim.clone_temporary('job', 'runtime')
                self.assertFalse((Path(temporary) / 't3-template.json').exists())
                guarded.assert_called_once()
                release.assert_called_once_with('T', keep=False)
        self.assertFalse(any('clone' in args for args in commands))

    def test_a_template_boot_stall_gets_one_fresh_template_and_the_clone_comes_from_it(self):
        runtime, devices, cloned, released = 'runtime', {}, [], []

        def command(args, **kw):
            if args == ['xcodebuild', '-version']:
                return 'Xcode test'
            if args[2] == 'list':
                return json.dumps({'devices': {runtime: list(devices.values())}})
            if args[2] == 'create':
                udid = f'T{len(released) + len(devices) + 1}'
                devices[udid] = {'udid': udid, 'name': args[3], 'state': 'Shutdown',
                                 'deviceTypeIdentifier': lane_sim.DEVICE_TYPE}
                return udid
            cloned.append(args[3])
            return 'CLONE'

        def boot(udid, label, **kw):
            if udid == 'T1':
                raise lane_sim.BootError('SpringBoard restarted (pid 1 -> 2) while booting.', stall=True)
            kw['info']['boot_window'] = (1, 2)
            return 30.0

        def release(udid, **kw):
            released.append(udid)
            if not kw.get('keep'):
                devices.pop(udid, None)

        with tempfile.TemporaryDirectory() as temporary, \
                mock.patch.dict(os.environ, {'SM_LANE_STATE_DIR': temporary}), \
                mock.patch.object(lane_sim.subprocess, 'check_output', side_effect=command), \
                mock.patch.object(lane_sim, 'boot', side_effect=boot), \
                mock.patch.object(lane_sim, 'start_watcher'), \
                mock.patch.object(lane_sim, 'release', side_effect=release), \
                mock.patch.object(lane_sim, 'post_stall') as posted, \
                mock.patch.object(lane_sim, 'late_report', return_value=None), \
                mock.patch.object(lane_sim, 'unsafe_devices', return_value={}), \
                mock.patch.object(lane_sim.time, 'sleep'):
            self.assertEqual(lane_sim.clone_temporary('job', runtime), 'CLONE')
            self.assertEqual(json.loads((Path(temporary) / 't3-template.json').read_text())['udid'], 'T2')
        self.assertEqual(cloned, ['T2'])
        self.assertEqual(released, ['T1', 'T2'])  # the stalled one deleted; the fresh one shut down and kept
        self.assertEqual(list(devices), ['T2'])
        self.assertIn('recovered', posted.call_args.args[2])

    def test_unsafe_missing_or_incompatible_templates_are_never_cloned(self):
        runtime = 'runtime'
        for reason in ('unsafe', 'missing', 'runtime', 'toolchain', 'unfinished'):
            with self.subTest(reason=reason), tempfile.TemporaryDirectory() as temporary:
                marker = Path(temporary) / 't3-template.json'
                marker.write_text(json.dumps({'udid': 'OLD', 'boot_window': [1, 2],
                                             'key': [runtime, lane_sim.DEVICE_TYPE,
                                                     'old-Xcode' if reason == 'toolchain' else 'Xcode test']}))
                devices = {} if reason == 'missing' else {'OLD': {
                    'udid': 'OLD', 'name': 'SM Lane T3 template', 'state': 'Shutdown',
                    'deviceTypeIdentifier': lane_sim.DEVICE_TYPE}}
                if reason == 'unfinished':
                    marker.unlink()
                cloned = []

                def command(args, **kw):
                    if args == ['xcodebuild', '-version']:
                        return 'Xcode test'
                    if args[2] == 'list':
                        return json.dumps({'devices': {runtime: list(devices.values())}})
                    if args[2] == 'create':
                        devices['NEW'] = {'udid': 'NEW', 'name': args[3], 'state': 'Shutdown',
                                          'deviceTypeIdentifier': lane_sim.DEVICE_TYPE}
                        return 'NEW'
                    cloned.append(args[3])
                    return 'CLONE'

                def boot(udid, label, **kw):
                    kw['info']['boot_window'] = (1, 2)

                with mock.patch.dict(os.environ, {'SM_LANE_STATE_DIR': temporary}), \
                        mock.patch.object(lane_sim.subprocess, 'check_output', side_effect=command), \
                        mock.patch.object(lane_sim, 'boot', side_effect=boot), \
                        mock.patch.object(lane_sim, 'start_watcher'), \
                        mock.patch.object(lane_sim, 'release'), \
                        mock.patch.object(lane_sim, 'late_report', return_value=None), \
                        mock.patch.object(lane_sim, 'unsafe_devices', return_value={'OLD': {}} if reason == 'unsafe' else {}), \
                        mock.patch.object(lane_sim.time, 'sleep'):
                    self.assertEqual(lane_sim.clone_temporary('job', 'new-runtime' if reason == 'runtime' else runtime),
                                     'CLONE')
                self.assertEqual(cloned, ['NEW'])

    def test_two_jobs_clone_one_template_after_guarded_first_boot_and_shutdown(self):
        events = []
        runtime = 'com.apple.CoreSimulator.SimRuntime.iOS-26-5'
        devices = {}

        def command(args, **kw):
            if args == ['xcodebuild', '-version']:
                return 'Xcode test'
            action = args[2]
            if action == 'list':
                return json.dumps({'devices': {runtime: list(devices.values())}})
            if action == 'create':
                events.append('create')
                devices['T'] = {'udid': 'T', 'name': args[3], 'state': 'Shutdown',
                                'deviceTypeIdentifier': lane_sim.DEVICE_TYPE}
                return 'T\n'
            if action == 'clone':
                self.assertEqual(devices['T']['state'], 'Shutdown')
                events.append('clone')
                return f'C{events.count("clone")}\n'
            self.fail(args)

        def boot(udid, label, **kw):
            self.assertTrue(kw['first_boot'])
            devices[udid]['state'] = 'Booted'
            kw['info']['boot_window'] = (1, 2)
            events.append('boot')

        def release(udid, **kw):
            self.assertTrue(kw['keep'])
            devices[udid]['state'] = 'Shutdown'
            events.append('shutdown')

        with tempfile.TemporaryDirectory() as temporary, \
                mock.patch.dict(os.environ, {'SM_LANE_STATE_DIR': temporary}), \
                mock.patch.object(lane_sim.subprocess, 'check_output', side_effect=command), \
                mock.patch.object(lane_sim, 'boot', side_effect=boot), \
                mock.patch.object(lane_sim, 'start_watcher') as watcher, \
                mock.patch.object(lane_sim, 'release', side_effect=release), \
                mock.patch.object(lane_sim, 'unsafe_devices', return_value={}), \
                mock.patch.object(lane_sim, 'late_report', return_value=None), \
                mock.patch.object(lane_sim.time, 'sleep'):
            self.assertEqual(lane_sim.clone_temporary('job1', runtime), 'C1')
            self.assertEqual(lane_sim.clone_temporary('job2', runtime), 'C2')
            watcher.assert_called_once()
        self.assertEqual(events, ['create', 'boot', 'shutdown', 'clone', 'clone'])


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
        self.comments = folder / 'gh-comments.txt'  # never the real #184
        gh = folder / 'gh'
        gh.write_text(f'#!/bin/sh\nprintf "%s\\n---\\n" "$*" >> "{self.comments}"\n')
        gh.chmod(0o755)
        self.env = {'SM_LANE_STATE_DIR': str(folder / 'state'), 'SM_LANE_SIMCTL': str(fake),
                    'SM_LANE_CRASH_REPORTS': str(folder / 'reports'), 'FAKE_RECORD': str(self.record),
                    'SM_LANE_MEMORY_PRESSURE': '1', 'SM_LANE_GH': str(gh)}
        patches = [mock.patch.dict(os.environ, self.env), mock.patch.object(lane_sim, 'CRASH_POLL_SECONDS', 0.05),
                   mock.patch.object(lane_slots, 'POLL_SECONDS', 0.05)]
        for patch in patches:
            patch.start()
            self.addCleanup(patch.stop)
        self.quiet = open(os.devnull, 'w')
        self.addCleanup(self.quiet.close)
        self.addCleanup(self.end_watchers)  # runs before the patches and the folder go (cleanups run last-in first)

    def end_watchers(self):
        """Stop every watcher this test started, even when the test failed before --done.

        Two watchers from a test that timed out kept running for 1.5 h, holding slot locks in a deleted
        temporary folder (#184). The stop flag is the watcher's own way out; a kill is the fallback.
        """
        for pid_file in Path(self.env['SM_LANE_STATE_DIR']).glob('watch-*.pid'):
            udid = pid_file.name[len('watch-'):-len('.pid')]
            lane_sim.watch_files(udid)[0].write_text('test ended\n')
            try:
                pid = int(pid_file.read_text())
            except (OSError, ValueError):
                continue
            for _ in range(100):
                command = subprocess.run(['ps', '-o', 'command=', '-p', str(pid)], capture_output=True, text=True).stdout
                if f'--watch {udid}' not in command:  # gone (or the pid now belongs to something else)
                    break
                time.sleep(0.1)
            else:
                os.kill(pid, signal.SIGKILL)

    def records(self):
        """What the fake simctl did, without timestamps (see timed() for those)."""
        return [{k: v for k, v in r.items() if k != 'at'} for r in self.timed()]

    def timed(self):
        return [json.loads(line) for line in self.record.read_text().splitlines()] if self.record.exists() else []

    def test_a_healthy_boot_returns_when_ready_and_marks_nothing(self):
        self.assertGreaterEqual(lane_sim.boot(UDID, 'test', out=self.quiet), 0)
        self.assertEqual([r.get('boot') for r in self.records() if 'boot' in r], [UDID])
        self.assertEqual(lane_sim.unsafe_devices(), {})

    def test_a_finished_boot_marks_the_simulator_quiet_from_that_moment(self):
        # #705: the host app stalled when launched within about 16 s of the boot finishing.
        self.assertIsNone(lane_sim.seconds_quiet(UDID))
        lane_sim.boot(UDID, 'test', out=self.quiet)
        self.assertLess(lane_sim.seconds_quiet(UDID), 5)

    def test_a_failed_boot_marks_nothing_quiet(self):
        with mock.patch.dict(os.environ, {'FAKE_BOOT': 'invalid'}):
            with self.assertRaises(lane_sim.BootError):
                lane_sim.boot(UDID, 'test', out=self.quiet)
        self.assertIsNone(lane_sim.seconds_quiet(UDID))

    def test_quiet_markers_age_from_their_last_mark_and_old_ones_are_pruned(self):
        lane_sim.mark_quiet(UDID)
        marker = lane_sim.quiet_marker(UDID)
        old = marker.parent / 'OLD-DEVICE'
        old.touch()
        os.utime(old, (time.time() - 3 * 24 * 3600,) * 2)
        os.utime(marker, (time.time() - 30,) * 2)
        self.assertAlmostEqual(lane_sim.seconds_quiet(UDID), 30, delta=2)
        lane_sim.mark_quiet(UDID)
        self.assertLess(lane_sim.seconds_quiet(UDID), 2)
        self.assertEqual([path.name for path in marker.parent.iterdir()], [UDID])

    def test_marking_quiet_survives_a_state_dir_that_cannot_be_written(self):
        blocker = Path(self.env['SM_LANE_STATE_DIR']).parent / 'blocked'
        blocker.write_text('a file where the state folder should be')
        with mock.patch.dict(os.environ, {'SM_LANE_STATE_DIR': str(blocker)}):
            lane_sim.mark_quiet(UDID)  # must not raise
            self.assertIsNone(lane_sim.seconds_quiet(UDID))

    def test_a_failed_boot_stops_marks_the_device_and_is_never_retried(self):
        with mock.patch.dict(os.environ, {'FAKE_BOOT': 'invalid'}):
            with self.assertRaisesRegex(lane_sim.BootError, 'Invalid argument.*do not retry'):
                lane_sim.boot(UDID, 'test', out=self.quiet)
        self.assertIn({'shutdown': UDID}, self.records())
        self.assertIn('Invalid argument', lane_sim.unsafe_devices()[UDID]['reason'])
        with self.assertRaisesRegex(lane_sim.BootError, 'marked unsafe'):
            lane_sim.boot(UDID, 'retry', out=self.quiet)
        self.assertEqual(sum('boot' in r for r in self.records()), 1)  # the retry never reached simctl

    def poll_loop(self, *, ready=(), springboard=((None, None),), reports=(), timeout=900, tolerate_until=None):
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
                self.tolerated = lane_sim.wait_until_ready(
                    UDID, is_ready, monitor, lambda: reports.pop(0) if reports else None, timeout,
                    clock=lambda: now[0], sleep=sleep, poll=1.0, tolerate_until=tolerate_until)
                outcome = 'ready'
            except lane_sim.BootError as error:
                outcome = str(error)
        return outcome, polls[0], stops

    # The owner's rule (#184, "fine with one simulator failure or crash"): one SpringBoard change in the
    # first 30 s of a first boot is tolerated; a second one, or any crash report, still stops the boot.
    def test_a_first_boot_tolerates_one_early_springboard_change(self):
        outcome, polls, stops = self.poll_loop(ready=[False] * 4 + [True], tolerate_until=30,
                                               springboard=[(10, 20), (10, 20), (10, 21), (10, 21)])
        self.assertEqual((outcome, stops), ('ready', []))
        self.assertEqual(self.tolerated, 'SpringBoard restarted (pid 20 -> 21)')
        outcome, _, stops = self.poll_loop(ready=[False] * 6 + [True], tolerate_until=30,
                                           springboard=[(10, 20), (10, None), (10, None), (10, None), (10, None), (10, 22)])
        self.assertEqual((outcome, stops), ('ready', []))  # a vanish, then a new SpringBoard: one change

    def test_a_second_change_in_a_first_boot_still_stops(self):
        outcome, _, stops = self.poll_loop(tolerate_until=30, springboard=[(10, 20), (10, 21), (10, 22)])
        self.assertIn('SpringBoard restarted (pid 21 -> 22) while booting', outcome)
        self.assertEqual(stops, ['SpringBoard restarted (pid 21 -> 22) during boot'])

    def test_a_change_after_the_first_30_s_still_stops(self):
        states = [(10, 20)] * 35 + [(10, 21)]
        outcome, _, stops = self.poll_loop(tolerate_until=30, springboard=states)
        self.assertIn('SpringBoard restarted (pid 20 -> 21) while booting', outcome)

    def test_a_crash_report_stops_a_first_boot_even_after_a_tolerated_change(self):
        outcome, _, stops = self.poll_loop(tolerate_until=30, springboard=[(10, 20), (10, 21), (10, 21)],
                                           reports=[None, None, Path('SpringBoard-x.ips')])
        self.assertIn('SpringBoard-x.ips while booting', outcome)

    def test_a_device_that_is_not_booting_for_the_first_time_gets_no_tolerance(self):
        outcome, _, _ = self.poll_loop(springboard=[(10, 20), (10, 21)])
        self.assertIn('SpringBoard restarted', outcome)

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

    def test_every_springboard_change_during_boot_is_logged_with_its_time(self):
        # Three first boots stopped on an early SpringBoard exit with no crash report (#184); the log is
        # how the next ones get explained rather than inferred.
        import io
        out = io.StringIO()
        now = [0.0]
        states = [(10, None), (10, 20), (10, 20), (10, None)]
        monitor = lane_sim.SpringBoardMonitor(UDID, lambda udid: states.pop(0) if len(states) > 1 else states[0],
                                              grace=3, clock=lambda: now[0])

        def sleep(seconds):
            now[0] += seconds

        with mock.patch.object(lane_sim, 'stop'):
            with self.assertRaises(lane_sim.BootError):
                lane_sim.wait_until_ready(UDID, lambda: False, monitor, lambda: None, 900, clock=lambda: now[0],
                                          sleep=sleep, poll=1.0, out=out)
        self.assertEqual(out.getvalue().splitlines(), [
            '[lane] +1.0s SpringBoard pid 20 up (launchd_sim 10)',
            '[lane] +3.0s SpringBoard pid 20 gone, launchd_sim 10 still running'])

    def test_a_shutdown_is_logged_once(self):
        events = []
        monitor = lane_sim.SpringBoardMonitor(UDID, sequence((10, 20), (None, None)), on_event=events.append)
        for _ in range(5):
            monitor.check()
        self.assertEqual(events, ['SpringBoard pid 20 up (launchd_sim 10)', 'device shut down'])

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

    def hosted_boot(self, *names, hosted=True):
        """Boot with these crash reports for the device already written and counted as new (#2575)."""
        folder = Path(self.env['SM_LANE_CRASH_REPORTS'])
        for name in names:
            (folder / name).write_text(f'{{"app_name":"x"}}\n{{"path": "com.apple.CoreSimulator.SimDevice.{UDID}"}}')
        evidence = Path(self.temporary.name) / 'evidence'
        env = {'SM_LANE_EVIDENCE_DIR': str(evidence), 'SM_LANE_GITHUB_HOSTED': '1' if hosted else ''}
        with mock.patch.dict(os.environ, env), mock.patch.object(lane_sim, 'crash_snapshot', return_value={}), \
                mock.patch.dict(lane_sim._tolerated_reports, clear=True):
            lane_sim.boot(UDID, 'test', out=self.quiet)
        return evidence / 'tolerated-crash-reports'

    def test_a_hosted_boot_goes_on_past_an_app_intents_daemon_crash_and_keeps_the_report(self):
        # #2575: every hosted T3 on iOS 27.0 stopped on AppIntentsLiveEntityService's first-boot crash and ran nothing.
        kept = self.hosted_boot('AppIntentsLiveEntityService-2026-10-23-211854.ips')
        self.assertNotIn(UDID, lane_sim.unsafe_devices())
        self.assertTrue((kept / 'AppIntentsLiveEntityService-2026-10-23-211854.ips.log').is_file())
        events = (Path(self.env['SM_LANE_STATE_DIR']) / 'boot-events.log').read_text()
        self.assertIn('tolerated on a hosted Mac: AppIntentsLiveEntityService-2026-10-23-211854.ips', events)

    def test_the_same_crash_stops_a_boot_on_a_build_mac(self):
        with self.assertRaisesRegex(lane_sim.BootError, 'AppIntentsLiveEntityService-2026-10-23-211854.ips while booting'):
            self.hosted_boot('AppIntentsLiveEntityService-2026-10-23-211854.ips', hosted=False)
        self.assertIn(UDID, lane_sim.unsafe_devices())

    def test_a_hosted_boot_still_stops_on_any_other_crash(self):
        with self.assertRaisesRegex(lane_sim.BootError, 'SpringBoard-2026-10-23-211854.ips while booting'):
            self.hosted_boot('AppIntentsLiveEntityService-2026-10-23-211850.ips', 'SpringBoard-2026-10-23-211854.ips')

    def test_a_third_report_of_the_tolerated_daemon_is_a_flood(self):
        with self.assertRaisesRegex(lane_sim.BootError, 'AppIntentsLiveEntityService-.*while booting'):
            self.hosted_boot(*(f'AppIntentsLiveEntityService-2026-10-23-21185{n}.ips' for n in range(3)))
        self.assertIn(UDID, lane_sim.unsafe_devices())

    def test_the_crash_check_during_tests_still_counts_the_tolerated_daemon(self):
        # #2579 audit: verify-tests.py and check_posterboard_repair.py call new_crash while the app tests run.
        # The hosted boot's exemption must not hide this daemon's crashes there, or a flood needs 5 reports, not 3.
        folder = Path(self.env['SM_LANE_CRASH_REPORTS'])
        (folder / 'AppIntentsLiveEntityService-2026-10-23-211854.ips').write_text(
            f'{{"app_name":"x"}}\n{{"path": "com.apple.CoreSimulator.SimDevice.{UDID}"}}')
        with mock.patch.dict(os.environ, {'SM_LANE_GITHUB_HOSTED': '1',
                                          'SM_LANE_EVIDENCE_DIR': str(Path(self.temporary.name) / 'evidence')}), \
                mock.patch.dict(lane_sim._tolerated_reports, clear=True):
            self.assertEqual(lane_sim.new_crash(folder, {}, UDID).name, 'AppIntentsLiveEntityService-2026-10-23-211854.ips')
            self.assertEqual(lane_sim._tolerated_reports, {})

    def test_report_process_reads_the_name_before_the_date(self):
        for name, process in [('AppIntentsLiveEntityService-2026-10-23-211854.ips', 'AppIntentsLiveEntityService'),
                              ('AppIntentsLiveEntityService-2026-10-23-211854-2.ips', 'AppIntentsLiveEntityService'),
                              ('com.apple.Foo-Bar-2026-10-23-211854.ips', 'com.apple.Foo-Bar'),
                              ('AppIntentsLiveEntityServiceX-2026-10-23-211854.ips', 'AppIntentsLiveEntityServiceX'),
                              ('SpringBoard-late.ips', 'SpringBoard-late')]:
            self.assertEqual(lane_sim.report_process(Path(name)), process, name)

    def test_a_hosted_late_report_check_skips_the_tolerated_daemon(self):
        import datetime
        folder = Path(self.env['SM_LANE_CRASH_REPORTS'])
        stamp = datetime.datetime.fromtimestamp(time.time()).astimezone().strftime('%Y-%m-%d %H:%M:%S.%f %z')
        (folder / 'AppIntentsLiveEntityService-2026-10-23-211854.ips').write_text(
            f'{{"app_name":"x"}}\n{{"captureTime" : "{stamp}", "path": "com.apple.CoreSimulator.SimDevice.{UDID}"}}')
        window = (time.time() - 10, time.time() + 10)
        self.assertIsNotNone(lane_sim.late_report(folder, UDID, window))
        with mock.patch.dict(os.environ, {'SM_LANE_GITHUB_HOSTED': '1',
                                          'SM_LANE_EVIDENCE_DIR': str(Path(self.temporary.name) / 'evidence')}), \
                mock.patch.dict(lane_sim._tolerated_reports, clear=True):
            self.assertIsNone(lane_sim.late_report(folder, UDID, window))

    def test_a_crash_report_renamed_during_the_scan_does_not_fail_the_boot(self):
        # #822: macOS writes each report as a hidden `.Name-date.ips` and then renames it. A rename between
        # crash_snapshot's glob and its stat raised FileNotFoundError and failed the boot (#767 hit the same
        # race in verify-tests' copy of the scan).
        folder = Path(self.env['SM_LANE_CRASH_REPORTS'])

        class RenamingFolder:
            """Lists the real folder, then renames every hidden report, as macOS does, before the caller reads it."""

            def __init__(self, folder):
                self.folder = folder

            def is_dir(self):
                return self.folder.is_dir()

            def glob(self, pattern):
                found = list(self.folder.glob(pattern))
                for path in found:
                    if path.name.startswith('.'):
                        path.rename(path.with_name(path.name[1:]))
                return iter(found)

        (folder / '.SpringBoard-2026-10-04-095145.ips').write_text('com.apple.CoreSimulator.SimDevice.99999999-0000')
        with mock.patch.object(lane_sim, 'crash_reports_dir', return_value=RenamingFolder(folder)):
            lane_sim.boot(UDID, 'test', out=self.quiet)
        self.assertNotIn(UDID, lane_sim.unsafe_devices())

    def test_the_crash_scans_skip_hidden_and_vanished_reports(self):
        import datetime
        folder = Path(self.env['SM_LANE_CRASH_REPORTS'])
        stamp = datetime.datetime.fromtimestamp(time.time()).astimezone().strftime('%Y-%m-%d %H:%M:%S.%f %z')
        report = ('{"app_name":"x","timestamp":"2000-01-01 00:00:00.00 +0000"}\n'
                  f'{{"captureTime" : "{stamp}", "path": "com.apple.CoreSimulator.SimDevice.{UDID}"}}')
        window = (time.time() - 10, time.time() + 10)

        # A hidden report is still being written: not a crash yet, and not part of the baseline.
        (folder / '.SpringBoard-2026-10-04-095145.ips').write_text(report)
        self.assertEqual(lane_sim.crash_snapshot(folder), {})
        self.assertIsNone(lane_sim.new_crash(folder, {}, UDID))
        self.assertIsNone(lane_sim.late_report(folder, UDID, window))

        # Once renamed, it is the real report, and each scan finds it.
        (folder / '.SpringBoard-2026-10-04-095145.ips').rename(folder / 'SpringBoard-2026-10-04-095145.ips')
        self.assertEqual(lane_sim.new_crash(folder, {}, UDID).name, 'SpringBoard-2026-10-04-095145.ips')
        self.assertEqual(lane_sim.late_report(folder, UDID, window).name, 'SpringBoard-2026-10-04-095145.ips')

        class VanishingFolder:
            """Lists the real folder, then deletes what it listed before the caller reads it."""

            def is_dir(self):
                return True

            def glob(self, pattern):
                found = list(folder.glob(pattern))
                for path in found:
                    path.unlink()
                return iter(found)

        self.assertEqual(lane_sim.crash_snapshot(VanishingFolder()), {})

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
        self.assertEqual((info['pressure'], info['pressure_waited'], info['tolerated']), ('normal', 0, None))
        other = '22222222-0000-0000-0000-000000000000'
        with mock.patch.dict(os.environ, {'FAKE_BOOT': 'invalid', 'SM_LANE_MEMORY_PRESSURE': '4'}), \
                mock.patch.object(lane_sim, 'PRESSURE_WAIT', 0):
            with self.assertRaisesRegex(lane_sim.BootError, 'Invalid argument.*Memory pressure at boot: critical'):
                lane_sim.boot(other, 'test', out=self.quiet)

    def test_it_never_boots_a_third_simulator(self):
        with mock.patch.dict(os.environ, {'FAKE_BOOTED': 'X,Y'}):
            with self.assertRaisesRegex(lane_sim.BootError, 'another simulator stayed booted'):
                lane_sim.wait_for_room(UDID, max_wait=0.1, poll=0.02)
        with mock.patch.dict(os.environ, {'FAKE_BOOTED': 'X'}):
            lane_sim.wait_for_room(UDID, max_wait=0.1, poll=0.02)  # the slots decide about a second one
        seen = iter([{'X', 'Y'}, {'X'}])
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
                mock.patch.object(runner, 'prepare_t3_build', return_value=('PASS', ['prepared'])), \
                mock.patch.dict(os.environ, {'SM_LANE_MEMORY_PRESSURE': '2'}), \
                mock.patch.object(lane_sim, 'clone_temporary', side_effect=AssertionError('made a simulator')), \
                lane_slots.simulator_slot('the Test Desk', out=self.quiet), mock.patch('sys.stdout', self.quiet):
            verdict, _, _, details, _, _ = runner.run_t3(['AppNavigationStateTests'], 'r1', Path(self.temporary.name))
        self.assertEqual(verdict, 'INCONCLUSIVE')
        self.assertIn('simulator slots stayed busy', details[0])
        self.assertIn('memory pressure is warn', details[0])

    # The second slot (#184): a job may always start alone; joining a running one needs normal memory
    # pressure and the second slot switched on.
    def test_a_second_job_joins_only_while_pressure_is_normal_and_the_slot_is_on(self):
        with lane_slots.simulator_slot('first', out=self.quiet):
            with lane_slots.simulator_slot('second', out=self.quiet, max_wait=1):
                self.assertEqual(lane_slots.simulator_jobs_running(), 2)
                with self.assertRaises(TimeoutError):  # never a third
                    with lane_slots.simulator_slot('third', out=self.quiet, max_wait=0.3):
                        pass
            with mock.patch.dict(os.environ, {'SM_LANE_MEMORY_PRESSURE': '2'}):
                with self.assertRaisesRegex(TimeoutError, 'memory pressure is warn'):
                    with lane_slots.simulator_slot('second', out=self.quiet, max_wait=0.3):
                        pass
            lane_slots.disable_second_slot('test')
            with self.assertRaisesRegex(TimeoutError, 'switched off'):
                with lane_slots.simulator_slot('second', out=self.quiet, max_wait=0.3):
                    pass
            lane_slots.enable_second_slot()
            with lane_slots.simulator_slot('second', out=self.quiet, max_wait=1):
                pass

    def test_a_lone_job_starts_whatever_the_pressure(self):
        with mock.patch.dict(os.environ, {'SM_LANE_MEMORY_PRESSURE': '4'}):
            with lane_slots.simulator_slot('alone', out=self.quiet, max_wait=1):
                self.assertEqual(lane_slots.simulator_jobs_running(), 1)

    def test_a_free_first_slot_is_not_a_way_around_the_brake(self):
        # First job ended, second still running: a new job would be the second one again.
        handle = lane_slots.acquire([lane_slots.SIMULATOR_SLOTS[1]], 'simulator slot', 'running second', self.quiet)[0]
        try:
            with mock.patch.dict(os.environ, {'SM_LANE_MEMORY_PRESSURE': '2'}):
                with self.assertRaises(TimeoutError):
                    with lane_slots.simulator_slot('new', out=self.quiet, max_wait=0.3):
                        pass
        finally:
            lane_slots.release_handle(handle)

    def test_the_boot_reports_one_or_two_simulator_periods(self):
        info = {}
        with lane_slots.simulator_slot('this job', out=self.quiet):
            lane_sim.boot(UDID, 'test', out=self.quiet, info=info)
        self.assertEqual(info['period'], 'one-simulator')
        with lane_slots.simulator_slot('other job', out=self.quiet), lane_slots.simulator_slot('this job', out=self.quiet):
            lane_sim.boot('33333333-0000-0000-0000-000000000000', 'test', out=self.quiet, info=info)
        self.assertEqual(info['period'], 'two-simulator')
        self.assertIn('two-simulator period', (Path(self.env['SM_LANE_STATE_DIR']) / 'boot-events.log').read_text())

    def test_the_watcher_goes_back_to_one_after_ten_minutes_of_warn_with_two_up(self):
        clock = iter(range(0, 100000, 100))  # each look at the clock is 100 s later
        announced = []
        with lane_slots.simulator_slot('first', out=self.quiet), lane_slots.simulator_slot('second', out=self.quiet), \
                mock.patch.dict(os.environ, {'SM_LANE_MEMORY_PRESSURE': '2'}), \
                mock.patch.object(lane_sim, 'announce', side_effect=announced.append):
            states = [(10, 20)] * 12 + [(None, None)]
            monitor = lane_sim.SpringBoardMonitor(UDID, lambda udid: states.pop(0) if len(states) > 1 else states[0])
            lane_sim.watch(UDID, poll=0.001, monitor=monitor, now=lambda: next(clock))
        self.assertFalse(lane_slots.second_slot_status()[0])
        self.assertIn('switched off', lane_slots.second_slot_status()[1])
        self.assertEqual(len(announced), 1)
        self.assertIn('back to one simulator', announced[0])

    def test_the_switch_on_the_command_line(self):
        helper = [sys.executable, str(SCRIPTS / 'lane-sim-boot'), '--second-slot']
        env = dict(os.environ)
        off = subprocess.run(helper + ['off', 'journeys', 'too', 'slow'], env=env, capture_output=True, text=True, timeout=60)
        self.assertIn('not available (the second slot is switched off', off.stdout)
        comment = self.comments.read_text()
        self.assertIn('issue comment 184', comment)
        self.assertIn('back to one simulator.** journeys too slow (switched off by hand)', comment)
        subprocess.run(helper + ['off', 'again'], env=env, capture_output=True, timeout=60)
        self.assertEqual(self.comments.read_text(), comment)  # said once, not again while it stays off
        on = subprocess.run(helper + ['on'], env=env, capture_output=True, text=True, timeout=60)
        self.assertIn('second simulator slot: available', on.stdout)
        self.assertNotEqual(subprocess.run(helper + ['off'], env=env, capture_output=True, text=True).returncode, 0)

    # An automatic switch-off expires (#2157): the 2026-09-29 one stayed three weeks with nothing to lift it.
    HOUR = 3600

    def test_an_automatic_switch_off_comes_back_on_after_its_cooldown_once_pressure_is_normal(self):
        lane_slots.disable_second_slot('pressure stayed at warn', now=0)
        off = Path(self.env['SM_LANE_STATE_DIR']) / lane_slots.SECOND_SLOT_OFF
        allowed, why = lane_slots.second_slot_status(now=4 * self.HOUR - 1)
        self.assertFalse(allowed)
        self.assertIn('comes back on after', why)
        allowed, why = lane_slots.second_slot_status(now=4 * self.HOUR + 1)
        self.assertTrue(allowed, why)
        self.assertIn('came back on after its cooldown', why)
        self.assertFalse(off.exists())

    def test_an_expired_switch_off_stays_off_while_pressure_is_above_normal(self):
        lane_slots.disable_second_slot('pressure stayed at warn', now=0)
        for level, name in (('2', 'warn'), ('4', 'critical')):
            with mock.patch.dict(os.environ, {'SM_LANE_MEMORY_PRESSURE': level}):
                allowed, why = lane_slots.second_slot_status(now=30 * self.HOUR)
            self.assertFalse(allowed)
            self.assertIn(f'once memory pressure is normal (now {name})', why)
        self.assertTrue((Path(self.env['SM_LANE_STATE_DIR']) / lane_slots.SECOND_SLOT_OFF).exists())
        self.assertTrue(lane_slots.second_slot_status(now=30 * self.HOUR)[0])

    def test_each_repeat_trip_within_a_week_doubles_the_cooldown_up_to_a_day(self):
        expected = [4, 8, 16, 24, 24]
        start = 0
        for hours in expected:
            lane_slots.disable_second_slot('trip', now=start)
            self.assertEqual(lane_slots.second_slot_back_on_at(), start + hours * self.HOUR)
            self.assertTrue(lane_slots.second_slot_status(now=start + hours * self.HOUR + 1)[0])
            start += hours * self.HOUR + 2
        # A week with no trip resets it to the base cooldown.
        start += 8 * 24 * self.HOUR
        lane_slots.disable_second_slot('trip', now=start)
        self.assertEqual(lane_slots.second_slot_back_on_at(), start + 4 * self.HOUR)

    def test_a_switch_off_by_hand_never_expires(self):
        lane_slots.disable_second_slot('journeys too slow', by_hand=True, now=0)
        allowed, why = lane_slots.second_slot_status(now=30 * 24 * self.HOUR)
        self.assertFalse(allowed)
        self.assertIn('stays off until switched on', why)
        self.assertIsNone(lane_slots.second_slot_back_on_at())
        lane_slots.enable_second_slot()
        self.assertTrue(lane_slots.second_slot_status()[0])

    def test_a_switch_off_by_hand_after_an_automatic_one_never_expires(self):
        # A hand switch-off while an automatic one is active must replace it, not leave its end time (#2158 audit).
        announced = []
        with mock.patch.object(lane_sim, 'announce', side_effect=announced.append):
            self.assertTrue(lane_slots.disable_second_slot('memory pressure', now=0))
            self.assertTrue(lane_sim.back_to_one_simulator('keep it at one (switched off by hand)', by_hand=True))
            self.assertFalse(lane_sim.back_to_one_simulator('again (switched off by hand)', by_hand=True))
        self.assertEqual(len(announced), 1)
        self.assertIn('stays off until someone runs', announced[0])
        self.assertIsNone(lane_slots.second_slot_back_on_at())
        allowed, why = lane_slots.second_slot_status(now=30 * 24 * self.HOUR)
        self.assertFalse(allowed)
        self.assertIn('keep it at one', why)
        self.assertIn('stays off until switched on', why)

    def test_a_switch_off_written_before_the_expiry_counts_from_its_file_time(self):
        off = Path(self.env['SM_LANE_STATE_DIR']) / lane_slots.SECOND_SLOT_OFF
        off.parent.mkdir(parents=True, exist_ok=True)
        off.write_text('2026-09-29T10:12:00: memory pressure stayed above normal for over 10 min\n')
        os.utime(off, (1000, 1000))
        allowed, why = lane_slots.second_slot_status(now=1000 + 4 * self.HOUR - 1)
        self.assertFalse(allowed)
        self.assertIn('memory pressure stayed above normal', why)
        self.assertTrue(lane_slots.second_slot_status(now=1000 + 4 * self.HOUR + 1)[0])

    def test_a_switch_off_by_hand_written_before_the_expiry_never_expires(self):
        # The old `lane-sim-boot --second-slot off` wrote the same one-line shape, marked by its reason (#2158 audit).
        off = Path(self.env['SM_LANE_STATE_DIR']) / lane_slots.SECOND_SLOT_OFF
        off.parent.mkdir(parents=True, exist_ok=True)
        for text in ('2026-10-18T09:00:00: J5 too slow (switched off by hand)\n',
                     '2026-10-18T09:00:00: J5 too slow (switched off by hand)  \r\n',
                     '',  # created by hand some other way: not the old automatic writer's shape
                     'off while I look at the J5 runs\n'):
            with self.subTest(text=text):
                off.write_text(text)
                os.utime(off, (1000, 1000))
                allowed, why = lane_slots.second_slot_status(now=1000 + 30 * 24 * self.HOUR)
                self.assertFalse(allowed)
                self.assertIn('by hand', why)
                self.assertTrue(off.exists())
                self.assertIsNone(lane_slots.second_slot_back_on_at())

    def test_the_announcement_says_when_an_automatic_switch_off_ends(self):
        announced = []
        with mock.patch.object(lane_sim, 'announce', side_effect=announced.append):
            self.assertTrue(lane_sim.back_to_one_simulator('a two-simulator T3 run timed out.'))
            self.assertFalse(lane_sim.back_to_one_simulator('again'))
            lane_slots.enable_second_slot()
            self.assertTrue(lane_sim.back_to_one_simulator('looking into it', by_hand=True))
        self.assertEqual(len(announced), 2)
        self.assertIn('comes back on by itself after', announced[0])
        self.assertIn('stays off until someone runs', announced[1])

    def test_a_second_simulator_job_waits_until_the_first_is_done_while_the_second_slot_is_off(self):
        helper = [sys.executable, str(SCRIPTS / 'lane-sim-boot')]
        lane_slots.disable_second_slot('test')
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

    def test_a_first_boot_with_one_change_boots_and_is_logged(self):
        info = {}
        with mock.patch.dict(os.environ, {'FAKE_READY_SECONDS': '1'}), \
                mock.patch.object(lane_sim, 'CRASH_POLL_SECONDS', 0.05), \
                mock.patch.object(lane_sim, 'device_processes', sequence((10, 20), (10, 20), (10, 21))):
            lane_sim.boot(UDID, 'test', out=self.quiet, info=info, first_boot=True)
        self.assertEqual(info['tolerated'], 'SpringBoard restarted (pid 20 -> 21)')
        self.assertEqual(len(info['boot_window']), 2)
        log = (Path(self.env['SM_LANE_STATE_DIR']) / 'boot-events.log').read_text()
        self.assertIn('boot started (first boot', log)
        self.assertIn('tolerated: SpringBoard restarted (pid 20 -> 21)', log)
        self.assertIn('one change tolerated', log)
        self.assertNotIn(UDID, lane_sim.unsafe_devices())

    def test_a_good_boot_is_logged_too(self):
        lane_sim.boot(UDID, 'test', out=self.quiet, first_boot=True)
        log = (Path(self.env['SM_LANE_STATE_DIR']) / 'boot-events.log').read_text()
        self.assertRegex(log, r'ready after \d+s, no SpringBoard change')

    def test_the_crash_time_comes_from_the_report_body_not_its_write_time(self):
        header = '{"app_name":"SpringBoard","timestamp":"2026-09-29 09:59:24.00 -0400"}\n'
        body = '{"captureTime" : "2026-09-29 09:58:01.9897 -0400"}'
        self.assertEqual(lane_sim.report_time(header + body), lane_sim.report_time(
            '{"timestamp":"2026-09-29 09:58:01.9897 -0400"}\n{}'))
        self.assertIsNotNone(lane_sim.report_time(header))  # the header is the fallback
        self.assertIsNone(lane_sim.report_time('not a report'))

    def test_the_watcher_marks_a_late_crash_report_from_the_boot_and_ignores_later_crashes(self):
        import datetime
        folder = Path(self.env['SM_LANE_CRASH_REPORTS'])
        start = time.time() - 100
        window = (start, start + 20)

        def report(name, crash_at):
            stamp = datetime.datetime.fromtimestamp(crash_at).astimezone().strftime('%Y-%m-%d %H:%M:%S.%f %z')
            (folder / name).write_text('{"app_name":"x","timestamp":"2000-01-01 00:00:00.00 +0000"}\n'
                                       f'{{"captureTime" : "{stamp}", "path": "com.apple.CoreSimulator.SimDevice.{UDID}"}}')

        report('SpokenMarginsApp-later.ips', start + 60)  # an app crash during a later test: not the boot
        self.assertIsNone(lane_sim.late_report(folder, UDID, window))
        report('SpringBoard-late.ips', start + 10)
        self.assertEqual(lane_sim.late_report(folder, UDID, window).name, 'SpringBoard-late.ips')
        monitor = lane_sim.SpringBoardMonitor(UDID, sequence((10, 20), (10, 20), (None, None)))
        self.assertEqual(lane_sim.watch(UDID, poll=0.01, monitor=monitor, crash_window=window), 'shut down')
        self.assertIn('late crash report for a crash during boot: SpringBoard-late.ips',
                      lane_sim.unsafe_devices()[UDID]['reason'])
        self.assertNotIn({'shutdown': UDID}, self.records())  # marked after the fact; the device wasn't stopped

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
            problem, _ = runner.boot_t3_device(UDID, self.quiet)
        self.assertIn('the lane stayed busy', problem)
        self.assertEqual(self.records(), [])


class BootRetryTests(unittest.TestCase):
    """A boot stall gets one fresh device; a second stall, or any other failure, stays a stop (#705)."""
    end_watchers, records, timed = LaneSimTests.end_watchers, LaneSimTests.records, LaneSimTests.timed

    def setUp(self):
        LaneSimTests.setUp(self)
        counter = Path(self.temporary.name) / 'created'
        for patch in (mock.patch.dict(os.environ, {'FAKE_CREATE_COUNTER': str(counter)}),
                      mock.patch.object(lane_sim, 'LATE_REPORT_WAIT', 0)):
            patch.start()
            self.addCleanup(patch.stop)
        self.logged = []
        self.replaced = []

    def replace(self, stalled):
        self.replaced.append(stalled)
        lane_sim.release(stalled, wait=0)
        return lane_sim.create_temporary('SM Lane retry')

    def boot(self, *stalls, replace=True, first_boot=True, **env):
        info = {}
        with mock.patch.dict(os.environ, {'FAKE_STALL': ','.join(stalls), **env}), \
                mock.patch.object(lane_sim, 'device_processes', stalling(*stalls)):
            try:
                result = lane_sim.boot_with_retry(UDID, 'test boot', self.replace if replace else None, out=self.quiet,
                                                  info=info, first_boot=first_boot,
                                                  log_stall=lambda *args: self.logged.append(args))
            except lane_sim.BootError as error:
                return error, info
        return result, info

    def booted(self):
        return [r['boot'] for r in self.records() if 'boot' in r]

    def test_a_healthy_boot_needs_no_retry_and_logs_nothing(self):
        (udid, _), info = self.boot()
        self.assertEqual((udid, info['udid'], info['boot_stalls']), (UDID, UDID, []))
        self.assertEqual((self.replaced, self.logged, self.booted()), ([], [], [UDID]))

    def test_a_stall_then_a_good_boot_on_a_fresh_device_recovers(self):
        (udid, seconds), info = self.boot(UDID)
        self.assertEqual(udid, 'FRESH-0001')
        self.assertEqual(info['udid'], 'FRESH-0001')
        self.assertEqual(self.booted(), [UDID, 'FRESH-0001'])  # the stalled device is never booted again
        self.assertIn({'delete': UDID}, self.records())
        self.assertIn('SpringBoard restarted', lane_sim.unsafe_devices()[UDID]['reason'])
        self.assertNotIn('FRESH-0001', lane_sim.unsafe_devices())
        self.assertEqual(info['boot_retry']['stalled'], UDID)
        (label, stalls, outcome), = self.logged
        self.assertEqual((label, [s['udid'] for s in stalls]), ('test boot', [UDID]))
        self.assertTrue(outcome.startswith('recovered on a fresh device'), outcome)

    def test_two_stalls_in_a_row_stop_and_name_the_device_to_release(self):
        error, info = self.boot(UDID, 'FRESH-0001')
        self.assertIsInstance(error, lane_sim.BootError)
        self.assertTrue(error.stall)
        self.assertIn('the one retry on a fresh device (FRESH-0001) failed too', str(error))
        self.assertEqual(info['udid'], 'FRESH-0001')  # the caller's to release
        self.assertEqual(self.booted(), [UDID, 'FRESH-0001'])  # no third boot
        self.assertEqual(set(lane_sim.unsafe_devices()), {UDID, 'FRESH-0001'})
        (_, stalls, outcome), = self.logged
        self.assertEqual(len(stalls), 2)
        self.assertIn('not recovered (two in a row)', outcome)

    def test_without_a_way_to_make_a_fresh_device_a_stall_stops_as_before(self):
        error, info = self.boot(UDID, replace=False)
        self.assertIsInstance(error, lane_sim.BootError)
        self.assertEqual((self.booted(), self.logged, info['udid']), ([UDID], [], UDID))

    def test_a_failed_simctl_boot_is_never_retried_on_any_device(self):
        error, _ = self.boot(FAKE_BOOT='invalid')
        self.assertFalse(error.stall)
        self.assertEqual((self.booted(), self.replaced, self.logged), ([UDID], [], []))

    def test_a_crash_report_during_boot_is_not_a_stall_and_gets_no_retry(self):
        error, _ = self.boot(FAKE_CRASH='1')
        self.assertIn('SpringBoard-2026-09-29-095801.ips', str(error))
        self.assertFalse(error.stall)
        self.assertEqual((self.booted(), self.replaced), ([UDID], []))

    def test_a_late_crash_report_for_the_stalled_device_means_no_retry(self):
        # A SpringBoard restart can start a crash flood, and its reports land about 80 s late (#184): the lane
        # waits LATE_REPORT_WAIT, and a report naming the stalled device stops it from switching devices.
        real_sleep = time.sleep

        def report_arrives(seconds):
            # Whole seconds: now minus half a second, cut down to the second, could fall over a second before a
            # boot that began a few milliseconds ago, and the report would miss the window (1 run in 5).
            stamp = time.strftime('%Y-%m-%d %H:%M:%S.00 +0000', time.gmtime(time.time()))
            (Path(self.env['SM_LANE_CRASH_REPORTS']) / 'SpringBoard-late.ips').write_text(
                '{"timestamp":"x"}\n{"captureTime" : "%s"} com.apple.CoreSimulator.SimDevice.%s' % (stamp, UDID))
            real_sleep(min(seconds, 0.01))

        # Only lane_sim's own sleeps may deliver the report. Patching the shared time module's sleep also caught
        # subprocess.run(timeout=...), which sleeps while it waits for a child that hasn't exited yet, so on a
        # loaded Mac the report landed during the boot and stopped it as a crash, not a stall (#2494).
        class SleepOnlyInLaneSim:
            sleep = staticmethod(report_arrives)

            def __getattr__(self, name):
                return getattr(time, name)

        with mock.patch.object(lane_sim, 'time', SleepOnlyInLaneSim()):
            error, info = self.boot(UDID)
        self.assertIsInstance(error, lane_sim.BootError)
        self.assertFalse(error.stall)
        self.assertIn('possible crash flood', str(error))
        self.assertEqual((self.booted(), self.replaced, info['udid']), ([UDID], [], UDID))
        self.assertIn('late crash report', lane_sim.unsafe_devices()[UDID]['reason'])
        (_, _, outcome), = self.logged
        self.assertIn('not retried: crash report SpringBoard-late.ips', outcome)

    def test_a_retry_waits_for_late_reports_first(self):
        real_sleep = time.sleep
        with mock.patch.object(lane_sim, 'LATE_REPORT_WAIT', 7), \
                mock.patch.object(lane_sim, 'late_report', return_value=None) as checked, \
                mock.patch.object(lane_sim.time, 'sleep', side_effect=lambda seconds: real_sleep(min(seconds, 0.01))) as slept:
            (udid, _), _ = self.boot(UDID)
        self.assertEqual(udid, 'FRESH-0001')
        self.assertIn(mock.call(7), slept.call_args_list)
        self.assertEqual(checked.call_args.args[1], UDID)

    def test_a_fresh_device_that_cannot_be_made_is_logged_and_stops(self):
        def broken(stalled):
            raise subprocess.CalledProcessError(1, ['simctl', 'create'])
        self.replace = broken
        error, info = self.boot(UDID)
        self.assertIn('could not be made', str(error))
        self.assertEqual(info['udid'], UDID)
        (_, _, outcome), = self.logged
        self.assertIn('not retried', outcome)

    def test_the_default_log_posts_each_stall_on_705(self):
        with mock.patch.dict(os.environ, {'FAKE_STALL': UDID}), \
                mock.patch.object(lane_sim, 'device_processes', stalling(UDID)):
            lane_sim.boot_with_retry(UDID, 'verify-tests --plan app boot at abc1234', self.replace, out=self.quiet,
                                     first_boot=True)
        posted = self.comments.read_text()
        self.assertIn('issue comment 1802', posted)
        self.assertIn('Boot stall recovered on a fresh device', posted)
        self.assertIn('verify-tests --plan app boot at abc1234', posted)
        self.assertIn(UDID, posted)


if __name__ == '__main__':
    unittest.main()
