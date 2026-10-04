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
import threading
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
        self.assertIn('runner-tests', [name for name, _ in calls])
        self.assertIsNone(dict(calls)['package']['probation'])
        self.assertFalse([step for step in manifest['steps'] if step.get('skipped')])
        self.assertEqual(status, 'verified')

    def runner_tests_beside(self, runner_tests, others):
        """Run the host steps with runner-tests and the other steps replaced; return (manifest, error, log)."""
        log, error = [], None
        with tempfile.TemporaryDirectory() as temporary, patch.dict(verification.os.environ, {}, clear=False):
            verification.os.environ.pop('CODEX_SANDBOX', None)
            run = verification.Run(Path(temporary) / 'run', 'fast')

            def command(name, args, **kw):
                if name != 'runner-tests':
                    raise AssertionError(name)
                return runner_tests(run, log)

            with patch.object(run, 'command', side_effect=command), \
                    patch.object(run, 'other_host_steps', side_effect=lambda: others(run, log)), \
                    patch.object(verification, 'input_identity', return_value=run.manifest['input_sha256']):
                try:
                    run.host_steps()
                except Exception as raised:  # noqa: BLE001
                    error = raised
            return run.manifest, error, log

    def test_runner_tests_run_beside_the_other_host_steps(self):
        # Lane throughput (2026-10-04): runner-tests took 127 s of every automerge run before anything
        # else started, though it used 46 s of CPU. Beside the package step, the plan is that much shorter.
        both_running = threading.Barrier(2, timeout=10)

        def runner_tests(run, log):
            both_running.wait()
            log.append('runner-tests done')

        def others(run, log):
            both_running.wait()  # times out (BrokenBarrierError) if runner-tests runs before or after
            log.append('others done')

        _, error, log = self.runner_tests_beside(runner_tests, others)
        self.assertIsNone(error)
        self.assertEqual(sorted(log), ['others done', 'runner-tests done'])

    def test_a_runner_tests_failure_still_fails_the_plan(self):
        def runner_tests(run, log):
            raise RuntimeError('runner-tests failed')

        _, error, log = self.runner_tests_beside(runner_tests, lambda run, log: log.append('others done'))
        self.assertEqual(str(error), 'runner-tests failed')
        self.assertEqual(log, ['others done'])

    def test_a_failing_step_stops_runner_tests_instead_of_waiting_for_it(self):
        def runner_tests(run, log):
            if not run.stop.wait(timeout=10):
                log.append('runner-tests was not told to stop')

        def others(run, log):
            raise RuntimeError('package failed')

        _, error, log = self.runner_tests_beside(runner_tests, others)
        self.assertEqual(str(error), 'package failed')
        self.assertEqual(log, [])

    def test_the_stop_signal_interrupts_a_running_command(self):
        with tempfile.TemporaryDirectory() as temporary:
            run = verification.Run(Path(temporary) / 'run', 'fast')
            run.stop.set()
            started = time.monotonic()
            with self.assertRaises(RuntimeError) as raised:
                run.command('runner-tests', [sys.executable, '-c', 'import time; time.sleep(60)'], timeout=120)
            self.assertLess(time.monotonic() - started, 30)
            self.assertIn('Process exit 124', str(raised.exception))
            self.assertTrue(run.manifest['steps'][0]['interrupted'])

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
