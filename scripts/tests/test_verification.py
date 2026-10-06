import contextlib
import importlib.util
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

    def host_step_calls(self, environment, changed=None):
        """(commands run, manifest, final status) for the host steps under an environment."""
        calls = []
        self.ops_ran = False
        audio = next(iter(verification.CODEX_SANDBOX_AUDIO_TESTS))
        with tempfile.TemporaryDirectory() as temporary, patch.dict(verification.os.environ, environment, clear=False):
            if not environment:
                verification.os.environ.pop('CODEX_SANDBOX', None)
            run = verification.Run(Path(temporary) / 'run', 'fast', changed)
            with patch.object(run, 'command', side_effect=lambda name, args, **kw: calls.append((name, kw))), \
                    patch.object(run, 'ops_steps', side_effect=lambda: setattr(self, 'ops_ran', True)), \
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

    def skipped_steps(self, manifest):
        return {step['name']: step['skipped'] for step in manifest['steps'] if step.get('skipped')}

    def test_a_lane_run_for_an_app_only_diff_runs_just_the_tests_that_read_the_app(self):
        # #862: runner-tests are about 2 minutes of a 10-minute run, and the ones that read App/ are seconds.
        calls, manifest, status, _ = self.host_step_calls({}, ['App/SpokenMarginsApp/Sources/SpokenMarginsApp/X.swift'])
        self.assertEqual(status, 'verified')
        self.assertIn('runner-tests', [name for name, _ in calls])
        self.assertFalse(self.ops_ran)
        self.assertEqual(list(self.skipped_steps(manifest)), ['ops'])
        self.assertIn('App/', manifest['runner_tests_note'])

    def test_a_lane_run_for_a_docs_only_diff_skips_both_and_records_why(self):
        calls, manifest, status, _ = self.host_step_calls({}, ['docs/workstreams/README.md'])
        self.assertNotIn('runner-tests', [name for name, _ in calls])
        self.assertFalse(self.ops_ran)
        skipped = self.skipped_steps(manifest)
        self.assertEqual(sorted(skipped), ['ops', 'runner-tests'])
        self.assertTrue(all(skipped.values()))
        self.assertEqual(status, 'verified')
        self.assertIn('package', [name for name, _ in calls])  # everything else still runs

    def test_a_diff_touching_scripts_or_github_runs_every_runner_test_and_the_ops_tests(self):
        for path in ('scripts/lane-runner.py', 'scripts/tests/test_x.py', '.github/workflows/lane.yml'):
            with self.subTest(path=path):
                calls, manifest, _, _ = self.host_step_calls({}, ['docs/a.md', path])
                self.assertIn('runner-tests', [name for name, _ in calls])
                self.assertTrue(self.ops_ran)
                self.assertFalse(self.skipped_steps(manifest))
                self.assertNotIn('runner_tests_note', manifest)

    def test_a_diff_touching_ops_runs_the_ops_tests_and_skips_the_runner_tests(self):
        calls, manifest, _, _ = self.host_step_calls({}, ['ops/dial/dial_gate.py'])
        self.assertTrue(self.ops_ran)
        self.assertEqual(list(self.skipped_steps(manifest)), ['runner-tests'])

    def test_no_diff_information_runs_every_step(self):
        for changed in (None, []):
            with self.subTest(changed=changed):
                calls, manifest, _, _ = self.host_step_calls({}, changed)
                self.assertEqual([name for name, _ in calls][0], 'runner-tests')
                self.assertTrue(self.ops_ran)
                self.assertFalse(self.skipped_steps(manifest))

    def test_the_readers_run_names_modules_that_exist_and_would_catch_an_app_change(self):
        for module in verification.RUNNER_TEST_READERS:
            self.assertTrue((SCRIPTS / 'tests' / f'{module}.py').exists(), module)
        calls = []
        with tempfile.TemporaryDirectory() as temporary:
            run = verification.Run(Path(temporary) / 'run', 'fast', ['App/X.swift'])
            with patch.object(run, 'command', side_effect=lambda name, args, **kw: calls.append((name, args))), \
                    patch.object(run, 'ops_steps'), patch.object(verification, 'swift_tests', return_value=set()), \
                    patch.object(verification, 'input_identity', return_value=run.manifest['input_sha256']):
                run.host_steps()
        args = dict(calls)['runner-tests']
        self.assertEqual(args[-len(verification.RUNNER_TEST_READERS):], list(verification.RUNNER_TEST_READERS))
        # Run the loader for real, on the scan modules only (this module is one of the readers): the runner's
        # "Ran N tests" line is there for the zero-tests check.
        scans = [module for module in verification.RUNNER_TEST_READERS if module.startswith('test_filled_button')]
        done = subprocess.run([sys.executable, *args[1:-len(verification.RUNNER_TEST_READERS)], *scans],
                              cwd=SCRIPTS.parent, capture_output=True, text=True)
        self.assertRegex(done.stderr, r'Ran \d+ tests? in ')

    def test_the_changed_files_list_is_read_or_ignored(self):
        with tempfile.TemporaryDirectory() as temporary:
            listing = Path(temporary) / 'changed.txt'
            listing.write_text('docs/a.md\n\nApp/b.swift\n')
            self.assertEqual(verification.read_changed_files(listing), ['docs/a.md', 'App/b.swift'])
            listing.write_text('\n')
            self.assertIsNone(verification.read_changed_files(listing))
            self.assertIsNone(verification.read_changed_files(Path(temporary) / 'missing.txt'))
            self.assertIsNone(verification.read_changed_files(None))

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

    def test_the_sessionkit_script_still_builds_and_tests_with_no_argument(self):
        script = (SCRIPTS / 'run-sessionkit-tests.sh').read_text()
        self.assertIn('"") exec "$ROOT/scripts/host-test-lane" swift test ', script)
        self.assertIn('--build-only) exec "$ROOT/scripts/host-test-lane" swift build --build-tests', script)
        self.assertIn('--skip-build) exec "$ROOT/scripts/host-test-lane" swift test --skip-build', script)

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

            def command(name, args, timeout=180, expected=None, allowed_skips=(), tests=False, probation=()):
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

            def command(name, args, timeout=180, expected=None, allowed_skips=(), tests=False, probation=None):
                commands[name] = (args, expected)
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
            args, expected = commands['xcode-tests']
            method = 'SpokenMarginsAppTests/SpeechTests/testBundled'
            self.assertEqual([a for a in args if a.startswith('-only-testing:')], [f'-only-testing:{method}'])
            self.assertEqual(expected, {method})

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
