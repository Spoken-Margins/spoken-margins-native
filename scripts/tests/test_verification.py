import importlib.util
import json
import shutil
import subprocess
from pathlib import Path
import sys
import tempfile
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

    def test_log_parser_preserves_failure_and_duration(self):
        log = "Test Case '-[App.ExportTests testIsolation]' failed (0.125 seconds)."
        self.assertEqual(verification.test_records(log), {
            'App/ExportTests/testIsolation': {'status': 'failed', 'seconds': 0.125}})

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

            def command(name, args, timeout=180, expected=None, allowed_skips=(), tests=False):
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


if __name__ == '__main__':
    unittest.main()
