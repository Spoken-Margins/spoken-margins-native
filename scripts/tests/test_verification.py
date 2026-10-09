import contextlib
import importlib.util
import inspect
import io
import json
import os
import shutil
import subprocess
from pathlib import Path
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
import test_inventory as inventory

spec = importlib.util.spec_from_file_location('verification', SCRIPTS / 'verify-tests.py')
verification = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verification)


class VerificationTests(unittest.TestCase):
    def crash_reports(self, *names):
        reports = iter([Path(name) for name in names])
        return lambda *args: next(reports, None)

    def test_single_simulator_crash_is_recorded_and_command_continues(self):
        with tempfile.TemporaryDirectory() as temporary:
            run = verification.Run(Path(temporary) / 'run', 'test')
            run.manifest['destination'] = {'udid': 'synthetic-device'}
            run.crash_baseline = {}
            crash = 'AppIntentsLiveEntityService-2026-09-24-223752.ips'
            with patch.object(verification, 'new_crash', side_effect=self.crash_reports(crash)), \
                    patch.object(verification.subprocess, 'run') as shutdown:
                run.command('crash-check', [sys.executable, '-c', 'import time; time.sleep(1)'])
                shutdown.assert_not_called()
            step = run.manifest['steps'][-1]
            self.assertEqual(step['simulator_crash_reports'], [crash])
            self.assertNotIn('simulator_crash_report', step)
            self.assertEqual(step['exit_code'], 0)

    def test_repeated_identical_simulator_crashes_stop_command_and_shut_down(self):
        with tempfile.TemporaryDirectory() as temporary:
            run = verification.Run(Path(temporary) / 'run', 'test')
            run.manifest['destination'] = {'udid': 'synthetic-device'}
            run.crash_baseline = {}
            crashes = [f'WidgetRenderer_Default-2026-09-24-10000{i}.ips' for i in range(3)]
            with patch.object(verification, 'new_crash', side_effect=self.crash_reports(*crashes)), \
                    patch.object(verification.subprocess, 'run') as shutdown:
                shutdown.return_value.returncode = 0
                with self.assertRaises(RuntimeError):
                    run.command('crash-check', [sys.executable, '-c', 'import time; time.sleep(60)'])
                self.assertEqual(shutdown.call_args.args[0],
                                 ['xcrun', 'simctl', 'shutdown', 'synthetic-device'])
            step = run.manifest['steps'][-1]
            self.assertEqual(step['simulator_crash_report'], crashes[-1])
            self.assertEqual(step['exit_code'], 124)

    def test_a_flood_on_a_desk_pool_device_marks_it_unsafe_before_the_shutdown(self):
        # #688: the pool erases and reuses its devices, so a device that flooded must be retired, not reused.
        import json
        import os
        from unittest import mock
        with tempfile.TemporaryDirectory() as temporary:
            state = Path(temporary) / 'state'
            state.mkdir()
            (state / 'desk-simulator-pool.json').write_text(json.dumps({'devices': {'pool-device': {'name': 'SM Lane Desk pool 1'}}}))
            seen = {}

            def shutdown(command, **kwargs):
                unsafe = state / 'unsafe-simulators.json'
                seen['unsafe_at_shutdown'] = json.loads(unsafe.read_text()) if unsafe.exists() else {}
                return mock.Mock(returncode=0)

            run = verification.Run(Path(temporary) / 'run', 'test')
            run.manifest['destination'] = {'udid': 'pool-device'}
            run.crash_baseline = {}
            crashes = [f'WidgetRenderer_Default-2026-09-24-10000{i}.ips' for i in range(3)]
            with mock.patch.dict(os.environ, {'SM_LANE_STATE_DIR': str(state)}), \
                    patch.object(verification, 'new_crash', side_effect=self.crash_reports(*crashes)), \
                    patch.object(verification.subprocess, 'run', side_effect=shutdown):
                with self.assertRaises(RuntimeError):
                    run.command('crash-check', [sys.executable, '-c', 'import time; time.sleep(60)'])
            self.assertIn('crash flood', seen['unsafe_at_shutdown']['pool-device']['reason'])

    def test_a_crash_report_renamed_while_it_is_read_is_skipped(self):
        # integration-4ca9d9c (#767): macOS wrote `.SpokenMarginsApp-….ips`, then renamed it between
        # the scan's glob and its stat, and the whole app run died with FileNotFoundError.
        device = 'synthetic-device'

        class RenamingFolder:
            """Lists the real folder, then renames every hidden report, as macOS does, before the caller reads it."""

            def __init__(self, folder):
                self.folder = folder

            def is_dir(self):  # the shared scans check the folder exists (lane_sim, #822)
                return self.folder.is_dir()

            def glob(self, pattern):
                found = list(self.folder.glob(pattern))
                for path in found:
                    if path.name.startswith('.'):
                        path.rename(path.with_name(path.name[1:]))
                return iter(found)

        with tempfile.TemporaryDirectory() as temporary:
            folder = Path(temporary)
            (folder / '.SpokenMarginsApp-2026-10-04-095145.ips').write_text(f'com.apple.CoreSimulator.SimDevice.{device}')
            self.assertEqual(verification.crash_snapshot(RenamingFolder(folder)), {})
            for report in folder.iterdir():
                report.unlink()
            (folder / '.SpokenMarginsApp-2026-10-04-095146.ips').write_text(f'com.apple.CoreSimulator.SimDevice.{device}')
            self.assertIsNone(verification.new_crash(RenamingFolder(folder), {}, device))

            # The renamed report is the real one, and the next scan finds it.
            self.assertEqual(verification.new_crash(folder, {}, device).name, 'SpokenMarginsApp-2026-10-04-095146.ips')

            # A report that vanishes outright (not hidden) is skipped too.
            class VanishingFolder(RenamingFolder):
                def glob(self, pattern):
                    found = list(self.folder.glob(pattern))
                    for path in found:
                        path.unlink()
                    return iter(found)

            self.assertEqual(verification.crash_snapshot(VanishingFolder(folder)), {})
            (folder / 'SpokenMarginsApp-later.ips').write_text(f'com.apple.CoreSimulator.SimDevice.{device}')
            self.assertIsNone(verification.new_crash(VanishingFolder(folder), {}, device))

    def test_a_hidden_report_still_being_written_is_not_a_crash_yet(self):
        with tempfile.TemporaryDirectory() as temporary:
            folder = Path(temporary)
            (folder / '.SpringBoard-2026-10-04-095145.ips').write_text('com.apple.CoreSimulator.SimDevice.synthetic-device')
            self.assertEqual(verification.crash_snapshot(folder), {})
            self.assertIsNone(verification.new_crash(folder, {}, 'synthetic-device'))

    def test_when_the_runner_itself_fails_it_still_stops_the_command(self):
        with tempfile.TemporaryDirectory() as temporary:
            run = verification.Run(Path(temporary) / 'run', 'test')
            run.manifest['destination'] = {'udid': 'synthetic-device'}
            run.crash_baseline = {}
            pid_file = Path(temporary) / 'child.pid'

            def scan(*args):
                if pid_file.exists() and pid_file.read_text():
                    raise FileNotFoundError('a crash report vanished')
                return None

            child = f'import os, time; open({str(pid_file)!r}, "w").write(str(os.getpid())); time.sleep(60)'
            with patch.object(verification, 'new_crash', side_effect=scan):
                with self.assertRaises(FileNotFoundError):
                    run.command('crash-check', [sys.executable, '-c', child])
            with self.assertRaises(ProcessLookupError):
                os.kill(int(pid_file.read_text()), 0)

    def test_stopping_kills_a_child_that_ignores_sigterm_after_its_leader_exits(self):
        # Codex audit P2 on dd3e0a4: the leader exits on SIGTERM at once, so waiting on it alone
        # never escalated, and a descendant that ignores SIGTERM was left running.
        with tempfile.TemporaryDirectory() as temporary:
            pid_file = Path(temporary) / 'child.pid'
            child = ('import os, signal, time; signal.signal(signal.SIGTERM, signal.SIG_IGN); '
                     f'open({str(pid_file)!r}, "w").write(str(os.getpid())); time.sleep(60)')
            leader = f'import subprocess, sys, time; subprocess.Popen([sys.executable, "-c", {child!r}]); time.sleep(60)'
            process = subprocess.Popen([sys.executable, '-c', leader], start_new_session=True)
            for _ in range(100):
                if pid_file.exists() and pid_file.read_text():
                    break
                time.sleep(0.05)
            child_pid = int(pid_file.read_text())
            verification.stop_process_group(process, grace=1)
            for _ in range(40):
                try:
                    os.kill(child_pid, 0)
                except ProcessLookupError:
                    break
                time.sleep(0.05)
            with self.assertRaises(ProcessLookupError):
                os.kill(child_pid, 0)

    def test_stopping_a_command_that_already_exited_does_not_raise(self):
        process = subprocess.Popen([sys.executable, '-c', 'pass'], start_new_session=True)
        process.wait()
        verification.stop_process_group(process)  # its group is gone; the runner's own error must survive

    def test_the_host_plan_runs_each_ops_folder_s_own_tests(self):
        # ops/dial and ops/codex carry their own Python tests, which no lane plan ran.
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / 'repo'
            for folder, body in (('dial', 'self.assertTrue(True)'), ('codex', 'self.assertEqual(1, 1)')):
                (root / 'ops' / folder).mkdir(parents=True)
                (root / 'ops' / folder / f'test_{folder}.py').write_text(
                    f'import unittest\nclass T(unittest.TestCase):\n    def test_it(self):\n        {body}\n')
            (root / 'ops' / 'notes').mkdir()
            (root / 'ops' / 'notes' / 'README.md').write_text('no tests here\n')
            self.assertEqual([p.relative_to(root).as_posix() for p in verification.ops_test_folders(root)],
                             ['ops/codex', 'ops/dial'])
            run = verification.Run(Path(temporary) / 'run', 'fast')
            run.ops_steps(root)
            steps = {step['name']: step for step in run.manifest['steps']}
            self.assertEqual(sorted(steps), ['ops-codex', 'ops-dial'])
            self.assertTrue(all(step['executed_count'] == 1 and not step['errors'] for step in steps.values()), steps)
            (root / 'ops' / 'dial' / 'test_dial.py').write_text('import unittest\n')  # a folder whose tests vanished
            run = verification.Run(Path(temporary) / 'run-2', 'fast')
            with self.assertRaises(RuntimeError) as raised:
                run.ops_steps(root)
            self.assertIn('executed zero tests', str(raised.exception))

    def host_step_calls(self, environment):
        """(commands run, manifest, final status) for the host steps under an environment."""
        calls = []
        audio = next(iter(verification.CODEX_SANDBOX_AUDIO_TESTS))
        with tempfile.TemporaryDirectory() as temporary, patch.dict(verification.os.environ, environment, clear=False):
            if not environment:
                verification.os.environ.pop('CODEX_SANDBOX', None)
            run = verification.Run(Path(temporary) / 'run', 'fast')
            with patch.object(run, 'command', side_effect=lambda name, args, **kw: calls.append((name, kw))), \
                    patch.object(run, 'ops_steps'), \
                    patch.object(verification, 'swift_tests',
                                 side_effect=lambda folder: {audio.split('/', 1)[1], 'OtherTests/testX'}
                                 if folder.name == 'SessionKitTests' else set()), \
                    patch.object(verification, 'input_identity', return_value=run.manifest['input_sha256']):
                run.host_steps()
            return calls, run.manifest, verification.passed_status(), audio

    def test_inside_codex_s_sandbox_the_fast_plan_skips_runner_tests_and_is_never_verified(self):
        # #64's Codex run (2026-10-01): its sandbox refuses `ps`, runner-tests failed (2 failures, 12 errors),
        # the plan stopped before the package step, and Codex gave up after 33 minutes.
        calls, manifest, status, audio = self.host_step_calls({'CODEX_SANDBOX': 'seatbelt'})
        names = [name for name, _ in calls]
        self.assertNotIn('runner-tests', names)
        self.assertIn('package', names)
        self.assertIn('runner-tests', [step['name'] for step in manifest['steps'] if step.get('skipped')])
        self.assertEqual(dict(calls)['package']['probation'], {audio})
        self.assertEqual(status, 'verified_in_codex_sandbox')

    def test_outside_a_sandbox_the_fast_plan_runs_everything_and_tolerates_no_audio_failure(self):
        calls, manifest, status, _ = self.host_step_calls({})
        self.assertEqual([name for name, _ in calls][0], 'runner-tests')
        self.assertIsNone(dict(calls)['package']['probation'])
        self.assertFalse([step for step in manifest['steps'] if step.get('skipped')])
        self.assertEqual(status, 'verified')

    def test_the_sessionkit_build_has_its_own_limit_so_the_tests_keep_theirs(self):
        # #844 (2026-10-05): one 300 s limit covered the SessionKit build and about 1,000 tests. Under a
        # load average of 40 to 180 the run stopped with hundreds of tests missing, at a different test
        # each time, and six PRs used their one re-run on it.
        calls = []
        with tempfile.TemporaryDirectory() as temporary, patch.dict(verification.os.environ, {}, clear=False):
            verification.os.environ.pop('CODEX_SANDBOX', None)
            run = verification.Run(Path(temporary) / 'run', 'fast')
            with patch.object(run, 'command', side_effect=lambda name, args, **kw: calls.append((name, args, kw))), \
                    patch.object(run, 'ops_steps'), \
                    patch.object(verification, 'swift_tests', return_value=set()), \
                    patch.object(verification, 'input_identity', return_value=run.manifest['input_sha256']):
                run.host_steps()
        names = [name for name, _, _ in calls]
        self.assertLess(names.index('package-build'), names.index('package'))
        steps = {name: (args, kw) for name, args, kw in calls}
        self.assertEqual(steps['package-build'][0][-1], '--build-only')
        self.assertEqual(steps['package'][0][-1], '--skip-build')
        self.assertGreaterEqual(steps['package'][1]['timeout'], 600)
        self.assertTrue(steps['package'][1]['tests'])  # the exact-test-ID check stays on the tests
        self.assertFalse(steps['package-build'][1].get('tests'))

    def test_runner_tests_have_their_own_limit_with_room_over_their_measured_time(self):
        # #1110: the runner's own suite takes 164.5 to 172.3 s on a quiet Mac, and the 180 s command default
        # killed it (exit 124, "executed zero tests") on PR #1103's head twice, beside a simulator job.
        measured = 172.3
        default = inspect.signature(verification.Run.command).parameters['timeout'].default
        calls = []
        with tempfile.TemporaryDirectory() as temporary, patch.dict(verification.os.environ, {}, clear=False):
            verification.os.environ.pop('CODEX_SANDBOX', None)
            run = verification.Run(Path(temporary) / 'run', 'fast')
            with patch.object(run, 'command', side_effect=lambda name, args, **kw: calls.append((name, kw))), \
                    patch.object(run, 'ops_steps'), \
                    patch.object(verification, 'swift_tests', return_value=set()), \
                    patch.object(verification, 'input_identity', return_value=run.manifest['input_sha256']):
                run.host_steps()
        timeout = dict(calls)['runner-tests'].get('timeout', default)
        self.assertGreaterEqual(timeout, 2 * measured)  # the suite grows and runs beside a simulator job
        self.assertGreater(timeout, default)

    def run_sessionkit_script(self, *args, exit_code=0, **env):
        """Run scripts/run-sessionkit-tests.sh from a copy in a temporary ROOT whose host-test-lane records what it
        was asked to run (and where), so the script's real argument handling executes. Returns (done, calls)."""
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / 'scripts').mkdir()
            (root / 'Packages/SessionKit').mkdir(parents=True)
            shutil.copy(SCRIPTS / 'run-sessionkit-tests.sh', root / 'scripts/run-sessionkit-tests.sh')
            lane = root / 'scripts/host-test-lane'
            lane.write_text(f'#!/bin/sh\nprintf "%s|" "$PWD" "$@" >> "{root}/calls"\necho >> "{root}/calls"\n'
                            f'exit {exit_code}\n')
            lane.chmod(0o755)
            environment = {key: value for key, value in os.environ.items() if key != 'CODEX_SANDBOX'}
            done = subprocess.run(['bash', str(root / 'scripts/run-sessionkit-tests.sh'), *args], env={**environment, **env},
                                  capture_output=True, text=True, timeout=30)
            calls = [line.split('|')[:-1] for line in (root / 'calls').read_text().splitlines()] \
                if (root / 'calls').exists() else []
            return done, [(Path(call[0]).resolve().relative_to(root.resolve()).as_posix(), call[1:]) for call in calls]

    def test_the_sessionkit_script_builds_and_tests_with_no_argument_and_splits_the_two_steps(self):
        package = 'Packages/SessionKit'
        for args, command in (((), ['swift', 'test']), (('--build-only',), ['swift', 'build', '--build-tests']),
                              (('--skip-build',), ['swift', 'test', '--skip-build'])):
            with self.subTest(args=args):
                done, calls = self.run_sessionkit_script(*args)
                self.assertEqual((done.returncode, calls), (0, [(package, command)]), done.stderr)  # run in the package

    def test_the_sessionkit_script_passes_on_the_exit_code_and_refuses_an_unknown_argument(self):
        done, calls = self.run_sessionkit_script('--skip-build', exit_code=3)
        self.assertEqual((done.returncode, len(calls)), (3, 1))  # a failing `swift test` fails the step
        done, calls = self.run_sessionkit_script('--everything')
        self.assertEqual((done.returncode, calls), (2, []))  # nothing ran
        self.assertIn('usage:', done.stderr)

    def test_inside_the_codex_sandbox_the_sessionkit_script_disables_swiftpm_s_own_sandbox(self):
        for args, command in (((), ['swift', 'test']), (('--build-only',), ['swift', 'build', '--build-tests']),
                              (('--skip-build',), ['swift', 'test', '--skip-build'])):
            with self.subTest(args=args):
                done, calls = self.run_sessionkit_script(*args, CODEX_SANDBOX='seatbelt')
                self.assertEqual(calls, [('Packages/SessionKit', command + ['--disable-sandbox'])], done.stderr)

    def test_ops_files_count_as_verification_inputs(self):
        with patch.object(verification, 'capture', return_value='ops/dial/dial_gate.py\n'), \
                tempfile.TemporaryDirectory() as temporary, patch.object(verification, 'ROOT', Path(temporary)):
            (Path(temporary) / 'ops/dial').mkdir(parents=True)
            (Path(temporary) / 'ops/dial/dial_gate.py').write_text('one\n')
            before = verification.input_identity()
            (Path(temporary) / 'ops/dial/dial_gate.py').write_text('two\n')
            self.assertNotEqual(before, verification.input_identity())

    def test_a_failed_step_names_its_first_errors_not_just_the_exit_code(self):
        # #411: T3 reports on #368 and #408 said only "Process exit 70"; the log that says why stayed on the Mac.
        script = ('import sys; print("Command line invocation: xcodebuild build-for-testing"); '
                  'print("2026-09-30 05:31:10.000 xcodebuild[1:2] Writing error result bundle"); '
                  'print("xcodebuild: error: Unable to find a destination matching the provided destination '
                  'specifier:"); print("xcodebuild: error: Unable to find a destination matching the provided '
                  'destination specifier:"); sys.exit(70)')
        with tempfile.TemporaryDirectory() as temporary:
            run = verification.Run(Path(temporary) / 'run', 'test')
            with self.assertRaises(RuntimeError) as raised:
                run.command('build-for-testing', [sys.executable, '-c', script])
        self.assertTrue(str(raised.exception).startswith(
            'Process exit 70; xcodebuild: error: Unable to find a destination matching the provided destination '
            'specifier: (see '), str(raised.exception))
        self.assertEqual(run.manifest['steps'][-1]['errors'], [
            'Process exit 70',
            'xcodebuild: error: Unable to find a destination matching the provided destination specifier:'])

    def test_build_errors_list_the_failed_commands(self):
        log = ('/src/A.swift:3:1: error: cannot find \'x\' in scope\n** TEST BUILD FAILED **\n\n'
               'The following build commands failed:\n\tSwiftCompile normal arm64 /src/A.swift\n(1 failure)\n\n')
        self.assertEqual(verification.log_errors(log), [
            "/src/A.swift:3:1: error: cannot find 'x' in scope", 'failed: SwiftCompile normal arm64 /src/A.swift',
            'failed: (1 failure)'])

    def simulator_inventory(self):
        return {
            f'com.apple.CoreSimulator.SimRuntime.iOS-{version}': [{
                'udid': str(version), 'name': 'Renamed verification device',
                'state': 'Booted' if version == 18 else 'Shutdown', 'isAvailable': True,
                'deviceTypeIdentifier': 'com.apple.CoreSimulator.SimDeviceType.iPhone-17',
            }] for version in (18, 26, 27)
        }

    def test_simulator_selection_excludes_old_os_and_recognizes_renamed_phones(self):
        devices = self.simulator_inventory()
        self.assertEqual(verification.select_simulator(devices)['udid'], '27')
        devices['com.apple.CoreSimulator.SimRuntime.iOS-26'][0]['state'] = 'Booted'
        self.assertEqual(verification.select_simulator(devices)['udid'], '26')
        self.assertEqual(verification.select_simulator(devices, ios=27)['udid'], '27')

    def test_requested_os_or_device_never_silently_falls_back(self):
        devices = self.simulator_inventory()
        for arguments in ({'device': '18'}, {'ios': 18}, {'ios': 28},
                          {'device': 'missing'}, {'device': '26', 'ios': 27}):
            with self.subTest(arguments=arguments), self.assertRaisesRegex(RuntimeError, 'supported simulator'):
                verification.select_simulator(devices, **arguments)
        devices['com.apple.CoreSimulator.SimRuntime.iOS-27'][0]['isAvailable'] = False
        with self.assertRaises(RuntimeError):
            verification.select_simulator(devices, ios=27)

    def test_explicit_ipad_is_supported_but_not_selected_as_default_phone(self):
        devices = self.simulator_inventory()
        tablet = devices['com.apple.CoreSimulator.SimRuntime.iOS-27'][0]
        tablet['deviceTypeIdentifier'] = 'com.apple.CoreSimulator.SimDeviceType.iPad-Pro'
        self.assertEqual(verification.select_simulator(devices)['udid'], '26')
        self.assertEqual(verification.select_simulator(devices, device='27')['udid'], '27')

    def test_non_ios_runtime_is_not_a_supported_destination(self):
        devices = self.simulator_inventory()
        devices['com.apple.CoreSimulator.SimRuntime.tvOS-27'] = devices.pop(
            'com.apple.CoreSimulator.SimRuntime.iOS-27')
        with self.assertRaises(RuntimeError):
            verification.select_simulator(devices, device='27')

    def test_app_tests_use_a_dedicated_runner_not_the_booted_journey_simulator(self):
        devices = self.simulator_inventory()
        devices['com.apple.CoreSimulator.SimRuntime.iOS-26'][0]['state'] = 'Booted'
        runner, template = verification.dedicated_simulator(devices)
        self.assertIsNone(runner)
        self.assertEqual((template['udid'], template['state']), ('26', 'Shutdown'))
        devices['com.apple.CoreSimulator.SimRuntime.iOS-26'].append({
            'udid': 'runner', 'name': verification.TEST_RUNNER_NAME, 'state': 'Shutdown', 'isAvailable': True,
            'deviceTypeIdentifier': 'com.apple.CoreSimulator.SimDeviceType.iPhone-17',
        })
        runner, template = verification.dedicated_simulator(devices)
        self.assertEqual(runner['udid'], 'runner')
        self.assertIsNone(template)
        runner, template = verification.dedicated_simulator(devices, ios=27)
        self.assertIsNone(runner, 'a runner on another OS is not reused when an OS is required')
        self.assertEqual(template['udid'], '27')

    def test_the_default_runner_stays_on_the_lane_ios_even_when_a_newer_one_exists(self):
        # 31A5C797, an iOS 27 "SpokenMargins Test Runner", was the default and crash-flooded (#184).
        devices = self.simulator_inventory()
        devices['com.apple.CoreSimulator.SimRuntime.iOS-27'].append({
            'udid': '31A5C797', 'name': verification.TEST_RUNNER_NAME, 'state': 'Shutdown', 'isAvailable': True,
            'deviceTypeIdentifier': 'com.apple.CoreSimulator.SimDeviceType.iPhone-17',
        })
        runner, template = verification.dedicated_simulator(devices)
        self.assertIsNone(runner)
        self.assertEqual(template['runtime'], 'com.apple.CoreSimulator.SimRuntime.iOS-26')
        self.assertEqual(verification.dedicated_simulator(devices, ios=27)[0]['udid'], '31A5C797')  # only if asked

    def test_a_device_on_the_unsafe_list_is_refused_however_it_was_chosen(self):
        chosen = {'udid': '31A5C797', 'name': verification.TEST_RUNNER_NAME}
        with self.assertRaisesRegex(RuntimeError, "unsafe list: iOS 27 flood.*lane-sim-boot --fresh"):
            verification.refuse_unsafe(chosen, {'31A5C797': {'reason': 'iOS 27 flood'}})
        verification.refuse_unsafe(chosen, {'OTHER': {'reason': 'x'}})  # not listed: fine

    def test_simulator_minimum_matches_shipping_targets(self):
        import re
        project = (inventory.ROOT / 'project.yml').read_text()
        package = (inventory.ROOT / 'Packages/SessionKit/Package.swift').read_text()
        self.assertEqual(int(re.search(r'iOS: "(\d+)\.0"', project)[1]), verification.MINIMUM_IOS_MAJOR)
        self.assertEqual(int(re.search(r'\.iOS\("(\d+)\.0"\)', package)[1]), verification.MINIMUM_IOS_MAJOR)

    def test_browser_and_surface_inputs_invalidate_build_identity(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            paths = ['Tools/BrowserExtraction/core.mjs', 'schemas/surface-contract.schema.json']
            for relative in paths:
                path = root / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text('original')
            with patch.object(verification, 'ROOT', root), patch.object(
                    verification, 'capture', return_value='\n'.join(paths)):
                previous = verification.input_identity()
                for relative in paths:
                    (root / relative).write_text('changed')
                    current = verification.input_identity()
                    self.assertNotEqual(previous, current, relative)
                    previous = current

    def test_repository_inventory_is_complete(self):
        self.assertEqual(inventory.validate(), [])

    def test_j1_is_registered_as_an_executable_scripted_journey(self):
        listing = json.loads((inventory.ROOT / 'TestPlans/scripted-journeys.json').read_text())
        entries = [entry for status in ('gating', 'probation') for entry in listing[status]
                   if entry['journey'] == 'J1']
        self.assertEqual(len(entries), 1, 'The integration run has no J1 script to execute')
        self.assertEqual(inventory.scripted_journey_errors(inventory.ROOT), [])
        selector = entries[0]['test'].removeprefix('SpokenMarginsAppUITests/')
        available = inventory.target_tests(inventory.ROOT, 'SpokenMarginsAppUITests')
        selected = {test for test in available if inventory.matches(test, selector)}
        self.assertEqual(len(selected), 1, 'J1 must select one short journey test')

    def test_zero_missing_extra_and_unexpected_skips_fail_closed(self):
        name = 'App/ExportTests/testIsolation'
        good = {name: {'status': 'passed', 'seconds': 0.01}}
        self.assertEqual(verification.reconcile({name}, good), [])
        self.assertTrue(verification.reconcile({name}, {}))
        self.assertTrue(verification.reconcile({name, 'missing'}, good))
        self.assertTrue(verification.reconcile(set(), good))
        skipped = {name: {'status': 'skipped', 'seconds': 0}}
        self.assertTrue(verification.reconcile({name}, skipped))
        self.assertEqual(verification.reconcile({name}, skipped, {name}), [])

    def xctest_log(self, *results):
        return '; '.join(f"print(\"Test Case '-[SpokenMarginsAppUITests.{c} {m}]' {status} (1.0 seconds)\")"
                         for c, m, status in results)

    def test_a_failing_probation_script_is_reported_but_does_not_fail_the_run(self):
        # #522: scripts on probation run in the integration run but can't turn it red; gating ones can.
        tour, share = 'SpokenMarginsAppUITests/TourUITests/testTour', 'SpokenMarginsAppUITests/ShareUITests/testShare'
        with tempfile.TemporaryDirectory() as temporary:
            run = verification.Run(Path(temporary) / 'run', 'journeys')
            script = self.xctest_log(('TourUITests', 'testTour', 'passed'), ('ShareUITests', 'testShare', 'failed'))
            run.command('xcode-tests', [sys.executable, '-c', script + '; raise SystemExit(65)'],
                        expected={tour, share}, tests=True, probation={share})
            step = run.manifest['steps'][-1]
            self.assertEqual((step['errors'], step['gating'], step['probation']), ([], {tour: 'passed'}, {share: 'failed'}))
            run.command('xcode-tests-missing', [sys.executable, '-c', self.xctest_log(('TourUITests', 'testTour', 'passed'))],
                        expected={tour, share}, tests=True, probation={share})
            self.assertEqual(run.manifest['steps'][-1]['probation'], {share: 'missing'})
            run.command('xcode-tests-skip', [sys.executable, '-c', self.xctest_log(
                ('TourUITests', 'testTour', 'passed'), ('ShareUITests', 'testShare', 'skipped'))],
                expected={tour, share}, tests=True, probation={share})
            self.assertEqual(run.manifest['steps'][-1]['probation'], {share: 'skipped'})
            # With only probation scripts listed, a run where nothing ran is still a failure, not a pass.
            with self.assertRaisesRegex(RuntimeError, 'Process exit 65; No completed tests recorded'):
                run.command('xcode-tests-nothing', [sys.executable, '-c', 'raise SystemExit(65)'],
                            expected={share}, tests=True, probation={share})
            with self.assertRaisesRegex(RuntimeError, f'Process exit 65; Failed: {tour}'):
                run.command('xcode-tests-gating', [sys.executable, '-c', self.xctest_log(
                    ('TourUITests', 'testTour', 'failed'), ('ShareUITests', 'testShare', 'passed')) + '; raise SystemExit(65)'],
                    expected={tour, share}, tests=True, probation={share})

    def test_a_test_step_that_exits_non_zero_fails_even_when_every_recorded_test_passed(self):
        # The shape of a real xcodebuild failure after the tests: the host crashes on teardown, the simulator
        # dies after the last test, `swift test` exits 1. Only a failing *probation* test excuses the exit code.
        tour, share = 'SpokenMarginsAppUITests/TourUITests/testTour', 'SpokenMarginsAppUITests/ShareUITests/testShare'
        passed = self.xctest_log(('TourUITests', 'testTour', 'passed'), ('ShareUITests', 'testShare', 'passed'))
        with tempfile.TemporaryDirectory() as temporary:
            run = verification.Run(Path(temporary) / 'run', 'journeys')
            for label, probation in (('no probation', None), ('probation that passed', {share})):
                with self.subTest(label):
                    with self.assertRaisesRegex(RuntimeError, 'Process exit 65'):
                        run.command(f'xcode-tests-{len(run.manifest["steps"])}',
                                    [sys.executable, '-c', passed + '; raise SystemExit(65)'],
                                    expected={tour, share}, tests=True, probation=probation)
                    step = run.manifest['steps'][-1]
                    self.assertEqual((step['exit_code'], step['errors'][0]), (65, 'Process exit 65'))
                    self.assertEqual(step['counts']['passed'], 2)  # the tests did pass: the exit code is the failure
            # and the same step with a zero exit is clean, so the above is the exit code and nothing else
            run.command('xcode-tests-clean', [sys.executable, '-c', passed], expected={tour, share}, tests=True)
            self.assertEqual(run.manifest['steps'][-1]['errors'], [])

    def test_journeys_plan_passes_ui_test_selectors_and_names_the_probation_ones(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / 'repo'
            for target, source in (('SpokenMarginsAppTests', 'final class SpeechTests: XCTestCase { func testSpeak() {} }'),
                                   ('SpokenMarginsAppUITests', 'final class TourUITests: XCTestCase { func testTour() {} }\n'
                                    'final class ShareUITests: XCTestCase { func testShare() {} func testOpen() {} }')):
                (root / 'App' / target).mkdir(parents=True)
                (root / 'App' / target / 'Tests.swift').write_text(source)
            (root / 'App/SpokenMarginsAppTests/Gate4WatchPackageRenderTests.swift').write_text(
                'final class Gate4WatchPackageRenderTests: XCTestCase { func testRender() {} }')
            (root / 'TestPlans').mkdir()
            (root / 'TestPlans/Release.xctestplan').write_text(json.dumps({'testTargets': [
                {'target': {'name': 'SpokenMarginsAppTests'}}, {'target': {'name': 'SpokenMarginsAppUITests'}}]}))
            (root / '.build/verification/SpokenMarginsReleaseTests').mkdir(parents=True)
            run = verification.Run(Path(temporary) / 'run', 'journeys')
            run.manifest['input_sha256'] = 'inputs'
            commands = {}

            def command(name, args, timeout=180, expected=None, allowed_skips=(), tests=False, probation=(),
                        startup=None):
                commands[name] = (args, expected, probation)
                return ''

            capture = lambda args: '{"devices": {}}' if args[:3] == ['xcrun', 'simctl', 'list'] else 'stub'
            device = {'udid': 'synthetic-device', 'state': 'Booted', 'runtime': 'iOS-26', 'name': 'Other'}
            with patch.object(verification, 'ROOT', root), \
                    patch.object(verification, 'input_identity', return_value='inputs'), \
                    patch.object(verification, 'capture', side_effect=capture), \
                    patch.object(verification, 'dedicated_simulator', return_value=(device, None)), \
                    patch.object(verification, 'refuse_unsafe'), \
                    patch.object(verification.lane_sim, 'unsafe_devices', return_value={}), \
                    patch.object(verification.subprocess, 'run'), \
                    patch.object(run, 'command', side_effect=command):
                run.xcode('journeys', None, rebuild=True, only=['SpokenMarginsAppUITests/TourUITests/testTour',
                                                                'SpokenMarginsAppUITests/ShareUITests'],
                          probation=['SpokenMarginsAppUITests/ShareUITests'])
            args, expected, probation = commands['xcode-tests']
            self.assertIn('SpokenMarginsReleaseTests', args)
            self.assertEqual([a for a in args if a.startswith('-only-testing:')],
                             ['-only-testing:SpokenMarginsAppUITests/TourUITests/testTour',
                              '-only-testing:SpokenMarginsAppUITests/ShareUITests'])
            share = {'SpokenMarginsAppUITests/ShareUITests/testShare', 'SpokenMarginsAppUITests/ShareUITests/testOpen'}
            self.assertEqual(expected, share | {'SpokenMarginsAppUITests/TourUITests/testTour'})
            self.assertEqual(probation, share)

    def test_journeys_plan_with_nothing_listed_boots_nothing(self):
        out = io.StringIO()
        with patch.object(sys, 'argv', ['verify-tests.py', '--plan', 'journeys']), \
                patch.object(verification, 'validate', return_value=[]), \
                patch.object(inventory, 'scripted_journeys', return_value={'gating': [], 'probation': []}), \
                patch.object(verification, 'Run') as run, contextlib.redirect_stdout(out):
            self.assertEqual(verification.main(), 0)
        run.assert_not_called()
        self.assertIn('nothing to run', out.getvalue())

    def test_log_parser_preserves_failure_and_duration(self):
        log = "Test Case '-[App.ExportTests testIsolation]' failed (0.125 seconds)."
        self.assertEqual(verification.test_records(log), {
            'App/ExportTests/testIsolation': {'status': 'failed', 'seconds': 0.125}})

    def test_interleaved_completion_is_recovered_from_result_bundle(self):
        method = 'testExplicitPodcastRedownloadCanReplacePausedTransportWhileAutomaticCompletionCannot'
        identifier = f'SpokenMarginsAppTests/SourceLinkImportTests/{method}'
        # Real failure shape from ce29f0c: a network log splits the completion inside the name.
        log = ("Test Case '-[SpokenMarginsAppTests.SourceLinkImportTests " + method[:-7]
               + '2026-10-02 07:55:20.045198-0400 SpokenMarginsApp[342:22743267] '
                 '[Default] Connection 32: received failure notification\n'
               + method[-7:] + "]' passed (0.094 seconds).")
        evidence = {'testNodes': [{'nodeType': 'Unit test bundle', 'name': 'SpokenMarginsAppTests',
                    'children': [{'nodeType': 'Test Case', 'nodeIdentifier': f'SourceLinkImportTests/{method}()',
                                  'result': 'Passed', 'durationInSeconds': 0.094}]}]}
        self.assertEqual(verification.test_records(log), {})
        with tempfile.TemporaryDirectory() as temporary:
            run = verification.Run(Path(temporary) / 'run', 'app')
            bundle = run.output / 'tests.xcresult'
            bundle.mkdir()
            with patch.object(verification.subprocess, 'check_output', return_value=json.dumps(evidence)):
                run.command('xcode-tests', [sys.executable, '-c', f'print({log!r})',
                            '-resultBundlePath', str(bundle)], tests=True, expected={identifier})
            step = run.manifest['steps'][-1]
            self.assertEqual(step['tests'][identifier], {'status': 'passed', 'seconds': 0.094})
            self.assertEqual(step['errors'], [])
            self.assertEqual(step['test_evidence'], 'log+xcresult')

    def test_failed_probation_exports_media_even_with_false_failure_flags(self):
        # #706: J1 failed but all nine attachments had isAssociatedWithFailure=false.
        identifier = 'App/ExportTests/testIsolation'
        url = 'test://com.apple.xcode/Project/App/ExportTests/testIsolation'
        evidence = self.xcresult_payload('Failed', nodeIdentifierURL=url,
                                         hasMediaAttachments=False)
        with tempfile.TemporaryDirectory() as temporary:
            run = verification.Run(Path(temporary) / 'run', 'journeys')
            bundle = run.output / 'tests.xcresult'
            bundle.mkdir()
            exports = []

            def export(args, **kwargs):
                exports.append(args)
                output = Path(args[args.index('--output-path') + 1])
                attachments = []
                for n in range(9):
                    name = f'{n}.mp4' if n == 8 else f'{n}.txt'
                    (output / name).write_bytes(b'retained evidence')
                    attachments.append({'exportedFileName': name, 'isAssociatedWithFailure': False})
                (output / 'manifest.json').write_text(json.dumps([
                    {'testIdentifierURL': url, 'attachments': attachments}]))
                return subprocess.CompletedProcess(args, 0)

            with patch.object(verification.subprocess, 'check_output', return_value=json.dumps(evidence)), \
                    patch.object(verification.subprocess, 'run', side_effect=export):
                run.command('xcode-tests', [sys.executable, '-c', 'raise SystemExit(65)',
                            '-resultBundlePath', str(bundle)], tests=True,
                            expected={identifier}, probation={identifier})
            step = run.manifest['steps'][-1]
            self.assertEqual(len(exports), 1)
            self.assertNotIn('--only-failures', exports[0])
            self.assertEqual(exports[0][exports[0].index('--test-id') + 1], url)
            recovered = step['attachments'][0]
            self.assertEqual(recovered['test'], identifier)
            self.assertEqual(len(recovered['files']), 9)
            self.assertTrue(all(Path(p).is_file() for p in recovered['files']))
            self.assertTrue(Path(recovered['manifest']).is_file())
            self.assertEqual(step['tests'][identifier]['status'], 'failed')
            self.assertEqual(step['probation'], {identifier: 'failed'})
            self.assertEqual(step['counts'], {'passed': 0, 'failed': 1, 'skipped': 0})
            self.assertEqual(step['errors'], [])

    def xcresult_payload(self, result='Passed', **fields):
        case = {'nodeType': 'Test Case', 'nodeIdentifier': 'ExportTests/testIsolation()',
                'result': result, 'durationInSeconds': 0.125, **fields}
        return {'testNodes': [{'nodeType': 'UI test bundle', 'name': 'App', 'children': [case]}]}

    def test_result_bundle_cannot_erase_log_failure_or_skip(self):
        for status in ('failed', 'skipped'):
            with self.subTest(status=status):
                log = f"Test Case '-[App.ExportTests testIsolation]' {status} (0.125 seconds)."
                with patch.object(verification.subprocess, 'check_output',
                                  return_value=json.dumps(self.xcresult_payload())):
                    records, _ = verification.completed_test_records(log, 'tests.xcresult')
                self.assertEqual(records['App/ExportTests/testIsolation']['status'], status)
                self.assertTrue(verification.reconcile(set(records), records))

    def test_result_bundle_failed_retry_and_skips_fail_closed(self):
        retry = self.xcresult_payload(children=[{'nodeType': 'Test Case Run', 'result': 'Failed'},
                                               {'nodeType': 'Test Case Run', 'result': 'Passed'}])
        records = verification.xcresult_test_records(retry)
        self.assertEqual(records['App/ExportTests/testIsolation']['status'], 'failed')
        self.assertTrue(verification.reconcile(set(records), records))
        skipped = verification.xcresult_test_records(self.xcresult_payload('Skipped'))
        self.assertEqual(skipped['App/ExportTests/testIsolation']['status'], 'skipped')
        self.assertTrue(verification.reconcile(set(skipped), skipped))
        with patch.object(verification.subprocess, 'check_output',
                          return_value=json.dumps(self.xcresult_payload('Failed'))):
            log = "Test Case '-[App.ExportTests testIsolation]' passed (0.125 seconds)."
            failed, _ = verification.completed_test_records(log, 'tests.xcresult')
        self.assertEqual(failed['App/ExportTests/testIsolation']['status'], 'failed')

    def test_result_bundle_counts_cannot_replace_individual_records(self):
        payload = {'testNodes': [{'nodeType': 'Test Plan', 'name': 'App', 'result': 'Passed'}],
                   'passedTests': 591}
        with patch.object(verification.subprocess, 'check_output', return_value=json.dumps(payload)):
            with self.assertRaisesRegex(ValueError, 'No completed individual tests'):
                verification.completed_test_records('', 'tests.xcresult')
        records = verification.xcresult_test_records(self.xcresult_payload())
        self.assertTrue(verification.reconcile(set(records) | {'App/ExportTests/testMissing'}, records))

    def test_unreadable_or_unknown_result_bundle_does_not_fall_back_to_pass(self):
        identifier = 'App/ExportTests/testIsolation'
        log = "Test Case '-[App.ExportTests testIsolation]' passed (0.125 seconds)."
        for output in ('not JSON', json.dumps(self.xcresult_payload('unknown'))):
            with self.subTest(output=output), tempfile.TemporaryDirectory() as temporary:
                run = verification.Run(Path(temporary) / 'run', 'app')
                with patch.object(verification.subprocess, 'check_output', return_value=output):
                    with self.assertRaisesRegex(RuntimeError, 'Could not reconcile xcresult'):
                        run.command('xcode-tests', [sys.executable, '-c', f'print({log!r})',
                                    '-resultBundlePath', 'tests.xcresult'], tests=True, expected={identifier})
                self.assertEqual(run.manifest['steps'][-1]['counts']['passed'], 1)

    def test_passing_retry_cannot_erase_failure(self):
        log = "\n".join(f"Test Case '-[App.ExportTests testIsolation]' {status} (0.125 seconds)."
                        for status in ('failed', 'passed', 'passed'))
        records = verification.test_records(log)
        result = records['App/ExportTests/testIsolation']
        self.assertEqual(result['status'], 'failed')
        self.assertEqual(len(result['attempts']), 3)
        self.assertTrue(verification.reconcile(set(records), records))

    def test_unknown_selector_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / 'TestPlans').mkdir()
            (root / 'App/SpokenMarginsAppUITests').mkdir(parents=True)
            (root / 'App/SpokenMarginsAppUITests/Test.swift').write_text(
                'final class RouteTests: XCTestCase { func testRoute() {} }')
            (root / 'TestPlans/Broken.xctestplan').write_text(json.dumps({'testTargets': [{
                'target': {'name': 'SpokenMarginsAppUITests'}, 'selectedTests': ['RouteTests/testRenamed()']}]}))
            with self.assertRaisesRegex(ValueError, 'stale'):
                inventory.plan_tests(root, 'Broken')

    def app_test_root(self, root):
        """A repo with one app test class of three methods and plans that select all, some, or none of it."""
        tests = root / 'App/SpokenMarginsAppTests'
        tests.mkdir(parents=True)
        (tests / 'Gate4WatchPackageRenderTests.swift').write_text(
            'final class Gate4WatchPackageRenderTests: XCTestCase { func testRender() {} }')
        (tests / 'SpeechTests.swift').write_text(
            'final class SpeechTests: XCTestCase { func testBundled() {} func testSwitch() {} func testSilence() {} }')
        (root / 'TestPlans').mkdir()
        target = {'name': 'SpokenMarginsAppTests'}
        for name, selection in (('AudioAdapters', {'selectedTests': ['SpeechTests/testBundled()']}),
                                ('AppBehavior', {'skippedTests': ['SpeechTests/testBundled()']}),
                                ('Whole', {})):
            (root / f'TestPlans/{name}.xctestplan').write_text(
                json.dumps({'testTargets': [dict(target=target, **selection)]}))

    def test_class_selector_is_narrowed_to_the_methods_a_plan_selects(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.app_test_root(root)
            available = {f'SpokenMarginsAppTests/{t}' for t in inventory.target_tests(root, 'SpokenMarginsAppTests')}
            speech = 'SpokenMarginsAppTests/SpeechTests'
            narrow = lambda plan, selectors: verification.narrow_selectors(
                selectors, inventory.plan_tests(root, plan), available)
            self.assertEqual(narrow('AudioAdapters', [speech]), [f'{speech}/testBundled'])
            self.assertEqual(narrow('AppBehavior', [speech]), [f'{speech}/testSilence', f'{speech}/testSwitch'])
            self.assertEqual(narrow('Whole', [speech]), [speech])
            self.assertEqual(narrow('AppBehavior', [f'{speech}/testSwitch']), [f'{speech}/testSwitch'])

    def test_t3_class_request_runs_only_the_planned_methods_in_the_adapters_plan(self):
        # #518: `tests: SpokenMarginsAppTests/SupertonicSpeechTests` passed -only-testing the class, which
        # overrides AudioAdapters' one selected method; all 74 ran and 73 were reported as unexpected.
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / 'repo'
            self.app_test_root(root)
            (root / '.build/verification/SpokenMarginsAppBehavior').mkdir(parents=True)
            run = verification.Run(Path(temporary) / 'run', 'adapters')
            run.manifest['input_sha256'] = 'inputs'
            commands = {}

            def command(name, args, timeout=180, expected=None, allowed_skips=(), tests=False, probation=None,
                        startup=None):
                commands[name] = (args, expected, startup)
                return ''

            capture = lambda args: '{"devices": {}}' if args[:3] == ['xcrun', 'simctl', 'list'] else 'stub'
            device = {'udid': 'synthetic-device', 'state': 'Booted', 'runtime': 'iOS-26', 'name': 'Other'}
            with patch.object(verification, 'ROOT', root), \
                    patch.object(verification, 'input_identity', return_value='inputs'), \
                    patch.object(verification, 'capture', side_effect=capture), \
                    patch.object(verification, 'dedicated_simulator', return_value=(device, None)), \
                    patch.object(verification, 'refuse_unsafe'), \
                    patch.object(verification.lane_sim, 'unsafe_devices', return_value={}), \
                    patch.object(verification.subprocess, 'run'), \
                    patch.object(run, 'command', side_effect=command):
                run.xcode('adapters', None, rebuild=True, only=['SpeechTests'])
            args, expected, startup = commands['xcode-tests']
            method = 'SpokenMarginsAppTests/SpeechTests/testBundled'
            self.assertEqual([a for a in args if a.startswith('-only-testing:')], [f'-only-testing:{method}'])
            self.assertEqual(expected, {method})
            # #705: the app-hosted plans watch for a run that never starts its tests.
            self.assertEqual((startup['seconds'], startup['retries']),
                             (verification.STARTUP_STALL_SECONDS, verification.STARTUP_RETRIES))
            # The relaunch hook ends the stalled app and frees the result-bundle path for the second launch.
            app = root / '.build/verification/SpokenMarginsAppBehavior/Build/Products/Debug-iphonesimulator/SpokenMarginsApp.app'
            app.mkdir(parents=True)
            (app / 'Info.plist').write_bytes(verification.plistlib.dumps({'CFBundleIdentifier': 'com.example.app'}))
            (run.output / 'tests.xcresult').mkdir()
            with patch.object(verification, 'ROOT', root), patch.object(verification.subprocess, 'run') as terminate:
                startup['reset'](1)
            self.assertEqual(terminate.call_args.args[0],
                             ['xcrun', 'simctl', 'terminate', 'synthetic-device', 'com.example.app'])
            self.assertFalse((run.output / 'tests.xcresult').exists())
            self.assertTrue((run.output / 'tests-stalled-1.xcresult').exists())

    def test_ui_plans_have_no_startup_watch(self):
        # Their runner is a separate app and starts on its own schedule; they keep their single launch.
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / 'repo'
            self.app_test_root(root)
            (root / '.build/verification/SpokenMarginsUISeams').mkdir(parents=True)
            (root / 'TestPlans/Smoke.xctestplan').write_text(json.dumps({'testTargets': [dict(
                target={'name': 'SpokenMarginsAppTests'}, selectedTests=['SpeechTests/testBundled()'])]}))
            run = verification.Run(Path(temporary) / 'run', 'smoke')
            run.manifest['input_sha256'] = 'inputs'
            commands = {}

            def command(name, args, timeout=180, expected=None, allowed_skips=(), tests=False, probation=None,
                        startup=None):
                commands[name] = startup
                return ''

            capture = lambda args: '{"devices": {}}' if args[:3] == ['xcrun', 'simctl', 'list'] else 'stub'
            device = {'udid': 'synthetic-device', 'state': 'Booted', 'runtime': 'iOS-26', 'name': 'Other'}
            with patch.object(verification, 'ROOT', root), \
                    patch.object(verification, 'input_identity', return_value='inputs'), \
                    patch.object(verification, 'capture', side_effect=capture), \
                    patch.object(verification, 'dedicated_simulator', return_value=(device, None)), \
                    patch.object(verification, 'refuse_unsafe'), \
                    patch.object(verification.lane_sim, 'unsafe_devices', return_value={}), \
                    patch.object(verification.subprocess, 'run'), \
                    patch.object(run, 'command', side_effect=command):
                run.xcode('smoke', None, rebuild=True)
            self.assertIsNone(commands['xcode-tests'])

    STALLS_THEN_RUNS = (
        'import os, sys, time\n'
        'marker = sys.argv[1]\n'
        'if not os.path.exists(marker):\n'
        '    open(marker, "w").close()\n'
        '    print("Writing result bundle at path:", flush=True)\n'
        '    time.sleep(60)\n'
        'print("Test Suite \'Selected tests\' started at now.", flush=True)\n'
        'print("Test Case \'-[SpokenMarginsAppTests.SpeechTests testBundled]\' started.", flush=True)\n'
        'print("Test Case \'-[SpokenMarginsAppTests.SpeechTests testBundled]\' passed (0.1 seconds).", flush=True)\n')

    def watch(self, seconds=1, retries=1):
        calls = {'diagnose': [], 'reset': []}
        return calls, {'seconds': seconds, 'retries': retries,
                       'diagnose': lambda folder: calls['diagnose'].append(folder.name) or {'processes': 2},
                       'reset': lambda attempt: calls['reset'].append(attempt)}

    def test_run_that_never_starts_its_tests_is_diagnosed_and_launched_again(self):
        # #705: the adapters step sat 300 s with no Test Suite line, 0 tests, exit 124. One stalled launch is
        # recorded and the same command runs again; the second launch's real test result is kept as evidence.
        # The stall's cause is unknown, so the step stays INCONCLUSIVE rather than turning into a PASS
        # (Codex audit of debe880, P1).
        with tempfile.TemporaryDirectory() as temporary:
            run = verification.Run(Path(temporary) / 'run', 'adapters')
            calls, startup = self.watch()
            with self.assertRaisesRegex(RuntimeError, r'Recovered after 1 startup stall\(s\) of 1s.*not a PASS'):
                run.command('xcode-tests', [sys.executable, '-c', self.STALLS_THEN_RUNS, str(Path(temporary) / 'seen')],
                            timeout=60, expected={'SpokenMarginsAppTests/SpeechTests/testBundled'}, tests=True,
                            startup=startup)
            step = run.manifest['steps'][-1]
            self.assertEqual(step['exit_code'], 0)
            self.assertEqual(step['counts']['passed'], 1)  # the retry's real result is evidence
            self.assertEqual(step['startup_attempts'], 2)
            self.assertEqual([(s['attempt'], s['last_log_line'], s['processes']) for s in step['startup_stalls']],
                             [(1, 'Writing result bundle at path:', 2)])
            self.assertEqual((calls['diagnose'], calls['reset']), (['xcode-tests-stall-1'], [1]))
            self.assertLess(step['seconds'], 30)  # not the 60 s the stalled launch would have slept
            self.assertEqual(len(step['errors']), 1)

    def test_run_that_stalls_on_every_launch_reports_why_within_its_budget(self):
        with tempfile.TemporaryDirectory() as temporary:
            run = verification.Run(Path(temporary) / 'run', 'adapters')
            calls, startup = self.watch()
            script = 'import time; print("Writing result bundle at path:", flush=True); time.sleep(60)'
            with self.assertRaisesRegex(RuntimeError, r'printed no test output in 2 launch\(es\) of 1s'):
                run.command('xcode-tests', [sys.executable, '-c', script], timeout=60, tests=True, startup=startup)
            step = run.manifest['steps'][-1]
            self.assertEqual(step['exit_code'], 124)
            self.assertFalse(step['interrupted'])  # the lane's report says "ran out of budget" for interrupted steps
            self.assertEqual([s['attempt'] for s in step['startup_stalls']], [1, 2])
            self.assertEqual(calls['reset'], [1])  # no third launch
            self.assertLess(step['seconds'], 30)

    def test_launch_that_starts_its_tests_while_the_stall_is_being_diagnosed_is_left_running(self):
        # Codex audit of debe880, P2: the diagnosis takes seconds; killing a launch that began meanwhile
        # throws away a working run.
        with tempfile.TemporaryDirectory() as temporary:
            run = verification.Run(Path(temporary) / 'run', 'adapters')
            calls, startup = self.watch()
            slow_diagnosis = startup['diagnose']
            startup['diagnose'] = lambda folder: (time.sleep(1.5), slow_diagnosis(folder))[1]
            script = ('import time; time.sleep(1.4); print("Test Suite \'Selected tests\' started at now.", flush=True); '
                      'time.sleep(1)')
            run.command('xcode-tests', [sys.executable, '-c', script], timeout=60, startup=startup)
            step = run.manifest['steps'][-1]
            self.assertEqual((step['exit_code'], calls['reset']), (0, []))
            self.assertNotIn('startup_stalls', step)
            self.assertEqual(len(step['slow_starts']), 1)

    def test_a_first_launchs_late_output_does_not_switch_off_the_second_launchs_watch(self):
        # Codex audit of debe880, P2: the accumulated log held the first launch's Test Suite line (printed
        # while it was being stopped), so the second launch was never judged and could hang to the budget.
        with tempfile.TemporaryDirectory() as temporary:
            run = verification.Run(Path(temporary) / 'run', 'adapters')
            calls, startup = self.watch()
            script = ('import signal, sys, time\n'
                      'def stop(*_):\n'
                      '    print("Test Suite \'Selected tests\' started at now.", flush=True); sys.exit(0)\n'
                      'signal.signal(signal.SIGTERM, stop)\n'
                      'time.sleep(60)\n')
            with self.assertRaisesRegex(RuntimeError, r'printed no test output in 2 launch\(es\)'):
                run.command('xcode-tests', [sys.executable, '-c', script], timeout=60, startup=startup)
            self.assertEqual([s['attempt'] for s in run.manifest['steps'][-1]['startup_stalls']], [1, 2])
            self.assertLess(run.manifest['steps'][-1]['seconds'], 30)

    def test_slow_run_that_has_started_its_tests_is_not_relaunched(self):
        with tempfile.TemporaryDirectory() as temporary:
            run = verification.Run(Path(temporary) / 'run', 'adapters')
            calls, startup = self.watch()
            script = ('import time; print("Test Suite \'Selected tests\' started at now.", flush=True); time.sleep(3)')
            run.command('xcode-tests', [sys.executable, '-c', script], timeout=60, startup=startup)
            step = run.manifest['steps'][-1]
            self.assertNotIn('startup_stalls', step)
            self.assertEqual((calls['diagnose'], calls['reset']), ([], []))

    def test_stall_evidence_never_raises_and_lists_this_devices_processes(self):
        with tempfile.TemporaryDirectory() as temporary:
            folder = Path(temporary) / 'stall'
            device = 'A1B2C3D4-0000-0000-0000-SYNTHETIC00'
            listing = (f'  101 05:10 S /x/Devices/{device}/data/Containers/Bundle/Application/Y/SpokenMarginsApp.app/SpokenMarginsApp\n'
                       '  102 05:10 S /Applications/Other.app/Other\n')
            sampled = []

            def run_(args, **kwargs):
                if args[0] == 'ps':
                    return subprocess.CompletedProcess(args, 0, stdout=listing)
                sampled.append(args[:2])
                return subprocess.CompletedProcess(args, 0, stdout='')

            with patch.object(verification.subprocess, 'run', side_effect=run_):
                found = verification.stall_evidence(device, folder)
            self.assertEqual(found, {'processes': 1, 'samples': [{'pid': 101, 'exit': 0}]})
            self.assertEqual(sampled, [['sample', '101']])
            self.assertIn(device, (folder / 'processes.txt').read_text())
            with patch.object(verification.subprocess, 'run', side_effect=OSError('no ps')):
                self.assertIn('error', verification.stall_evidence(device, folder))

    def test_unclassified_trace_and_fixture_and_empty_selection_are_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for directory in ('Contracts', 'validation', 'TestPlans'):
                shutil.copytree(inventory.ROOT / directory, root / directory)
            for directory in ('App', 'Packages', 'scripts'):
                (root / directory).symlink_to(inventory.ROOT / directory, target_is_directory=True)
            trace = root / 'Contracts/traces/omitted-regression.json'
            trace.write_text('{}')
            self.assertTrue(any('Trace disposition mismatch' in e for e in inventory.validate(root)))
            trace.unlink()
            fixture = root / 'Contracts/fixtures/unclassified.json'
            fixture.write_text('{}')
            self.assertTrue(any('without schema coverage' in e for e in inventory.validate(root)))
            fixture.unlink()
            for path in (root / 'Contracts/fixtures/capabilities').glob('*.json'):
                path.unlink()
            self.assertTrue(any('Empty fixture/schema selection' in e for e in inventory.validate(root)))

    def plan_root(self, root, **plans):
        """A repo for inventory.validate(): the real contracts, traces and scripts (symlinked, never written),
        and a made-up app of one test class (three methods) and one UI class, with plans that are correct
        unless `plans` replaces one: {plan name: [(target, {'selectedTests': ...}), ...]}."""
        for directory in ('Contracts', 'validation', 'Packages', 'scripts'):
            (root / directory).symlink_to(inventory.ROOT / directory, target_is_directory=True)
        tests, ui = root / 'App/SpokenMarginsAppTests', root / 'App/SpokenMarginsAppUITests'
        tests.mkdir(parents=True)
        ui.mkdir(parents=True)
        (tests / 'Gate4WatchPackageRenderTests.swift').write_text(
            'final class Gate4WatchPackageRenderTests: XCTestCase { func testRender() {} }')
        (tests / 'SpeechTests.swift').write_text(
            'final class SpeechTests: XCTestCase { func testA() {} func testB() {} func testC() {} }')
        (ui / 'TourUITests.swift').write_text('final class TourUITests: XCTestCase { func testTour() {} func testShare() {} }')
        app, uis = 'SpokenMarginsAppTests', 'SpokenMarginsAppUITests'
        selecting = lambda target, *tests: (target, {'selectedTests': list(tests)} if tests else {})
        defaults = {'AppBehavior': [selecting(app, 'SpeechTests/testA', 'SpeechTests/testC')],
                    'AudioAdapters': [selecting(app, 'SpeechTests/testB')],
                    'Release': [selecting(app), selecting(uis)],
                    'UISeams': [selecting(uis, 'TourUITests/testTour')],
                    'SpeechCanary': [selecting(uis, 'TourUITests/testShare')],
                    'Smoke': [selecting(uis, 'TourUITests/testTour')]}
        (root / 'TestPlans').mkdir()
        (root / 'TestPlans/scripted-journeys.json').write_text(json.dumps({'version': 1, 'gating': [], 'probation': []}))
        for name, targets in {**defaults, **plans}.items():
            (root / f'TestPlans/{name}.xctestplan').write_text(json.dumps({'testTargets': [
                dict(target={'name': target}, **selection) for target, selection in targets]}))

    def test_inventory_accepts_plans_that_partition_the_app_tests_and_release_runs_everything(self):
        with tempfile.TemporaryDirectory() as temporary:
            self.plan_root(Path(temporary))
            self.assertEqual(inventory.validate(Path(temporary)), [])  # the others below change one plan of this

    def test_inventory_rejects_app_tests_that_are_in_both_plans_or_in_neither(self):
        partition = 'AppBehavior and AudioAdapters must partition all active app tests'
        app = 'SpokenMarginsAppTests'
        for label, plans in (
                ('SpeechTests/testB runs in both plans (twice in T3)', {
                    'AudioAdapters': [(app, {'selectedTests': ['SpeechTests/testB', 'SpeechTests/testA']})]}),
                ('SpeechTests/testC runs in neither (never in T3)', {
                    'AppBehavior': [(app, {'selectedTests': ['SpeechTests/testA']})]})):
            with self.subTest(label), tempfile.TemporaryDirectory() as temporary:
                self.plan_root(Path(temporary), **plans)
                self.assertEqual(inventory.validate(Path(temporary)), [partition])

    def test_inventory_rejects_a_release_plan_that_leaves_out_an_app_or_ui_test(self):
        release = 'Release must include all active app and UI tests'
        app, ui = 'SpokenMarginsAppTests', 'SpokenMarginsAppUITests'
        for label, targets in (
                ('a UI test missing', [(app, {}), (ui, {'selectedTests': ['TourUITests/testTour']})]),
                ('an app test missing', [(app, {'selectedTests': ['SpeechTests/testA', 'SpeechTests/testB']}), (ui, {})])):
            with self.subTest(label), tempfile.TemporaryDirectory() as temporary:
                self.plan_root(Path(temporary), Release=targets)
                self.assertEqual(inventory.validate(Path(temporary)), [release])

    def test_inventory_rejects_a_ui_plan_that_selects_an_app_test(self):
        for plan in ('UISeams', 'SpeechCanary', 'Smoke'):
            with self.subTest(plan), tempfile.TemporaryDirectory() as temporary:
                self.plan_root(Path(temporary), **{plan: [
                    ('SpokenMarginsAppUITests', {'selectedTests': ['TourUITests/testTour']}),
                    ('SpokenMarginsAppTests', {'selectedTests': ['SpeechTests/testA']})]})
                self.assertEqual(inventory.validate(Path(temporary)), [f'{plan}: non-UI test selected'])

    def test_built_preprocessor_check_rejects_missing_entrypoint(self):
        with tempfile.TemporaryDirectory() as temporary:
            resource = Path(temporary) / 'broken.js'
            resource.write_text('var unrelated = {};')
            result = subprocess.run(['node', str(SCRIPTS / 'check-share-preprocessor.cjs'), str(resource)],
                                    capture_output=True, text=True, timeout=15)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('AssertionError', result.stderr)

    def test_zero_infrastructure_tests_are_not_a_pass(self):
        with tempfile.TemporaryDirectory() as temporary:
            run = verification.Run(Path(temporary) / 'run', 'test')
            with self.assertRaisesRegex(RuntimeError, 'zero tests'):
                run.command('runner-tests', [sys.executable, '-c', 'print("Ran 0 tests in 0.0s")'])

    def test_a_node_suite_that_ran_zero_tests_is_not_a_pass_for_the_browser_and_share_link_steps(self):
        # `node --test` exits 0 and prints "# tests 0" when its glob matches no files (a renamed folder).
        with tempfile.TemporaryDirectory() as temporary:
            run = verification.Run(Path(temporary) / 'run', 'test')
            for name in ('browser', 'share-link'):
                for label, output in (('a TAP summary of zero tests', '# tests 0'),
                                      ('no TAP summary at all', 'npm warn nothing to run')):
                    with self.subTest(name=name, label=label):
                        with self.assertRaisesRegex(RuntimeError, f'{"Browser runner" if name == "browser" else name} '
                                                                  'executed zero tests'):
                            run.command(name, [sys.executable, '-c', f'print({output!r})'])
                        step = run.manifest['steps'][-1]
                        self.assertEqual((step['executed_count'], step['exit_code']), (0, 0))  # it exited 0
                with self.subTest(name=name, label='a TAP summary of three tests'):
                    run.command(name, [sys.executable, '-c', 'print("TAP version 13\\n# tests 3\\n# pass 3")'])
                    step = run.manifest['steps'][-1]
                    self.assertEqual((step['executed_count'], step['errors']), (3, []))

    def test_hung_process_is_bounded_and_manifest_retains_failure(self):
        with tempfile.TemporaryDirectory() as temporary:
            run = verification.Run(Path(temporary) / 'run', 'test')
            with self.assertRaisesRegex(RuntimeError, '124'):
                run.command('hang', [sys.executable, '-c', 'import time; time.sleep(30)'], timeout=0.1)
            step = json.loads((run.output / 'manifest.json').read_text())['steps'][0]
            self.assertTrue(step['interrupted'])
            self.assertLess(step['seconds'], 5)

    def test_scripted_journey_list_names_real_ui_tests_once_each(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / 'TestPlans').mkdir()
            (root / 'App/SpokenMarginsAppUITests').mkdir(parents=True)
            (root / 'App/SpokenMarginsAppUITests/Tour.swift').write_text(
                'final class ScreenTourUITests: XCTestCase { func testTour() {} func testShare() {} }')
            listing = root / 'TestPlans/scripted-journeys.json'
            write = lambda **lists: listing.write_text(json.dumps({'version': 1, 'gating': [], 'probation': [], **lists}))
            write(gating=[{'test': 'SpokenMarginsAppUITests/ScreenTourUITests/testTour', 'journey': 'screen tour'}],
                  probation=[{'test': 'SpokenMarginsAppUITests/ScreenTourUITests/testShare()', 'journey': 'J5'}])
            self.assertEqual(inventory.scripted_journey_errors(root), [])
            write(probation=[{'test': 'SpokenMarginsAppUITests/ScreenTourUITests/testRenamed', 'journey': 'J1'},
                             {'test': 'ScreenTourUITests', 'journey': 'J1'},
                             {'test': 'SpokenMarginsAppUITests/ScreenTourUITests'}])
            errors = inventory.scripted_journey_errors(root)
            self.assertEqual(len(errors), 3, errors)
            self.assertIn('testRenamed', errors[0])
            self.assertIn("'ScreenTourUITests'", errors[1])
            self.assertIn('names no journey', errors[2])
            write(gating=[{'test': 'SpokenMarginsAppUITests/ScreenTourUITests', 'journey': 'tour'}],
                  probation=[{'test': 'SpokenMarginsAppUITests/ScreenTourUITests', 'journey': 'tour'}])
            self.assertIn('also listed', inventory.scripted_journey_errors(root)[0])
            write(gating=[{'test': 'SpokenMarginsAppUITests/ScreenTourUITests', 'journey': 'tour'}],
                  probation=[{'test': 'SpokenMarginsAppUITests/ScreenTourUITests/testShare()', 'journey': 'J5'}])
            self.assertIn('also listed', inventory.scripted_journey_errors(root)[0])
            for malformed in ([], {'version': 1, 'gating': None, 'probation': []},
                              {'version': 1, 'gating': [{'test': 7, 'journey': 'J1'}, 'x'], 'probation': []}):
                listing.write_text(json.dumps(malformed))
                self.assertTrue(inventory.scripted_journey_errors(root), malformed)
            listing.write_text(json.dumps({'version': 1, 'gating': [], 'probation': [], 'passes': {}}))
            self.assertTrue(inventory.scripted_journey_errors(root))
            listing.unlink()
            self.assertTrue(inventory.scripted_journey_errors(root))


class InheritedSimulatorSlotTests(unittest.TestCase):
    def test_cli_passes_inherited_slot_to_the_app_runner(self):
        with tempfile.TemporaryDirectory() as temporary, \
                patch.object(verification, 'ROOT', Path(temporary)), \
                patch.object(verification, 'validate', return_value=[]), \
                patch.object(verification, 'input_identity', return_value='inputs'), \
                patch.object(verification, 'Run') as factory, \
                patch.object(sys, 'argv', ['verify-tests.py', '--plan', 'app', '--simulator-slot-fd', '8']):
            run = factory.return_value
            run.manifest = {'input_sha256': 'inputs'}
            self.assertEqual(verification.main(), 0)
            run.xcode.assert_called_once_with('app', None, False, None, [], simulator_slot_fd=8)

    def test_only_a_real_locked_simulator_slot_descriptor_can_be_inherited(self):
        import fcntl
        import lane_slots
        with tempfile.TemporaryDirectory() as temporary, patch.dict(os.environ, {'SM_LANE_STATE_DIR': temporary}):
            path = Path(temporary) / lane_slots.SIMULATOR_SLOT
            with path.open('a+') as handle:
                with self.assertRaises(ValueError):
                    verification.inherited_simulator_slot(handle.fileno())
                fcntl.flock(handle, fcntl.LOCK_EX)
                borrowed = verification.inherited_simulator_slot(handle.fileno())
                borrowed.close()
                self.assertTrue(lane_slots.simulator_job_running())
            self.assertFalse(lane_slots.simulator_job_running())
            with (Path(temporary) / 'wrong.lock').open('a+') as handle:
                fcntl.flock(handle, fcntl.LOCK_EX)
                with self.assertRaises(ValueError):
                    verification.inherited_simulator_slot(handle.fileno())


if __name__ == '__main__':
    unittest.main()
