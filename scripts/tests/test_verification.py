import contextlib
import importlib.util
import inspect
import io
import json
import plistlib
import re
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
    def test_a_step_does_not_inherit_the_trunk_setting(self):
        # #1492: the lane and the Mac export SM_TRUNK=main; suites written for the default trunk failed under it.
        with tempfile.TemporaryDirectory() as temporary, patch.dict(os.environ, {'SM_TRUNK': 'main', 'KEEP': '1'}):
            run = verification.Run(Path(temporary) / 'run', 'fast')
            with patch.object(verification, 'build_slot', return_value=contextlib.nullcontext()), \
                    patch.object(verification.subprocess, 'Popen') as process:
                process.return_value.wait.return_value = 0
                run.command('probe', ['true'])
            env = process.call_args.kwargs['env']
            self.assertNotIn('SM_TRUNK', env)
            self.assertEqual(env['KEEP'], '1')
            self.assertEqual(os.environ['SM_TRUNK'], 'main')  # the caller's own environment is left alone

    def test_test_without_building_does_not_take_a_build_slot(self):
        # #1330: even an empty test run used to queue behind compilers and hold their slot.
        with tempfile.TemporaryDirectory() as temporary:
            run = verification.Run(Path(temporary) / 'run', 'app')
            with patch.object(verification, 'build_slot', return_value=contextlib.nullcontext()) as slot, \
                    patch.object(verification.subprocess, 'Popen') as process:
                process.return_value.wait.return_value = 0
                run.command('xcode-tests', ['xcodebuild', 'test-without-building'])
            slot.assert_not_called()
            with patch.object(verification, 'build_slot', return_value=contextlib.nullcontext()) as slot, \
                    patch.object(verification.subprocess, 'Popen') as process:
                process.return_value.wait.return_value = 0
                run.command('build-for-testing', ['xcodebuild', 'build-for-testing'])
            slot.assert_called_once()

    def test_build_only_never_selects_or_boots_a_simulator_and_stale_build_is_refused(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / 'repo'
            commands = []
            with patch.object(verification, 'ROOT', root), \
                    patch.object(verification, 'input_identity', return_value='inputs'), \
                    patch.object(verification, 'capture', return_value='toolchain'), \
                    patch.object(verification.Run, 'simulator') as simulator, \
                    patch.object(verification.lane_sim, 'boot') as boot, \
                    patch.object(verification.Run, 'command',
                                 side_effect=lambda name, args, **kw: commands.append(name)):
                run = verification.Run(Path(temporary) / 'run', 'app')
                with self.assertRaisesRegex(RuntimeError, 'missing or stale'):
                    run.xcode_build('app', 'runtime1', require_build=True)
                self.assertNotIn('build-for-testing', commands)
                run.xcode_build('app', 'runtime1')
                run.xcode_build('adapters', 'runtime1', require_build=True)
                self.assertEqual(commands.count('build-for-testing'), 1)
                with self.assertRaisesRegex(RuntimeError, 'missing or stale'):
                    run.xcode_build('adapters', 'runtime2', require_build=True)
                simulator.assert_not_called()
                boot.assert_not_called()

    def test_the_app_build_uses_the_shared_compilation_cache_and_records_its_hits(self):
        # #1331: each T3 builds in fresh DerivedData; the cache outside the tree is what a later build reuses.
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / 'repo'
            commands = []

            def command(run, name, args, **kw):
                commands.append((name, args))
                if name == 'build-for-testing':
                    (run.output / f'{name}.log').write_text(
                        'note: 0 hits / 508 cacheable tasks (0%)\n** TEST BUILD SUCCEEDED **\n'
                        'note: 441 hits / 508 cacheable tasks (87%)\n')

            with patch.object(verification, 'ROOT', root), \
                    patch.object(verification, 'input_identity', return_value='inputs'), \
                    patch.object(verification, 'capture', return_value='toolchain'), \
                    patch.object(verification.Run, 'command', autospec=True, side_effect=command):
                run = verification.Run(Path(temporary) / 'run', 'app')
                run.xcode_build('app', 'runtime1')
            build = next(args for name, args in commands if name == 'build-for-testing')
            settings = dict(arg.split('=', 1) for arg in build if '=' in arg and not arg.startswith('-'))
            cache = Path(settings['COMPILATION_CACHE_CAS_PATH'])
            self.assertEqual(settings['COMPILATION_CACHE_ENABLE_CACHING'], 'YES')
            self.assertEqual(cache, verification.state_dir() / 'compilation-cache')
            self.assertFalse(cache.is_relative_to(root))  # the checkout's clean must not empty it
            self.assertEqual(settings['COMPILATION_CACHE_LIMIT_SIZE'], verification.COMPILATION_CACHE_LIMIT)
            for language in ('SWIFT', 'CLANG'):
                self.assertEqual(settings[f'{language}_ENABLE_PREFIX_MAPPING'], 'YES')
                self.assertEqual(settings[f'{language}_ENABLE_PROJECT_PREFIX_MAPPING'], 'YES')
                self.assertEqual(settings[f'{language}_OTHER_PREFIX_MAPPINGS'], f'"{root}=/^tree"')
            self.assertEqual(build[-1], 'build-for-testing')
            self.assertEqual(run.manifest['compilation_cache'], '441 hits / 508 cacheable tasks (87%)')
            self.assertIsNone(verification.compilation_cache_hits('** TEST BUILD SUCCEEDED **\n'))

    def test_both_behavior_plans_reuse_one_build_and_inputs_invalidate_it(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / 'repo'
            self.app_test_root(root)
            (root / '.build/verification/SpokenMarginsAppBehavior').mkdir(parents=True)
            commands = []
            device = {'udid': 'U', 'state': 'Booted', 'runtime': 'iOS-26', 'name': 'Other'}
            with patch.object(verification, 'ROOT', root), \
                    patch.object(verification, 'input_identity', return_value='inputs') as identity, \
                    patch.object(verification, 'capture', return_value='toolchain'), \
                    patch.object(verification.Run, 'simulator', return_value=(device, False)), \
                    patch.object(verification, 'refuse_unsafe'), \
                    patch.object(verification.lane_sim, 'unsafe_devices', return_value={}), \
                    patch.object(verification.Run, 'command',
                                 side_effect=lambda name, args, **kw: commands.append((name, args))):
                for index, plan in enumerate(('app', 'adapters', 'app')):
                    if index == 2:
                        identity.return_value = 'changed-inputs'
                    run = verification.Run(Path(temporary) / f'run-{index}', plan)
                    run.xcode(plan, 'U', rebuild=False)
                    if index == 1:
                        self.assertTrue(run.manifest['reused_build'])
                builds = [args for name, args in commands if name == 'build-for-testing']
                self.assertEqual(len(builds), 2)  # one for both plans, one after the source changed
                self.assertTrue(all('-testPlan' not in args for args in builds))
                self.assertTrue(all('generic/platform=iOS Simulator' in args for args in builds))
                tests = [args for name, args in commands if name == 'xcode-tests']
                self.assertEqual([args[args.index('-testPlan') + 1] for args in tests],
                                 ['AppBehavior', 'AudioAdapters', 'AppBehavior'])

    def test_compilation_cache_settings_apply_only_to_the_build_step(self):
        # #1331: caching changes compilation, while running the prepared tests keeps its command unchanged.
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / 'repo'
            self.app_test_root(root)
            commands = []
            device = {'udid': 'U', 'state': 'Booted', 'runtime': 'iOS-26', 'name': 'Other'}
            with patch.object(verification, 'ROOT', root), \
                    patch.object(verification, 'input_identity', return_value='inputs'), \
                    patch.object(verification, 'capture', return_value='toolchain'), \
                    patch.object(verification.Run, 'simulator', return_value=(device, False)), \
                    patch.object(verification, 'refuse_unsafe'), \
                    patch.object(verification.lane_sim, 'unsafe_devices', return_value={}), \
                    patch.object(verification.Run, 'command',
                                 side_effect=lambda name, args, **kw: commands.append((name, args))):
                run = verification.Run(Path(temporary) / 'run', 'app')
                run.xcode('app', 'U', rebuild=False)
                settings = verification.compilation_cache_settings(root)
            build = dict(commands)['build-for-testing']
            tests = dict(commands)['xcode-tests']
            self.assertIn('test-without-building', tests)
            for setting in settings:
                self.assertIn(setting, build)
                self.assertNotIn(setting, tests)

    def setUp(self):
        # The host steps look up and write SessionKit pass records in the lane's state folder (#1328): keep a
        # developer's or the lane Mac's real records out of these tests (tests/test_sessionkit_steps.py covers them).
        state = tempfile.TemporaryDirectory()
        self.addCleanup(state.cleanup)
        for patcher in (patch.object(verification, 'state_dir', return_value=Path(state.name)),
                        patch.object(verification.sessionkit_pass, 'toolchain', return_value=None),
                        # #705's settle sleeps for real (up to 20 s) whenever a test runs run.xcode twice on one
                        # device: the first call marks it quiet in this shared state folder. Tests of the settle
                        # itself patch it again or inject sleep= (SimulatorSettleTests).
                        patch.object(verification, 'settle_before_tests',
                                     return_value={'seconds_quiet': None, 'waited_seconds': 0.0})):
            patcher.start()
            self.addCleanup(patcher.stop)

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

    def crash_files(self, folder, process, count, bundle='com.apple.intelligencetasksd', path=None):
        """`count` real .ips reports of one process, as macOS writes them (JSON header line, JSON body)."""
        files = []
        for index in range(count):
            head = {'app_name': process, 'name': process, 'bundleID': bundle}
            body = {'procName': process, 'procPath': path or f'/Volumes/V/RuntimeRoot/usr/libexec/{process}'}
            report = Path(folder) / f'{process}-2026-10-24-12000{index}.ips'
            report.write_text(json.dumps(head) + '\n' + json.dumps(body))
            files.append(report)
        return files

    def run_with_crashes(self, folder, reports, runner):
        run = verification.Run(Path(folder) / 'run', 'test')
        run.manifest['destination'] = {'udid': 'synthetic-device'}
        run.crash_baseline = {}
        with patch.dict(os.environ, {'RUNNER_ENVIRONMENT': runner}), \
                patch.object(verification, 'new_crash', side_effect=self.crash_reports(*reports)), \
                patch.object(verification.subprocess, 'run') as shutdown:
            shutdown.return_value.returncode = 0
            try:
                run.command('crash-check', [sys.executable, '-c', 'import time; time.sleep(3)'])
            except RuntimeError:
                pass
        return run.manifest['steps'][-1]

    def test_a_hosted_runner_counts_three_system_daemon_crashes_in_seconds_and_goes_on(self):
        # #2602: intelligencetasksd crashed three times in 20 s on the hosted Mac and ended a good run.
        with tempfile.TemporaryDirectory() as temporary:
            reports = self.crash_files(temporary, 'intelligencetasksd', 3)
            step = self.run_with_crashes(temporary, reports, 'github-hosted')
            self.assertEqual(step['exit_code'], 0)
            self.assertNotIn('simulator_crash_report', step)
            self.assertEqual(step['hosted_system_process_crashes'], {'intelligencetasksd': 3})

    def test_a_hosted_runner_counts_a_daemon_report_that_names_no_apple_bundle_or_runtime_path(self):
        # #2602: run 40126811473's intelligencetasksd reports were not recognised as Apple's, so three in 20 s stopped the run.
        with tempfile.TemporaryDirectory() as temporary:
            reports = self.crash_files(temporary, 'intelligencetasksd', 3, bundle='', path='/usr/libexec/intelligencetasksd')
            step = self.run_with_crashes(temporary, reports, 'github-hosted')
            self.assertEqual(step['exit_code'], 0)
            self.assertEqual(step['hosted_system_process_crashes'], {'intelligencetasksd': 3})

    def test_a_hosted_runner_still_stops_on_a_flood_of_the_app_or_its_test_runner(self):
        for process, bundle, path in (('SpokenMarginsApp', 'com.spokenmargins.native', None),
                                      ('SpokenMarginsAppUITests-Runner', 'com.spokenmargins.UITests.xctrunner', None),
                                      ('xctest', 'com.apple.dt.xctest', '/Volumes/V/RuntimeRoot/usr/bin/xctest'),
                                      ('SpringBoard', 'com.apple.springboard', None)):
            with self.subTest(process=process), tempfile.TemporaryDirectory() as temporary:
                reports = self.crash_files(temporary, process, 3, bundle=bundle, path=path)
                step = self.run_with_crashes(temporary, reports, 'github-hosted')
                self.assertEqual(step['exit_code'], 124)
                self.assertEqual(step['simulator_crash_report'], str(reports[-1]))
                self.assertNotIn('hosted_system_process_crashes', step)

    def test_a_hosted_runner_stops_on_a_report_it_cannot_read(self):
        reports = [f'intelligencetasksd-2026-10-24-12000{i}.ips' for i in range(3)]
        with tempfile.TemporaryDirectory() as temporary:
            step = self.run_with_crashes(temporary, reports, 'github-hosted')
            self.assertEqual(step['exit_code'], 124)

    def test_a_self_hosted_runner_stops_on_the_same_daemon_flood(self):
        # The Mac's rule is unchanged: crash dialogs fill Cole's screen.
        for runner in ('self-hosted', ''):
            with self.subTest(runner=runner), tempfile.TemporaryDirectory() as temporary:
                reports = self.crash_files(temporary, 'intelligencetasksd', 3)
                step = self.run_with_crashes(temporary, reports, runner)
                self.assertEqual(step['exit_code'], 124)
                self.assertEqual(step['simulator_crash_report'], str(reports[-1]))

    @patch.dict(os.environ, {'RUNNER_ENVIRONMENT': 'self-hosted'})  # a hosted runner scales the budget (#2602)
    def test_a_hung_shutdown_after_a_run_does_not_replace_the_error_that_ended_it(self):
        # #2602: the finally's 60 s shutdown timed out on a hosted Mac and its TimeoutExpired hid why 0 tests ran.
        def hang(command, **kwargs):
            raise subprocess.TimeoutExpired(command, kwargs['timeout'])

        output = io.StringIO()
        with patch.object(verification.subprocess, 'run', hang), contextlib.redirect_stdout(output):
            try:
                try:
                    raise RuntimeError('simulator-boot: the real reason')
                finally:
                    verification.shut_down_without_hiding_the_error('UDID-1')
            except RuntimeError as error:
                self.assertEqual(str(error), 'simulator-boot: the real reason')
            else:
                self.fail('the original error should still be raised')
        self.assertIn('did not finish in 60s', output.getvalue())

    def test_simctl_timeouts_scale_on_a_hosted_runner_only(self):
        # #2602: the class behind three proof runs that died on three fixed short simctl timeouts.
        hosted, ours = {'RUNNER_ENVIRONMENT': 'github-hosted'}, {'RUNNER_ENVIRONMENT': 'self-hosted'}
        self.assertEqual(verification.simctl_timeout(60, hosted), 60 * verification.HOSTED_SIMCTL_FACTOR)
        self.assertEqual(verification.simctl_timeout(60, ours), 60)
        self.assertEqual(verification.simctl_timeout(60, {}), 60)

    def test_a_hung_or_missing_simctl_housekeeping_call_is_noted_and_never_raised(self):
        # #2602: `simctl uninstall` timed out after 60 s and the run ended with 0 passed, 0 failed.
        for failure in (subprocess.TimeoutExpired(['simctl'], 60), OSError('no xcrun')):
            def fail(command, **kwargs):
                raise failure
            with self.subTest(failure=type(failure).__name__), patch.dict(os.environ, {'RUNNER_ENVIRONMENT': 'github-hosted'}), \
                    patch.object(verification.subprocess, 'run', fail), contextlib.redirect_stdout(io.StringIO()) as output:
                self.assertFalse(verification.simctl_quietly(['uninstall', 'UDID-1', 'com.example.app']))
            self.assertIn('simctl uninstall UDID-1 com.example.app', output.getvalue())

    def test_a_hung_uninstall_on_a_reused_device_stops_the_run_but_not_installed_is_fine(self):
        def hang(command, **kwargs):
            raise subprocess.TimeoutExpired(command, kwargs['timeout'])
        with patch.object(verification.subprocess, 'run', hang):
            with self.assertRaisesRegex(RuntimeError, 'simulator-clean.*did not finish'):
                verification.uninstall_from_reused_device('UDID-1', 'com.example.app')
        not_installed = subprocess.CompletedProcess([], 1)
        with patch.object(verification.subprocess, 'run', lambda *a, **k: not_installed):
            verification.uninstall_from_reused_device('UDID-1', 'com.example.app')

    def test_housekeeping_gets_the_scaled_budget_on_a_hosted_runner(self):
        seen = {}

        def record(command, **kwargs):
            seen['timeout'] = kwargs['timeout']
        for runner, expected in (('github-hosted', 60 * verification.HOSTED_SIMCTL_FACTOR), ('self-hosted', 60)):
            with self.subTest(runner=runner), patch.dict(os.environ, {'RUNNER_ENVIRONMENT': runner}), \
                    patch.object(verification.subprocess, 'run', record):
                self.assertTrue(verification.simctl_quietly(['shutdown', 'UDID-1']))
            self.assertEqual(seen['timeout'], expected)

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
            with patch.dict(os.environ, {'SM_LANE_STATE_DIR': str(state)}), \
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
                    patch.object(verification.host_audio, 'audio_output', return_value={'usable': True, 'why': 'test'}), \
                    patch.object(verification, 'swift_tests',
                                 side_effect=lambda folder: {audio.split('/', 1)[1], 'OtherTests/testX'}
                                 if folder.name == 'SessionKitTests' else set()), \
                    patch.object(verification, 'input_identity', return_value=run.manifest['input_sha256']):
                run.host_steps()
            return calls, run.manifest, verification.passed_status(), audio

    def package_failing(self, usable, failed, **step):
        """The manifest and error from the host steps when the package step fails these tests."""
        with tempfile.TemporaryDirectory() as temporary, patch.dict(verification.os.environ, {}, clear=False):
            verification.os.environ.pop('CODEX_SANDBOX', None)
            run = verification.Run(Path(temporary) / 'run', 'fast')

            def command(name, args, **kw):
                if name == 'package':
                    run.manifest['steps'].append({
                        'name': name, 'tests': {t: {'status': 'failed'} for t in failed},
                        'errors': ['Process exit 1', *(f'Failed: {t}' for t in failed)], **step})
                    raise RuntimeError('Failed: ' + ', '.join(failed))

            with patch.object(run, 'command', side_effect=command), patch.object(run, 'ops_steps'), \
                    patch.object(verification.host_audio, 'audio_output',
                                 return_value={'usable': usable, 'why': 'lid closed'}), \
                    patch.object(verification, 'swift_tests', return_value=set()), \
                    patch.object(verification, 'input_identity', return_value=run.manifest['input_sha256']):
                with self.assertRaises(RuntimeError) as raised:
                    run.host_steps()
            return run.manifest, str(raised.exception)

    def test_real_player_failures_with_no_sound_output_are_a_lane_fault(self):
        # #909: the same real-player tests failed for every PR while the lane Mac's lid was closed.
        player = ['SessionKitTests/RealPlayerMarginMomentTests/testMarginPlays',
                  'SessionKitTests/RealPlayerPodcastEvidenceTests/testTap',
                  'SessionKitTests/StreamSeekLifecycleTests/testSeek']
        manifest, message = self.package_failing(usable=False, failed=player)
        self.assertEqual(manifest['lane_fault'], 'no audio output: lid closed')
        self.assertTrue(message.startswith('lane fault, not the PR: no audio output'), message)
        self.assertEqual(manifest['audio_output'], {'usable': False, 'why': 'lid closed'})

    def test_an_output_that_never_starts_is_a_lane_fault_before_the_package_tests_run(self):
        # #1956, 2026-10-17: BlackHole 2ch was the default output and never started, so the real-player tests
        # hung the package step for 17 minutes on every PR, and the reports blamed the PRs.
        calls = []
        with tempfile.TemporaryDirectory() as temporary, patch.dict(verification.os.environ, {}, clear=False):
            verification.os.environ.pop('CODEX_SANDBOX', None)
            run = verification.Run(Path(temporary) / 'run', 'fast')
            stuck = {'usable': False, 'stuck': True, 'why': 'the default output (BlackHole 2ch) does not start'}
            with patch.object(run, 'command', side_effect=lambda name, args, **kw: calls.append(name)), \
                    patch.object(run, 'ops_steps'), \
                    patch.object(verification.host_audio, 'audio_output', return_value=stuck), \
                    patch.object(verification, 'swift_tests', return_value=set()), \
                    patch.object(verification, 'input_identity', return_value=run.manifest['input_sha256']):
                with self.assertRaises(RuntimeError) as raised:
                    run.host_steps()
        self.assertEqual(run.manifest['lane_fault'], 'no audio output: the default output (BlackHole 2ch) does not start')
        self.assertTrue(str(raised.exception).startswith('lane fault, not the PR: no audio output'), raised.exception)
        self.assertNotIn('package', calls)
        self.assertNotIn('package-core', calls)

    def test_other_failures_stay_the_prs_even_with_no_sound_output_or_with_it(self):
        player = 'SessionKitTests/RealPlayerMarginMomentTests/testMarginPlays'
        for name, step in (('a later test crashed, so tests are missing', {'errors': [
                                'Process exit 1', f'Failed: {player}', 'Missing 40 tests; first ten: []']}),
                           ('the step timed out', {'interrupted': True})):
            with self.subTest(name):
                manifest, message = self.package_failing(False, [player], **step)
                self.assertNotIn('lane_fault', manifest)
        for name, usable, failed in (
                ('a player test and a sharing test', False, [player, 'SessionKitTests/SharingTests/testPacket']),
                ('a similarly named class', False, ['SessionKitTests/RealPlayerlessTests/testX']),
                ('sound works, so the player tests failing is the code', True, [player])):
            with self.subTest(name):
                manifest, message = self.package_failing(usable, failed)
                self.assertNotIn('lane_fault', manifest)
                self.assertNotIn('lane fault', message)

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
        # shipped-compat (test_shipped_compat_step.py) and tools (test_tools_step.py) follow their own path filters,
        # not the runner and ops test scopes.
        return {step['name']: step['skipped'] for step in manifest['steps']
                if step.get('skipped') and step['name'] not in ('shipped-compat', 'tools')}

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

    def test_a_diff_touching_the_root_agents_file_runs_the_ops_tests(self):
        # The Codex audit's tests check that AGENTS.md is at the repository root (Codex audit of #898 on 4ef1b0f).
        self.host_step_calls({}, ['App/X.swift', 'AGENTS.md'])
        self.assertTrue(self.ops_ran)

    def test_every_runner_test_that_reads_the_repository_outside_scripts_is_covered(self):
        # The lane's warm-build tests copy the root .gitignore, and next's research and hot-file tests read
        # research/ and the hot files under App/: a diff to any of them must still reach those tests (audit of #898).
        self.assertEqual(verification.runner_test_scope(['App/X.swift', '.gitignore'])[0], 'all')
        for path in ('research/B4/README.md', 'App/SpokenMarginsApp/Sources/SpokenMarginsApp/Gate1AppModel.swift'):
            with self.subTest(path=path):
                scope, why = verification.runner_test_scope([path])
                self.assertEqual(scope, 'readers')
        self.assertIn('test_research_tests', verification.RUNNER_TEST_READERS)
        self.assertIn('test_hot_file_ratchet', verification.RUNNER_TEST_READERS)
        # The lane runner's T3 tests plan against the real TestPlans/ and app test sources: renaming an app test
        # or editing a plan must still reach them (found in review of #898).
        for name in ('test_lane_runner.ScopeClassTests', 'test_lane_runner.T3Tests',
                     'test_lane_runner.OnlyTestingTests', 'test_lane_sim.LaneSimTests', 'test_sharing_kit'):
            self.assertIn(name, verification.RUNNER_TEST_READERS)
        for path in ('TestPlans/AudioAdapters.xctestplan', 'App/SpokenMarginsAppTests/Gate1AppModelWorkflowTests.swift'):
            self.assertEqual(verification.runner_test_scope([path])[0], 'readers', path)
        # The sharing kit's tests (next, #848) read the kit under docs/ and the packet sources under Packages/.
        self.assertIn('test_sharing_kit', verification.RUNNER_TEST_READERS)
        for path in ('docs/sharing-test-kit/kit.json', 'Packages/SessionKitTools/Sources/CoopPacket/PacketBuilder.swift'):
            self.assertEqual(verification.runner_test_scope([path])[0], 'readers', path)
        # The third-party notices test (#1823) reads the dependency manifests and the generated list.
        self.assertIn('test_third_party_notices', verification.RUNNER_TEST_READERS)
        for path in ('package.json', 'requirements-dev.txt', 'docs/legal/third-party-components.json',
                     'THIRD_PARTY_NOTICES.md', 'Design/UXProposal20260909/package.json'):
            self.assertEqual(verification.runner_test_scope([path])[0], 'readers', path)
        self.assertEqual(verification.runner_test_scope(['docs/a.md'])[0], 'none')
        # The task-cost map test (#2396) checks the map's budgets and markers: a PR that edits only the map
        # must run it before the merge, not leave the red to the next PR that touches scripts/.
        self.assertIn('test_task_cost_map', verification.RUNNER_TEST_READERS)
        self.assertEqual(verification.runner_test_scope(['docs/task-cost-map.json'])[0], 'readers')
        # A manifest, model or font file added anywhere must run the check in the PR that adds it, not in the
        # next PR that touches scripts/.
        for path in ('ops/x/requirements.txt', 'Design/New/fonts/a.ttf', 'docs/y/package.json', 'ops/m/voice.onnx',
                     'Design/NewPrototype/package.json', 'Tools/z/Package.swift'):
            self.assertEqual(verification.runner_test_scope([path])[0], 'readers', path)
        self.assertEqual(verification.runner_test_scope(['ops/x/notes.txt', 'docs/a.png'])[0], 'none')

    def test_an_app_only_diff_runs_the_accessibility_source_scans(self):
        # The scans read App/ Swift files, so a PR that touches only App/ must run them before the merge (#2041).
        scans = ('test_screen_change_cue', 'test_selected_trait', 'test_screen_title_heading',
                 'test_row_accessibility_actions', 'test_voiceover_label_nits', 'test_increase_contrast_wiring',
                 'test_reduce_motion', 'test_tap_target_styles')
        scope, _ = verification.runner_test_scope(['App/SpokenMarginsApp/Sources/SpokenMarginsApp/Gate1RootView.swift'])
        self.assertEqual(scope, 'readers')
        for name in scans:
            with self.subTest(name=name):
                self.assertIn(name, verification.RUNNER_TEST_READERS)

    def test_no_diff_information_runs_every_step(self):
        for changed in (None, []):
            with self.subTest(changed=changed):
                calls, manifest, _, _ = self.host_step_calls({}, changed)
                self.assertEqual([name for name, _ in calls][0], 'runner-tests')
                self.assertTrue(self.ops_ran)
                self.assertFalse(self.skipped_steps(manifest))

    def test_the_readers_run_names_modules_that_exist_and_would_catch_an_app_change(self):
        for name in verification.RUNNER_TEST_READERS:
            module, _, cls = name.partition('.')
            source = SCRIPTS / 'tests' / f'{module}.py'
            self.assertTrue(source.exists(), name)
            self.assertTrue(not cls or f'class {cls}(' in source.read_text(), name)
        calls = []
        with tempfile.TemporaryDirectory() as temporary:
            run = verification.Run(Path(temporary) / 'run', 'fast', ['App/X.swift'])
            with patch.object(run, 'command', side_effect=lambda name, args, **kw: calls.append((name, args))), \
                    patch.object(run, 'ops_steps'), patch.object(verification, 'swift_tests', return_value=set()), \
                    patch.object(verification.host_audio, 'audio_output', return_value={'usable': True, 'why': 'test'}), \
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
                    patch.object(verification.host_audio, 'audio_output', return_value={'usable': True, 'why': 'test'}), \
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

    def test_package_test_steps_may_run_past_their_budget_while_printing_and_not_forever(self):
        # #1767: the tests' 600 s budget killed three PRs' runs on a busy Mac with hundreds of tests missing and none
        # failing; the suite was slow, not hung. Both test steps carry a ceiling and a stall time.
        calls = []
        with tempfile.TemporaryDirectory() as temporary, patch.dict(verification.os.environ, {}, clear=False):
            verification.os.environ.pop('CODEX_SANDBOX', None)
            run = verification.Run(Path(temporary) / 'run', 'fast')
            with patch.object(run, 'command', side_effect=lambda name, args, **kw: calls.append((name, kw))), \
                    patch.object(run, 'ops_steps'), \
                    patch.object(verification.host_audio, 'audio_output', return_value={'usable': True, 'why': 'test'}), \
                    patch.object(verification, 'swift_tests', return_value={'SessionKitCoreTests/A/testA'}), \
                    patch.object(verification, 'input_identity', return_value=run.manifest['input_sha256']):
                run.package_steps({'SessionKitCoreTests/A/testA', 'SessionKitTests/B/testB'})
        steps = dict(calls)
        self.assertEqual(steps['package']['timeout'], 600)
        self.assertGreater(steps['package']['ceiling'], steps['package']['timeout'])
        self.assertLess(steps['package']['stall_seconds'], steps['package']['ceiling'] - steps['package']['timeout'])
        self.assertLess(steps['package']['ceiling'], 2400)  # the lane's FAST_TIMEOUT still bounds the plan
        # The parallel core run loses all its results when killed (they are written at the end), so it too goes on
        # while its progress lines stream; a hang in it is still cut short and rerun serially.
        self.assertEqual(steps['package-core']['timeout'], verification.PARALLEL_CORE_TIMEOUT)
        self.assertEqual(steps['package-core']['ceiling'], verification.PARALLEL_CORE_CEILING)
        self.assertLess(steps['package-core']['stall_seconds'], steps['package']['stall_seconds'])

    def test_the_serial_core_fallback_has_the_same_ceiling(self):
        calls = []

        def command(name, args, **kw):
            calls.append((name, kw))
            run.manifest['steps'].append({'name': name})
            if name == 'package-core':
                raise RuntimeError('parallel run failed')

        with tempfile.TemporaryDirectory() as temporary:
            run = verification.Run(Path(temporary) / 'run', 'fast')
            with patch.object(run, 'command', side_effect=command):
                run.package_core({'SessionKitCoreTests/A/testA'})
        serial = dict(calls)['package-core-serial']
        self.assertEqual(serial['timeout'], verification.PACKAGE_TEST_TIMEOUT)
        self.assertEqual(serial['ceiling'], verification.PACKAGE_TEST_CEILING)
        self.assertEqual(serial['stall_seconds'], verification.PACKAGE_STALL_SECONDS)

    def test_a_fast_plan_cuts_a_steps_ceiling_to_what_is_left_of_the_lanes_clock(self):
        # The lane's 2400 s FAST_TIMEOUT starts before verify-tests.py, so a long slot wait leaves less of it.
        script = 'import time\nwhile True:\n    print("Test Case passed", flush=True)\n    time.sleep(0.1)\n'
        with tempfile.TemporaryDirectory() as temporary:
            run = verification.Run(Path(temporary) / 'run', 'fast')
            run.started -= verification.FAST_PLAN_SECONDS - 3  # about 3 s of the plan left
            started = time.monotonic()
            with self.assertRaises(RuntimeError):
                run.command('package', [sys.executable, '-c', script], timeout=1, ceiling=600, stall_seconds=60)
            self.assertLess(time.monotonic() - started, 10)
            step = run.manifest['steps'][-1]
            self.assertIn('ceiling', step['errors'][1])
            self.assertLessEqual(step['ceiling_seconds'], 3)

    def test_a_step_still_printing_when_its_budget_ends_goes_on_to_the_ceiling(self):
        script = 'import time\nfor i in range(14):\n    print("Test Case passed", flush=True)\n    time.sleep(0.25)\n'
        with tempfile.TemporaryDirectory() as temporary:
            run = verification.Run(Path(temporary) / 'run', 'test')
            run.command('slow-tests', [sys.executable, '-c', script], timeout=2, ceiling=10, stall_seconds=3)
            step = run.manifest['steps'][-1]
            self.assertEqual(step['exit_code'], 0)
            self.assertTrue(step['ran_past_its_limit'])
            self.assertGreater(step['seconds'], 1)

    def test_a_step_with_no_ceiling_is_still_stopped_at_its_budget_however_much_it_prints(self):
        script = 'import time\nwhile True:\n    print("Test Case passed", flush=True)\n    time.sleep(0.1)\n'
        with tempfile.TemporaryDirectory() as temporary:
            run = verification.Run(Path(temporary) / 'run', 'test')
            started = time.monotonic()
            with self.assertRaises(RuntimeError):
                run.command('plain', [sys.executable, '-c', script], timeout=1)
            self.assertLess(time.monotonic() - started, 6)
            self.assertEqual(run.manifest['steps'][-1]['exit_code'], 124)

    def test_a_step_that_goes_quiet_after_its_budget_is_stopped_as_a_hang(self):
        script = 'import time\nfor i in range(8):\n    print("Test Case passed", flush=True)\n    time.sleep(0.25)\ntime.sleep(60)\n'
        with tempfile.TemporaryDirectory() as temporary:
            run = verification.Run(Path(temporary) / 'run', 'test')
            started = time.monotonic()
            with self.assertRaises(RuntimeError) as raised:
                run.command('hung-tests', [sys.executable, '-c', script], timeout=1, ceiling=40, stall_seconds=2)
            self.assertLess(time.monotonic() - started, 15)
            step = run.manifest['steps'][-1]
            self.assertEqual(step['exit_code'], 124)
            self.assertTrue(step['interrupted'])
            self.assertIn('printed nothing for', step['errors'][1])
            self.assertTrue(step['errors'][0].startswith('Process exit 124'))
            self.assertIn('Process exit 124', str(raised.exception))

    def test_a_step_that_never_stops_printing_is_stopped_at_the_ceiling(self):
        script = 'import time\nwhile True:\n    print("Test Case passed", flush=True)\n    time.sleep(0.1)\n'
        with tempfile.TemporaryDirectory() as temporary:
            run = verification.Run(Path(temporary) / 'run', 'test')
            started = time.monotonic()
            with self.assertRaises(RuntimeError):
                run.command('runaway', [sys.executable, '-c', script], timeout=1, ceiling=3, stall_seconds=2)
            self.assertLess(time.monotonic() - started, 10)
            step = run.manifest['steps'][-1]
            self.assertEqual(step['exit_code'], 124)
            self.assertIn('ceiling', step['errors'][1])

    def test_the_timeout_report_says_how_far_the_tests_got_and_that_the_slot_wait_is_not_counted(self):
        # #1767: the lane report carries the step's errors, so the next timeout explains itself.
        script = ('import time\nfor i in range(3):\n    print("Test Case \'-[X.Y t%d]\' passed (0.1 seconds)." % i, flush=True)\n'
                  'time.sleep(60)\n')
        with tempfile.TemporaryDirectory() as temporary:
            run = verification.Run(Path(temporary) / 'run', 'fast')
            run.manifest['host_test_slot'] = {'slot': 0, 'waited_seconds': 840}
            with self.assertRaises(RuntimeError):
                run.command('package', [sys.executable, '-c', script], timeout=3)
            note = run.manifest['steps'][-1]['errors'][1]
            self.assertIn('3 test results in the log', note)
            self.assertIn('waited 840s for the host-test slot before the steps, not counted', note)
            self.assertIn('ran out of its 3s limit', note)
            self.assertIsNotNone(run.manifest['steps'][-1]['load_average_start'])

    def test_the_unfinished_test_is_the_last_one_started_with_no_result_after_it(self):
        # #1956: the log's last "started" line with no result names the test a hung run is in.
        started = "Test Case '-[SessionKitTests.%s %s]' started.\n"
        passed = "Test Case '-[SessionKitTests.%s %s]' passed (0.010 seconds).\n"
        for log, unfinished in (
                ('', None),
                (passed % ('A', 'testA'), None),
                (started % ('A', 'testA') + passed % ('A', 'testA'), None),
                (started % ('A', 'testA') + passed % ('A', 'testA') + started % ('B', 'testB'), 'SessionKitTests/B/testB'),
                (started % ('B', 'testB') + 'some output the test printed\n', 'SessionKitTests/B/testB'),
                # a result for another test with the same method name does not finish it
                (started % ('B', 'testB') + passed % ('C', 'testB'), 'SessionKitTests/B/testB'),
                (started % ('B', 'testB') + "Test Case '-[SessionKitTests.B testB]' failed (1.0 seconds).\n", None)):
            with self.subTest(log=log):
                self.assertEqual(verification.unfinished_test(log), unfinished)

    # The shape of a `sample` call graph on this Mac (Xcode 26, 2026-10-20), cut to the frames that matter. The audio
    # stack is the one #1956's sample of the hung lane run showed.
    SAMPLE_HEAD = ('Call graph:\n'
                   '    1275 Thread_50374060   DispatchQueue_1: com.apple.main-thread  (serial)\n'
                   '    + 1275 start  (in dyld) + 6992  [0x180fdc4e4]\n'
                   '    +   1275 -[XCTestCase invokeTestMethod:]  (in XCTestCore) + 60  [0x100fb147c]\n'
                   '    +     1275 @objc RealPlayerMarginMomentTests.testAMarginThatIsNotChimedStartsItsVoiceStraightAway()'
                   '  (in SessionKitPackageTests) + 44  [0x100d52240]  /<compiler-generated>:0\n'
                   '    +       1275 RealPlayerMarginMomentTests.testAMarginThatIsNotChimedStartsItsVoiceStraightAway()'
                   '  (in SessionKitPackageTests) + 52  [0x100d521fc]  RealPlayerMarginMomentTests.swift:88\n')
    AUDIO_SAMPLE = SAMPLE_HEAD + (
        '    +         1275 MarginMomentConductor.beginVoice()  (in SessionKitPackageTests) + 300  [0x1]  MarginMomentConductor.swift:209\n'
        '    +           1275 -[AVAudioPlayer play]  (in AVFAudio) + 44  [0x2]\n'
        '    +             1275 AudioDeviceStart  (in CoreAudio) + 120  [0x3]\n'
        '    +               1275 HALB_IOThread::StartAndWaitForState(unsigned int)  (in CoreAudio) + 200  [0x4]\n'
        '    +                 1275 __psynch_cvwait  (in libsystem_kernel.dylib) + 8  [0x5]\n'
        '    1275 Thread_50374063\n'
        '    + 1275 start_wqthread  (in libsystem_pthread.dylib) + 8  [0x6]\n')

    def test_a_hung_xctest_sample_names_the_test_and_the_call_it_waits_in(self):
        found = verification.hang_diagnosis(self.AUDIO_SAMPLE)
        self.assertEqual(found['test'], 'RealPlayerMarginMomentTests.testAMarginThatIsNotChimedStartsItsVoiceStraightAway')
        self.assertEqual(found['waiting_in'], '__psynch_cvwait')  # not the next thread's frames
        self.assertTrue(found['audio_device'])
        self.assertIn('stuck in MarginMomentConductor.beginVoice() → … → __psynch_cvwait', found['diagnosis'])
        self.assertIn('a sound output that never started', found['diagnosis'])
        plain = verification.hang_diagnosis(self.SAMPLE_HEAD + (
            '    +         1275 Conductor.wait()  (in SessionKitPackageTests) + 44  [0x1]\n'
            '    +           1275 semaphore_wait_trap  (in libsystem_kernel.dylib) + 8  [0x2]\n'
            '    +         3 Conductor.other()  (in SessionKitPackageTests) + 4  [0x3]\n'))
        self.assertEqual((plain['waiting_in'], plain['audio_device']), ('semaphore_wait_trap', False))
        self.assertNotIn('test', verification.hang_diagnosis('Call graph:\n    5 Thread_1\n    + 5 start  (in dyld)\n'))

    def hung_host_test_step(self, temporary):
        """A stand-in "xctest" in its own session hangs after its test starts; returns the stopped step and its pid."""
        # #1956: SwiftPM starts xctest in a process group of its own. The step's stop left it running under launchd,
        # and the report named no test. The stand-in is /bin/sleep run under the name xctest (argv[0]), which is what
        # `ps` shows: a symlink to Python would not do, since the framework Python re-executes itself under Python.app.
        tools = Path(temporary) / 'toolchain'
        tools.mkdir()
        pid_file = Path(temporary) / 'xctest.pid'
        script = ('import subprocess, sys, time\n'
                  'print("Test Case \'-[SessionKitTests.RealPlayerMarginMomentTests testHangs]\' started.", flush=True)\n'
                  f'child = subprocess.Popen([{str(tools / "xctest")!r}, "120"], executable="/bin/sleep", '
                  'start_new_session=True)\n'
                  f'open({str(pid_file)!r}, "w").write(str(child.pid))\n'
                  'child.wait()\n')
        run = verification.Run(Path(temporary) / 'run', 'test')
        with self.assertRaises(RuntimeError):
            run.command('package', [sys.executable, '-c', script], timeout=1, ceiling=60, stall_seconds=2,
                        tests=True)
        step = run.manifest['steps'][-1]
        stray = int(pid_file.read_text())
        self.assertIn('SessionKitTests/RealPlayerMarginMomentTests/testHangs started and did not finish',
                      step['errors'][1])
        self.assertEqual([sample['pid'] for sample in step['hang']['samples']], [stray])
        self.assertTrue((run.output / 'package-hang' / f'sample-{stray}.txt').is_file())
        self.assertTrue(step['errors'][2].startswith('stuck: '))
        deadline = time.monotonic() + 5
        while verification.process_alive(stray) and time.monotonic() < deadline:
            time.sleep(0.1)
        self.assertFalse(verification.process_alive(stray))
        return step, stray

    @unittest.skipUnless(shutil.which('sample'), 'macOS `sample` only; the no-sample case runs everywhere')
    def test_a_hung_host_test_step_samples_its_xctest_names_the_test_and_leaves_no_stray(self):
        with tempfile.TemporaryDirectory() as temporary:
            step, stray = self.hung_host_test_step(temporary)
            self.assertIsNotNone(step['hang']['samples'][0]['exit'])

    def test_a_hung_host_test_step_without_sample_still_names_its_xctest_and_leaves_no_stray(self):
        # #1956: the hosted Linux runner has no `sample`. Popen raised FileNotFoundError, the step's hang record lost
        # every sample, and nothing named the stopped xctest. It now writes a note per xctest instead.
        real_which = shutil.which
        with tempfile.TemporaryDirectory() as temporary, patch.object(
                verification.shutil, 'which', lambda name, *a, **k: None if name == 'sample' else real_which(name, *a, **k)):
            step, stray = self.hung_host_test_step(temporary)
        [sample] = step['hang']['samples']
        self.assertIsNone(sample['exit'])
        self.assertIn(f'xctest {stray}: no `sample` tool on this host', sample['diagnosis'])
        self.assertIn('no `sample` tool', step['errors'][2])

    def test_an_audio_device_hang_is_a_lane_fault_only_while_the_output_still_does_not_start(self):
        # #1956: a stuck output stays stuck after the step stops; a hang in the PR's own audio code ends with its xctest.
        def command(name, args, **kw):
            run.manifest['steps'].append({'name': name, 'interrupted': True, 'errors': ['Process exit 124'],
                                          'hang': {'audio_device': True, 'samples': [{}]}})
            if name == 'package':
                raise RuntimeError('Process exit 124')

        for starts, fault in ((False, True), (True, False)):
            with self.subTest(output_starts_after_the_stop=starts), tempfile.TemporaryDirectory() as temporary, \
                    patch.dict(verification.os.environ, {}, clear=False):
                verification.os.environ.pop('CODEX_SANDBOX', None)
                run = verification.Run(Path(temporary) / 'run', 'fast')
                with patch.object(run, 'command', side_effect=command), \
                        patch.object(verification.host_audio, 'audio_output', return_value={'usable': True, 'why': 'test'}), \
                        patch.object(verification.host_audio, 'output_starts',
                                     return_value={'starts': starts, 'why': 'probe'}):
                    with self.assertRaises(RuntimeError) as raised:
                        run.package_steps({'SessionKitTests/B/testB'})
                self.assertEqual('lane fault, not the PR' in str(raised.exception), fault)
                self.assertEqual('stopped starting during package' in run.manifest.get('lane_fault', ''), fault)

    def test_the_sessionkit_script_runs_xctest_unbuffered(self):
        # #1956: buffered, a hung run's log ended 400-odd results before the test that hung.
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / 'scripts').mkdir()
            (root / 'Packages/SessionKit').mkdir(parents=True)
            shutil.copy(SCRIPTS / 'run-sessionkit-tests.sh', root / 'scripts/run-sessionkit-tests.sh')
            lane = root / 'scripts/host-test-lane'
            lane.write_text('#!/bin/sh\nprintf "%s" "$NSUnbufferedIO"\n')
            lane.chmod(0o755)
            environment = {key: value for key, value in os.environ.items() if key != 'NSUnbufferedIO'}
            done = subprocess.run(['bash', str(root / 'scripts/run-sessionkit-tests.sh'), '--rest'], env=environment,
                                  capture_output=True, text=True, timeout=30)
        self.assertEqual(done.stdout, 'YES', done.stderr)

    def test_the_wait_for_the_host_test_slot_is_outside_every_steps_clock(self):
        # #1767 suspected that a step's limit also covered its wait for a host-test slot. fast() takes the slot first
        # and hands it to the step's children (SM_LANE_HOST_SLOT), so a slow wait leaves the step's whole budget.
        @contextlib.contextmanager
        def slow_slot(label, out=None, max_wait=None):
            time.sleep(2.5)
            verification.os.environ['SM_LANE_HOST_SLOT'] = label
            try:
                yield {'slot': 0, 'waited_seconds': 2.5}
            finally:
                verification.os.environ.pop('SM_LANE_HOST_SLOT', None)

        seen = {}
        with tempfile.TemporaryDirectory() as temporary:
            run = verification.Run(Path(temporary) / 'run', 'fast')

            def steps():
                run.command('package', [sys.executable, '-c', 'import os, time; time.sleep(0.5); '
                                        'print(os.environ.get("SM_LANE_HOST_SLOT", "none"))'], timeout=2)
                seen['child'] = (run.output / 'package.log').read_text().strip()

            # The hot-file ratchet is its own step with its own tests; here it would run on this checkout (#2180 audit).
            with patch.object(verification, 'host_test_slot', slow_slot), patch.object(run, 'host_steps', steps), \
                    patch.object(run, 'hot_file_ratchet'):
                run.fast()
            step = run.manifest['steps'][-1]
        self.assertEqual(step['exit_code'], 0)
        self.assertLess(step['seconds'], 2)  # the 2.5 s wait is not in it
        self.assertEqual(run.manifest['host_test_slot']['waited_seconds'], 2.5)
        self.assertTrue(seen['child'].startswith('verify-tests fast'))

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
                    patch.object(verification.host_audio, 'audio_output', return_value={'usable': True, 'why': 'test'}), \
                    patch.object(verification, 'input_identity', return_value=run.manifest['input_sha256']):
                run.host_steps()
        timeout = dict(calls)['runner-tests'].get('timeout', default)
        self.assertGreaterEqual(timeout, 2 * measured)  # the suite grows and runs beside a simulator job
        self.assertGreater(timeout, default)

    def test_runner_tests_still_printing_at_their_budget_go_on_to_a_ceiling(self):
        # #2488: at load 138-150 the suite was killed at 600 s with its log still a stream of passing dots (#2409).
        for portable in (False, True):
            calls = []
            with tempfile.TemporaryDirectory() as temporary, patch.dict(verification.os.environ, {}, clear=False):
                verification.os.environ.pop('CODEX_SANDBOX', None)
                run = verification.Run(Path(temporary) / 'run', 'fast')
                with patch.object(run, 'command', side_effect=lambda name, args, **kw: calls.append((name, kw))), \
                        patch.object(run, 'ops_steps'), patch.object(run, 'skip'), \
                        patch.object(verification, 'swift_tests', return_value=set()), \
                        patch.object(verification.host_audio, 'audio_output', return_value={'usable': True, 'why': 'test'}), \
                        patch.object(verification, 'input_identity', return_value=run.manifest['input_sha256']):
                    run.host_steps(portable=portable)
            step = dict(calls)['runner-tests']
            self.assertEqual(step['timeout'], verification.RUNNER_TESTS_TIMEOUT)
            self.assertGreater(step['ceiling'], step['timeout'])
            self.assertLess(step['stall_seconds'], step['ceiling'] - step['timeout'])  # a hang still stops early
            self.assertLess(step['ceiling'], 2400)  # the lane's FAST_TIMEOUT still bounds the plan
        # The readers-only and Mac-rest runs of the same step get the same limits.
        for scope in ('readers', 'all'):
            calls = []
            with tempfile.TemporaryDirectory() as temporary, patch.dict(verification.os.environ, {}, clear=False):
                verification.os.environ.pop('CODEX_SANDBOX', None)
                run = verification.Run(Path(temporary) / 'run', 'fast')
                with patch.object(run, 'command', side_effect=lambda name, args, **kw: calls.append((name, kw))), \
                        patch.object(run, 'ops_steps'), patch.object(run, 'skip'), \
                        patch.object(verification, 'runner_test_scope', return_value=(scope, '')), \
                        patch.object(verification, 'swift_tests', return_value=set()), \
                        patch.object(verification.host_audio, 'audio_output', return_value={'usable': True, 'why': 'test'}), \
                        patch.object(verification, 'input_identity', return_value=run.manifest['input_sha256']):
                    run.host_steps()
            self.assertEqual({k: dict(calls)['runner-tests'][k] for k in verification.RUNNER_TESTS_LIMITS},
                             verification.RUNNER_TESTS_LIMITS, scope)
        calls = []
        with tempfile.TemporaryDirectory() as temporary, patch.dict(verification.os.environ, {}, clear=False):
            verification.os.environ.pop('CODEX_SANDBOX', None)
            run = verification.Run(Path(temporary) / 'run', 'fast-mac-rest')
            with patch.object(run, 'command', side_effect=lambda name, args, **kw: calls.append((name, kw))), \
                    patch.object(run, 'ops_steps'), patch.object(run, 'skip'), patch.object(run, 'package_steps'), \
                    patch.object(run, 'shipped_compat'), \
                    patch.object(verification, 'runner_test_scope', return_value=('all', '')), \
                    patch.object(verification, 'swift_tests', return_value=set()), \
                    patch.object(verification.sessionkit_pass, 'find', return_value=None):
                run.mac_rest()
        self.assertEqual({k: dict(calls)['runner-tests'][k] for k in verification.RUNNER_TESTS_LIMITS},
                         verification.RUNNER_TESTS_LIMITS)

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

    FAILING_UNITTEST = (
        'import unittest\n'
        'class Sample(unittest.TestCase):\n'
        '    def test_equal(self):\n'
        '        self.assertEqual({"a": 1}, {"a": 2})\n'
        '    def test_crash(self):\n'
        '        raise ValueError("nope")\n'
        '    def test_fine(self):\n'
        '        pass\n'
        'unittest.main()\n')

    def test_unittest_failures_are_named_with_their_line_and_message(self):
        # #2457: runner-tests failed in CI with only "FAILED" because log_errors reads xcodebuild's words.
        with tempfile.TemporaryDirectory() as temporary:
            script = Path(temporary) / 'sample.py'
            script.write_text(self.FAILING_UNITTEST)
            log = subprocess.run([sys.executable, str(script)], capture_output=True, text=True).stderr
        failures = verification.unittest_failures(log)
        self.assertEqual([test for test, _, _ in failures], ['test_crash (__main__.Sample.test_crash)',
                                                             'test_equal (__main__.Sample.test_equal)'])
        self.assertTrue(failures[0][1].endswith('sample.py:6'), failures[0])
        self.assertEqual(failures[0][2], 'ValueError: nope')
        self.assertTrue(failures[1][1].endswith('sample.py:4'), failures[1])
        self.assertTrue(failures[1][2].startswith("AssertionError: {'a': 1} != {'a': 2}"), failures[1])
        self.assertEqual(verification.unittest_failures('Ran 3 tests in 0.1s\n\nOK\n'), [])

    def test_the_last_in_repo_line_and_the_final_chained_exception_are_reported(self):
        # Review of #2466: a library frame or the first of two chained exceptions must not stand for the failure.
        here = str(verification.ROOT)
        log = ('======================================================================\n'
               'ERROR: test_x (m.C.test_x)\n'
               '----------------------------------------------------------------------\n'
               'Traceback (most recent call last):\n'
               f'  File "{here}/scripts/tests/m.py", line 5, in test_x\n    data["x"]\nKeyError: \'x\'\n\n'
               'During handling of the above exception, another exception occurred:\n\n'
               'Traceback (most recent call last):\n'
               f'  File "{here}/scripts/tests/m.py", line 7, in test_x\n    json.loads("{{")\n'
               '  File "/usr/lib/python3/json/decoder.py", line 361, in raw_decode\n'
               'ValueError: Expecting property name\n\n'
               '----------------------------------------------------------------------\n'
               'Ran 1 test in 0.1s\n\nFAILED (errors=1)\n')
        self.assertEqual(verification.unittest_failures(log), [
            ('test_x (m.C.test_x)', f'{here}/scripts/tests/m.py:7', 'ValueError: Expecting property name')])

    def test_a_failing_runner_test_step_names_each_failing_test(self):
        with tempfile.TemporaryDirectory() as temporary:
            script = Path(temporary) / 'sample.py'
            script.write_text(self.FAILING_UNITTEST)
            summary = Path(temporary) / 'summary.md'
            run = verification.Run(Path(temporary) / 'run', 'test')
            with patch.dict(os.environ, {'GITHUB_STEP_SUMMARY': str(summary)}):
                with self.assertRaises(RuntimeError) as raised:
                    run.command('runner-tests', [sys.executable, str(script)])
            summary_text = summary.read_text()
        message = str(raised.exception)
        self.assertIn('Failed: test_equal (__main__.Sample.test_equal) at ', message)
        self.assertIn('Failed: test_crash (__main__.Sample.test_crash) at ', message)
        self.assertNotIn('test_fine', message)
        self.assertIn('2 failing test(s)', summary_text)
        self.assertIn('`test_equal (__main__.Sample.test_equal)`', summary_text)

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

    def test_a_plain_iphone_wins_over_a_newer_os_that_offers_only_a_duo(self):
        # The hosted xcode-27 image: iOS 27.1 accepts only iPhone-Duo, 27.0 also has iPhone-17 (#2894).
        duo = 'com.apple.CoreSimulator.SimDeviceType.iPhone-Duo'
        plain = 'com.apple.CoreSimulator.SimDeviceType.iPhone-17'
        def phone(udid, kind):
            return {'udid': udid, 'name': udid, 'state': 'Shutdown', 'isAvailable': True, 'deviceTypeIdentifier': kind}
        devices = {'com.apple.CoreSimulator.SimRuntime.iOS-27-1': [phone('duo-27.1', duo)],
                   'com.apple.CoreSimulator.SimRuntime.iOS-27-0': [phone('duo-27.0', duo), phone('17-27.0', plain)]}
        runner, template = verification.dedicated_simulator(devices, ios=27)
        self.assertIsNone(runner)
        self.assertEqual(template['udid'], '17-27.0')
        devices['com.apple.CoreSimulator.SimRuntime.iOS-27-0'].pop()
        self.assertEqual(verification.select_simulator(devices, ios=27)['udid'], 'duo-27.1',
                         'with no plain iPhone, the newest phone is still used')

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

    def test_the_hang_probe_timing_tests_may_skip_on_a_busy_host_in_both_core_steps(self):
        # #2210: those tests skip when the host runs a 10 ms sleep 40 ms late. A skip the core steps don't allow turns
        # the fast plan red just the same, and a name that drifts from the Swift file allows nothing.
        swift = (Path(__file__).resolve().parents[2] / 'Packages/SessionKit/Tests/SessionKitCoreTests'
                 / 'MainThreadHangProbeTests.swift').read_text()
        skipping = {f'SessionKitCoreTests/MainThreadHangProbeTests/{name}' for name in
                    re.findall(r'func (test\w+)\(\) throws', swift)}
        self.assertEqual(verification.HANG_PROBE_TIMING_TESTS, skipping)
        steps = {}

        def command(name, args, **kw):
            steps[name] = kw.get('allowed_skips', ())
            run.manifest['steps'].append({'name': name})
            if name == 'package-core':
                raise RuntimeError('parallel run failed')

        run = verification.Run(Path(tempfile.mkdtemp()) / 'run', 'fast')
        with patch.object(run, 'command', side_effect=command):
            run.package_core({'SessionKitCoreTests/MainThreadHangProbeTests/testAHundredMillisecondBlockRecordsNothing'})
        self.assertEqual(set(steps), {'package-core', 'package-core-serial'})
        for allowed in steps.values():
            self.assertLessEqual(verification.HANG_PROBE_TIMING_TESTS, set(allowed))

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
        self.assertEqual(records['App/ExportTests/testIsolation']['status'], 'passed')  # owner 2026-10-24 (#2596)
        self.assertEqual(verification.reconcile(set(records), records), [])
        skipped = verification.xcresult_test_records(self.xcresult_payload('Skipped'))
        self.assertEqual(skipped['App/ExportTests/testIsolation']['status'], 'skipped')
        self.assertTrue(verification.reconcile(set(skipped), skipped))
        with patch.object(verification.subprocess, 'check_output',
                          return_value=json.dumps(self.xcresult_payload('Failed'))):
            log = "Test Case '-[App.ExportTests testIsolation]' passed (0.125 seconds)."
            failed, _ = verification.completed_test_records(log, 'tests.xcresult')
        self.assertEqual(failed['App/ExportTests/testIsolation']['status'], 'failed')

    def test_fail_then_pass_on_a_rerun_is_a_pass_and_fail_then_fail_is_not(self):
        # Owner, 2026-10-24 (#2596): "a green run [may] override a red one".
        name = 'App/ExportTests/testIsolation'
        line = "Test Case '-[App.ExportTests testIsolation]' {} (0.1 seconds)."
        log = line.format('failed') + '\n' + line.format('passed')
        records = verification.test_records(log)
        self.assertEqual(records[name]['status'], 'passed')
        self.assertTrue(records[name]['passed_on_retry'])
        self.assertEqual(verification.reconcile({name}, records), [])
        twice = verification.test_records(line.format('failed') + '\n' + line.format('failed'))
        self.assertEqual(twice[name]['status'], 'failed')
        self.assertTrue(verification.reconcile({name}, twice))
        runs = lambda *r: self.xcresult_payload(children=[{'nodeType': 'Test Case Run', 'result': x} for x in r])
        retried = verification.xcresult_test_records(runs('Failed', 'Passed'))[name]
        self.assertEqual((retried['status'], retried.get('passed_on_retry')), ('passed', True))
        self.assertEqual(verification.xcresult_test_records(runs('Failed', 'Failed'))[name]['status'], 'failed')

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

    def test_a_failure_followed_by_a_pass_is_a_pass_named_as_retried(self):
        log = "\n".join(f"Test Case '-[App.ExportTests testIsolation]' {status} (0.125 seconds)."
                        for status in ('failed', 'passed', 'passed'))
        records = verification.test_records(log)
        result = records['App/ExportTests/testIsolation']
        self.assertEqual(result['status'], 'passed')  # owner, 2026-10-24 (#2596)
        self.assertTrue(result['passed_on_retry'])
        self.assertEqual(len(result['attempts']), 3)
        self.assertEqual(verification.reconcile(set(records), records), [])

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
            # #2176: every launch first waits, bounded, for normal memory pressure.
            self.assertIs(startup['hold'], verification.hold_for_launch)
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
        # recorded and the same command runs again. Owner's call 2026-10-11: when that retry passes every
        # requested test, the step passes, with the stall kept on record for the lane runner to log on #705.
        with tempfile.TemporaryDirectory() as temporary:
            run = verification.Run(Path(temporary) / 'run', 'adapters')
            calls, startup = self.watch()
            run.command('xcode-tests', [sys.executable, '-c', self.STALLS_THEN_RUNS, str(Path(temporary) / 'seen')],
                        timeout=60, expected={'SpokenMarginsAppTests/SpeechTests/testBundled'}, tests=True,
                        startup=startup)
            step = run.manifest['steps'][-1]
            self.assertEqual(step['exit_code'], 0)
            self.assertEqual(step['counts']['passed'], 1)  # the retry's real result
            self.assertEqual(step['startup_attempts'], 2)
            self.assertTrue(step['startup_recovered'])
            self.assertEqual([(s['attempt'], s['last_log_line'], s['processes']) for s in step['startup_stalls']],
                             [(1, 'Writing result bundle at path:', 2)])
            self.assertEqual((calls['diagnose'], calls['reset']), (['xcode-tests-stall-1'], [1]))
            self.assertLess(step['seconds'], 30)  # not the 60 s the stalled launch would have slept
            self.assertEqual(step['errors'], [])

    def test_each_launch_records_the_host_conditions_at_its_start_its_tests_and_its_stall(self):
        # #2176: stalls went from 0 of 15 T3 runs on 10-17 to 12 of 32 on 10-19, and only the load average was on
        # record. Each attempt now notes the host's conditions as it starts and as its tests start, and each stall
        # as it is seen, so scripts/lane_stall_report.py can count stalls against them.
        with tempfile.TemporaryDirectory() as temporary:
            run = verification.Run(Path(temporary) / 'run', 'adapters')
            calls, startup = self.watch()
            readings = iter(range(100))
            startup['conditions'] = lambda: {'reading': next(readings)}
            # A real run's tests last seconds after their first line; the watch polls every 0.25 s.
            script = self.STALLS_THEN_RUNS.replace(
                'print("Test Case', 'time.sleep(1)\nprint("Test Case', 1)
            run.command('xcode-tests', [sys.executable, '-c', script, str(Path(temporary) / 'seen')],
                        timeout=60, expected={'SpokenMarginsAppTests/SpeechTests/testBundled'}, tests=True,
                        startup=startup)
            step = run.manifest['steps'][-1]
            self.assertEqual([(n['attempt'], n['at'], n['reading']) for n in step['launch_conditions']],
                             [(1, 'start', 0), (2, 'start', 2), (2, 'tests_started', 3)])
            self.assertEqual(step['startup_stalls'][0]['conditions'], {'reading': 1})
            self.assertLess(step['launch_conditions'][-1]['seconds'], 30)

    def test_hold_for_launch_waits_a_bounded_time_for_normal_pressure_and_reports_it(self):
        # #2176: launches that began under memory pressure "warn" stalled 10 times in 12 on 2026-10-20.
        asked = []
        held = verification.hold_for_launch(wait=lambda limit: asked.append(limit) or ('warn', 90.04))
        self.assertEqual(asked, [verification.LAUNCH_PRESSURE_WAIT_SECONDS])
        self.assertEqual(held, {'memory_pressure': 'warn', 'waited_seconds': 90.0})
        self.assertEqual(verification.hold_for_launch(wait=lambda limit: ('normal', 0.0)),
                         {'memory_pressure': 'normal', 'waited_seconds': 0.0})
        # The real wait never runs past its limit and never fails, whatever the Mac reports.
        ticks = iter(range(0, 1000, 10))
        level, waited = verification.lane_sim.wait_for_normal_pressure(
            30, poll=10, level=lambda: 2, clock=lambda: next(ticks), sleep=lambda seconds: None)
        self.assertEqual(level, 'warn')
        self.assertTrue(30 <= waited <= 40, waited)

    def test_every_launch_is_held_for_pressure_first_and_the_hold_is_recorded(self):
        # The first launch and the retry each wait before they start, so the conditions noted at each start are
        # the ones the launch really began under; the wait is not charged to the step's time.
        with tempfile.TemporaryDirectory() as temporary:
            run = verification.Run(Path(temporary) / 'run', 'adapters')
            calls, startup = self.watch()
            order = []
            startup['hold'] = lambda: order.append('hold') or {'memory_pressure': 'normal', 'waited_seconds': 0.0}
            startup['conditions'] = lambda: order.append('conditions') or {}
            run.command('xcode-tests', [sys.executable, '-c', self.STALLS_THEN_RUNS, str(Path(temporary) / 'seen')],
                        timeout=60, expected={'SpokenMarginsAppTests/SpeechTests/testBundled'}, tests=True,
                        startup=startup)
            step = run.manifest['steps'][-1]
            self.assertEqual([h['attempt'] for h in step['launch_holds']], [1, 2])
            self.assertEqual(order[:2], ['hold', 'conditions'])
            self.assertEqual(order.count('hold'), 2)
            self.assertEqual(step['exit_code'], 0)

    def test_recovered_stall_still_fails_when_a_requested_test_did_not_pass(self):
        # The PASS is for a retry that passes every requested test; a missing test is still an error.
        with tempfile.TemporaryDirectory() as temporary:
            run = verification.Run(Path(temporary) / 'run', 'adapters')
            calls, startup = self.watch()
            with self.assertRaisesRegex(RuntimeError, r'SpeechTests/testOther'):
                run.command('xcode-tests', [sys.executable, '-c', self.STALLS_THEN_RUNS, str(Path(temporary) / 'seen')],
                            timeout=60, tests=True, startup=startup,
                            expected={'SpokenMarginsAppTests/SpeechTests/testBundled',
                                      'SpokenMarginsAppTests/SpeechTests/testOther'})

    def test_two_stalls_before_a_pass_stay_an_error(self):
        # Only one stall that the first retry recovers is covered by the 2026-10-11 call.
        script = (
            'import os, sys, time\n'
            'marker = sys.argv[1]\n'
            'count = len(os.listdir(marker))\n'
            'if count < 2:\n'
            '    open(os.path.join(marker, str(count)), "w").close()\n'
            '    print("Writing result bundle at path:", flush=True)\n'
            '    time.sleep(60)\n'
            'print("Test Suite \'Selected tests\' started at now.", flush=True)\n'
            'print("Test Case \'-[SpokenMarginsAppTests.SpeechTests testBundled]\' passed (0.1 seconds).", flush=True)\n')
        with tempfile.TemporaryDirectory() as temporary:
            marker = Path(temporary) / 'seen'
            marker.mkdir()
            run = verification.Run(Path(temporary) / 'run', 'adapters')
            calls, startup = self.watch(retries=2)
            with self.assertRaisesRegex(RuntimeError, r'Recovered after 2 startup stall\(s\) of 1s.*not a PASS'):
                run.command('xcode-tests', [sys.executable, '-c', script, str(marker)], timeout=60,
                            expected={'SpokenMarginsAppTests/SpeechTests/testBundled'}, tests=True, startup=startup)
            step = run.manifest['steps'][-1]
            self.assertNotIn('startup_recovered', step)
            self.assertEqual([s['attempt'] for s in step['startup_stalls']], [1, 2])

    def test_hung_relaunch_hook_does_not_use_up_the_retry(self):
        # #1807: on a simulator wedged at launch, `simctl terminate` hangs too; its TimeoutExpired came out
        # of the watch loop's try as "the step ran out of budget", so the one allowed retry never started
        # (seven T3 runs stopped at 150 s = 90 s watch + 60 s terminate, startup_attempts 1, interrupted).
        with tempfile.TemporaryDirectory() as temporary:
            run = verification.Run(Path(temporary) / 'run', 'adapters')
            calls, startup = self.watch()

            def hung_terminate(attempt):
                calls['reset'].append(attempt)
                raise subprocess.TimeoutExpired(['xcrun', 'simctl', 'terminate'], 60)

            startup['reset'] = hung_terminate
            run.command('xcode-tests', [sys.executable, '-c', self.STALLS_THEN_RUNS, str(Path(temporary) / 'seen')],
                        timeout=60, expected={'SpokenMarginsAppTests/SpeechTests/testBundled'}, tests=True,
                        startup=startup)
            step = run.manifest['steps'][-1]
            self.assertEqual((step['exit_code'], step['startup_attempts']), (0, 2))
            self.assertFalse(step.get('interrupted'))
            self.assertTrue(step['startup_recovered'])
            self.assertEqual(calls['reset'], [1])
            # What the second attempt followed is on record for the ledger.
            self.assertIn('TimeoutExpired', step['startup_stalls'][0]['relaunch']['error'])

    @patch.dict(os.environ, {'RUNNER_ENVIRONMENT': 'self-hosted'})  # a hosted runner scales the budget (#2602)
    def test_hung_terminate_is_noted_and_the_stalled_result_bundle_is_still_moved_aside(self):
        # The same hang, through the real relaunch hook with a fake `xcrun` that never returns: the retry
        # needs the result-bundle path free, so the rename must not be skipped with the terminate.
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / 'repo'
            self.app_test_root(root)
            (root / '.build/verification/SpokenMarginsAppBehavior').mkdir(parents=True)
            run = verification.Run(Path(temporary) / 'run', 'adapters')
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
                run.xcode('adapters', None, rebuild=True, only=['SpeechTests'])
            app = root / '.build/verification/SpokenMarginsAppBehavior/Build/Products/Debug-iphonesimulator/SpokenMarginsApp.app'
            app.mkdir(parents=True)
            (app / 'Info.plist').write_bytes(verification.plistlib.dumps({'CFBundleIdentifier': 'com.example.app'}))
            (run.output / 'tests.xcresult').mkdir()
            tools = Path(temporary) / 'bin'
            tools.mkdir()
            (tools / 'xcrun').write_text('#!/bin/sh\nexec sleep 30\n')
            (tools / 'xcrun').chmod(0o755)
            with patch.object(verification, 'ROOT', root), patch.object(verification, 'TERMINATE_TIMEOUT_SECONDS', 1), \
                    patch.dict(os.environ, {'PATH': f'{tools}{os.pathsep}{os.environ["PATH"]}'}):
                started = time.monotonic()
                note = commands['xcode-tests']['reset'](1)
            self.assertLess(time.monotonic() - started, 15)
            self.assertEqual(note, {'terminate': 'timed out after 1s'})
            self.assertFalse((run.output / 'tests.xcresult').exists())
            self.assertTrue((run.output / 'tests-stalled-1.xcresult').exists())

    def test_run_that_stalls_on_every_launch_reports_why_within_its_budget(self):
        with tempfile.TemporaryDirectory() as temporary:
            run = verification.Run(Path(temporary) / 'run', 'adapters')
            calls, startup = self.watch()
            startup['diagnose'] = lambda folder: {'diagnosis': verification.NO_HOST_APP}
            script = 'import time; print("Writing result bundle at path:", flush=True); time.sleep(60)'
            # #1161: the step's error names what the host app was doing, not only that no test output came.
            with self.assertRaisesRegex(RuntimeError, r'printed no test output in 2 launch\(es\) of 1s.*'
                                                      r'no host app process: the launch into the simulator'):
                run.command('xcode-tests', [sys.executable, '-c', script], timeout=60, tests=True, startup=startup)
            step = run.manifest['steps'][-1]
            self.assertEqual(step['exit_code'], 124)
            self.assertFalse(step['interrupted'])  # the lane's report says "ran out of budget" for interrupted steps
            self.assertEqual([s['attempt'] for s in step['startup_stalls']], [1, 2])
            self.assertEqual([s['diagnosis'] for s in step['startup_stalls']], [verification.NO_HOST_APP] * 2)
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
            # sample wrote no file here, so the stall says so rather than guessing.
            self.assertEqual(found, {'processes': 1, 'samples': [{'pid': 101, 'exit': 0}],
                                     'diagnosis': 'host app sample unreadable (no main thread in its call graph)'})
            self.assertEqual(sampled, [['sample', '101']])
            self.assertIn(device, (folder / 'processes.txt').read_text())
            with patch.object(verification.subprocess, 'run', side_effect=OSError('no ps')):
                self.assertIn('error', verification.stall_evidence(device, folder))

    # Shaped like the `sample` output in the #1161 stall folders: the main thread first, other threads after it.
    def stall_sample(self, main_frames, images, stray=''):
        frames = ''.join(f'    + {" " * i}2499 {frame}  (in X) + 4  [0x1]\n' for i, frame in enumerate(main_frames))
        frames += f'    + 1 {stray}  (in X) + 4  [0x1]\n' if stray else ''
        return ('Analysis of sampling SpokenMarginsApp (pid 101) every 1 millisecond\n----\n\nCall graph:\n'
                f'    2500 Thread_1   DispatchQueue_1: com.apple.main-thread  (serial)\n{frames}'
                '    2500 Thread_2: com.apple.AXSpeech\n    + 2500 semaphore_wait_trap  (in libsystem_kernel.dylib)\n'
                '\nTotal number in stack (recursive counted multiple times):\n'
                f'\nBinary Images:\n{images}')

    RUN_LOOP = ['start', 'UIApplicationMain', 'GSEventRunModal', '__CFRunLoopRun', '__CFRunLoopServiceMachPort',
                'mach_msg2_trap']
    APP_IMAGES = '       0x102ea8000 -        0x102eabfff +SpokenMarginsApp (0.1 - 32) <A> /x/SpokenMarginsApp\n'
    INJECT = ('       0x10f000000 -        0x10f00ffff +libXCTestBundleInject.dylib (0) <B> '
              '/x/SpokenMarginsApp.app/Frameworks/libXCTestBundleInject.dylib\n')

    def test_stall_diagnosis_names_each_shape_seen_in_the_1161_samples(self):
        sample = self.stall_sample
        cases = [
            # 19 of 32: started, idle, and xcodebuild's DYLD_INSERT_LIBRARIES never took effect.
            (sample(self.RUN_LOOP, self.APP_IMAGES), 'S', 'host app idle in its run loop; XCTest never injected'),
            # Another thread waiting on a semaphore is normal; only the main thread decides "idle".
            (sample(self.RUN_LOOP, self.APP_IMAGES + self.INJECT), 'Ss', 'host app idle in its run loop; XCTest loaded'),
            # A wait seen in 1 of 2500 main-thread samples is a one-off branch, not a blocked app.
            (sample(self.RUN_LOOP, self.APP_IMAGES, stray='__ulock_wait'), 'S',
             'host app idle in its run loop; XCTest never injected'),
            (sample(['start', 'Gate1AppModel.init', 'dispatch_sync', '_dispatch_sync_f_slow', '__ulock_wait'],
                    self.APP_IMAGES + self.INJECT), 'S', 'host app busy or blocked on its main thread; XCTest loaded'),
            # 1 of 32: launched about 70 s late, so the sample caught it in dyld, stopped for the debugger (Ts).
            (sample(['_dyld_start'], ''), 'Ts', 'host app launched late and still starting in dyld'),
            (sample(self.RUN_LOOP, self.APP_IMAGES), 'T', 'host app launched late and still starting in dyld'),
            # A later one had already resumed when sampled: running, but most samples still in dyld's set-up.
            (sample(['start', 'dyld4::prepareSim', 'dyld4::APIs::runAllInitializersForMain'], ''), 'S',
             'host app launched late and still starting in dyld'),
            (sample(self.RUN_LOOP, ''), 'S', 'host app idle in its run loop; XCTest load unknown'),
            ('', 'S', 'host app sample unreadable'),
            ('sample: process 101 does not exist\n', '', 'host app sample unreadable'),
        ]
        for text, state, expected in cases:
            with self.subTest(expected=expected, state=state):
                self.assertTrue(verification.stall_diagnosis(text, state).startswith(expected),
                                verification.stall_diagnosis(text, state))

    def test_stall_evidence_with_no_host_app_says_the_launch_never_completed(self):
        # 12 of 32 #1161 stalls: the session log ends at "Launching app" and no app process exists.
        with tempfile.TemporaryDirectory() as temporary:
            device = 'A1B2C3D4-0000-0000-0000-SYNTHETIC00'
            listing = f'  90 05:10 S /x/Devices/{device}/data/usr/libexec/launchd_sim\n'
            with patch.object(verification.subprocess, 'run',
                              return_value=subprocess.CompletedProcess([], 0, stdout=listing)):
                found = verification.stall_evidence(device, Path(temporary) / 'stall')
            self.assertEqual(found, {'processes': 1, 'diagnosis': verification.NO_HOST_APP})

    def test_stall_evidence_diagnoses_the_sample_it_took(self):
        with tempfile.TemporaryDirectory() as temporary:
            folder = Path(temporary) / 'stall'
            device = 'A1B2C3D4-0000-0000-0000-SYNTHETIC00'
            listing = f'  101 01:30 Ss /x/Devices/{device}/data/Y/SpokenMarginsApp.app/SpokenMarginsApp\n'
            text = self.stall_sample(self.RUN_LOOP, self.APP_IMAGES)

            def run_(args, **kwargs):
                if args[0] == 'sample':
                    Path(args[args.index('-file') + 1]).write_text(text)
                return subprocess.CompletedProcess(args, 0, stdout=listing)

            with patch.object(verification.subprocess, 'run', side_effect=run_):
                found = verification.stall_evidence(device, folder)
            self.assertEqual(found['diagnosis'], 'host app idle in its run loop; XCTest never injected')

    # Lines as xcodebuild writes them in the attempt's Staging session log (pr1647-r38684087699, 2026-10-15).
    SESSION_LOG = (
        '00:03:35.197 xcodebuild[49404:1] X: Installing app at path: /x/SpokenMarginsApp.app\n'
        '00:03:36.651 xcodebuild[49404:1] X: Installed app at path: /x/SpokenMarginsApp.app\n'
        '00:03:36.654 xcodebuild[49404:1] X: Launching app with identifier: com.spokenmargins.native and options: {\n'
        '    "wait_for_debugger" = 1;\n}\n'
        '00:03:37.143 xcodebuild[49404:1] X: Launched app with identifier: com.spokenmargins.native (pid = 101)\n'
        '00:03:37.615 xcodebuild[49404:1] Test process runnable PID is 101.\n'
        '00:03:37.615 xcodebuild[49404:1] XCTHTestOperationStateMachine: Transitioning from state Initial to AcquiredPID\n')

    def stalled_bundle(self, root, session_log):
        bundle = root / 'tests.xcresult'
        run = bundle / 'Staging/1_Test/Diagnostics/SpokenMarginsAppTests-A-Configuration-Default-Iteration-1/SpokenMarginsAppTests-B'
        run.mkdir(parents=True)
        if session_log is not None:
            (run / 'Session-SpokenMarginsAppTests-2026-10-15_000334-W3zi1U.log').write_text(session_log)
        return bundle

    def test_stall_evidence_says_whether_it_sampled_xcodebuilds_own_launch(self):
        # #705: the idle, uninjected host app was the very pid xcodebuild launched, so the simulator dropped that
        # launch's settings; a different pid would mean something else launched the app first.
        device = 'A1B2C3D4-0000-0000-0000-SYNTHETIC00'
        text = self.stall_sample(self.RUN_LOOP, self.APP_IMAGES)
        for pid, expected in [('101', "host app idle in its run loop; XCTest never injected; xcodebuild's own launch; "
                                      'session log ends at "Transitioning from state Initial to AcquiredPID"'),
                              ('202', 'host app idle in its run loop; XCTest never injected; not the pid xcodebuild '
                                      'launched (101); session log ends at "Transitioning from state Initial to AcquiredPID"')]:
            with self.subTest(pid=pid), tempfile.TemporaryDirectory() as temporary:
                bundle = self.stalled_bundle(Path(temporary), self.SESSION_LOG)
                listing = f'  {pid} 01:30 Ss /x/Devices/{device}/data/Y/SpokenMarginsApp.app/SpokenMarginsApp\n'

                def run_(args, **kwargs):
                    if args[0] == 'sample':
                        Path(args[args.index('-file') + 1]).write_text(text)
                    return subprocess.CompletedProcess(args, 0, stdout=listing)

                with patch.object(verification.subprocess, 'run', side_effect=run_):
                    found = verification.stall_evidence(device, Path(temporary) / 'stall', result_bundle=bundle)
                self.assertEqual(found['diagnosis'], expected)
                self.assertEqual(found['launched_pid'], 101)

    def test_stall_evidence_with_no_host_app_names_the_launch_step_it_reached(self):
        # 14 of the 40 kept stalled result bundles (2026-10-15) had no host process; their session logs end at
        # "Launching app", "Installing app" or "Installed app", or are empty. Each stall now says which.
        device = 'A1B2C3D4-0000-0000-0000-SYNTHETIC00'
        listing = f'  90 05:10 S /x/Devices/{device}/data/usr/libexec/launchd_sim\n'
        cut = self.SESSION_LOG.index('00:03:37.143')
        for session_log, expected in [
                (self.SESSION_LOG[:cut], {'session_last_step': 'Launching app',
                                          'diagnosis': f'{verification.NO_HOST_APP}; session log ends at "Launching app"'}),
                ('', {'session_last_step': None, 'diagnosis': verification.NO_HOST_APP}),
                (None, {'diagnosis': verification.NO_HOST_APP})]:
            with self.subTest(expected=expected), tempfile.TemporaryDirectory() as temporary:
                bundle = self.stalled_bundle(Path(temporary), session_log)
                with patch.object(verification.subprocess, 'run',
                                  return_value=subprocess.CompletedProcess([], 0, stdout=listing)):
                    found = verification.stall_evidence(device, Path(temporary) / 'stall', result_bundle=bundle)
                self.assertEqual(found, {'processes': 1, **expected})

    def simulator_listings(self, *runners):
        """simctl listings, one per call: an iOS 26 iPhone template plus the Test Runner named in each."""
        runtime = 'com.apple.CoreSimulator.SimRuntime.iOS-26-0'
        phone = 'com.apple.CoreSimulator.SimDeviceType.iPhone-17'
        listings = []
        for runner in runners:
            group = [{'udid': 'template', 'name': 'iPhone 17', 'state': 'Shutdown', 'isAvailable': True,
                      'deviceTypeIdentifier': phone}]
            if runner:
                group.append({'udid': runner, 'name': verification.TEST_RUNNER_NAME, 'state': 'Shutdown',
                              'isAvailable': True, 'deviceTypeIdentifier': phone})
            listings.append(json.dumps({'devices': {runtime: group}}))
        return listings

    def pick_simulator(self, listings, unsafe, device=None):
        with tempfile.TemporaryDirectory() as temporary:
            run = verification.Run(Path(temporary) / 'run', 'app')
            commands = []
            with patch.object(verification, 'capture', side_effect=listings), \
                    patch.object(verification.lane_sim, 'unsafe_devices', return_value=unsafe), \
                    patch.object(verification.subprocess, 'run'), \
                    patch.object(run, 'command', side_effect=lambda name, args, **_: commands.append((name, args))), \
                    contextlib.redirect_stdout(io.StringIO()):
                chosen, created = run.simulator(device)
        return chosen['udid'], created, commands

    def test_an_unsafe_test_runner_is_replaced_and_the_new_one_counts_as_created(self):
        # #1325: the Test Runner was marked unsafe on 10-09, and every integration run on next then
        # stopped after 4 s with "is on the lane's unsafe list", because nothing ever replaced it.
        udid, created, commands = self.pick_simulator(self.simulator_listings('old', None, 'new'),
                                                      {'old': {'reason': 'SpringBoard restarted during boot'}})
        self.assertEqual((udid, created), ('new', True))
        self.assertEqual([name for name, _ in commands], ['simulator-retire', 'simulator-create'])
        self.assertEqual(commands[0][1], ['xcrun', 'simctl', 'delete', 'old'])

    def test_a_safe_test_runner_is_kept(self):
        udid, created, commands = self.pick_simulator(self.simulator_listings('old'), {'other': {'reason': 'x'}})
        self.assertEqual((udid, created, commands), ('old', False, []))

    def test_a_given_device_is_never_replaced(self):
        # --device is someone else's choice; xcode() still refuses it if it is marked unsafe.
        udid, created, commands = self.pick_simulator(self.simulator_listings('old'), {'old': {'reason': 'x'}},
                                                      device='old')
        self.assertEqual((udid, created, commands), ('old', False, []))

    def test_a_device_this_run_created_boots_with_the_first_boot_tolerance(self):
        # A fresh device's first boot may restart SpringBoard once (lane_sim.FIRST_BOOT_TOLERANCE); without
        # first_boot the boot marks it unsafe, which is likely how the Test Runner was lost in #1325.
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / 'repo'
            self.app_test_root(root)
            (root / '.build/verification/SpokenMarginsAppBehavior').mkdir(parents=True)
            run = verification.Run(Path(temporary) / 'run', 'adapters')
            run.manifest['input_sha256'] = 'inputs'
            fresh = {'udid': 'new', 'state': 'Shutdown', 'runtime': 'iOS-26', 'name': 'Other'}
            boots = []
            with patch.object(verification, 'ROOT', root), \
                    patch.object(verification, 'input_identity', return_value='inputs'), \
                    patch.object(verification, 'capture', return_value='stub'), \
                    patch.object(run, 'simulator', return_value=(fresh, True)), \
                    patch.object(verification, 'refuse_unsafe'), \
                    patch.object(verification.lane_sim, 'unsafe_devices', return_value={}), \
                    patch.object(verification.lane_sim, 'boot',
                                 side_effect=lambda udid, label, **kw: boots.append(kw) or 1.0), \
                    patch.object(verification, 'acquire_simulator_slot', return_value=None), \
                    patch.object(verification.subprocess, 'run'), \
                    patch.object(run, 'command', return_value=''):
                run.xcode('adapters', None, rebuild=True, only=['SpeechTests'])
            self.assertEqual([kw.get('first_boot') for kw in boots], [True])

    def stalled_test_runner(self, device=None):
        """run.xcode() where the Test Runner's boot stalls once (#705); returns (boots, commands, manifest, posted)."""
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / 'repo'
            self.app_test_root(root)
            (root / '.build/verification/SpokenMarginsAppBehavior').mkdir(parents=True)
            app = root / '.build/verification/SpokenMarginsAppBehavior/Build/Products/Debug-iphonesimulator/SpokenMarginsApp.app'
            app.mkdir(parents=True)
            (app / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': 'test.app'}))
            run = verification.Run(Path(temporary) / 'run', 'adapters')
            run.manifest['input_sha256'] = 'inputs'
            runners = iter([{'udid': 'old', 'state': 'Shutdown', 'runtime': 'iOS-26', 'name': verification.TEST_RUNNER_NAME},
                            {'udid': 'new', 'state': 'Shutdown', 'runtime': 'iOS-26', 'name': verification.TEST_RUNNER_NAME}])
            boots, commands = [], []

            def boot(udid, label, **kw):
                boots.append(udid)
                if udid == 'old':
                    raise verification.lane_sim.BootError('SpringBoard restarted (pid 1 -> 2) while booting.', stall=True)
                return 30.0

            with patch.object(verification, 'ROOT', root), \
                    patch.object(verification, 'input_identity', return_value='inputs'), \
                    patch.object(verification, 'capture', return_value='stub'), \
                    patch.object(run, 'simulator', side_effect=lambda *a: (next(runners), True)), \
                    patch.object(verification, 'refuse_unsafe'), \
                    patch.object(verification.lane_sim, 'unsafe_devices', return_value={}), \
                    patch.object(verification.lane_sim, 'boot', side_effect=boot), \
                    patch.object(verification.lane_sim, 'post_stall') as posted, \
                    patch.object(verification.lane_sim, 'LATE_REPORT_WAIT', 0), \
                    patch.object(verification.lane_sim, 'late_report', return_value=None), \
                    patch.object(verification, 'acquire_simulator_slot', return_value=None), \
                    patch.object(verification.subprocess, 'run'), \
                    patch.object(run, 'command', side_effect=lambda name, args, **_: commands.append((name, args)) or ''), \
                    contextlib.redirect_stdout(io.StringIO()):
                try:
                    run.xcode('adapters', device, rebuild=True, only=['SpeechTests'])
                except RuntimeError:
                    pass
            return boots, commands, run.manifest, posted

    def test_a_test_runner_boot_stall_gets_one_fresh_test_runner(self):
        # #705: 26 of 45 INCONCLUSIVE integration runs from 10-09 to 10-16 were boot stalls.
        boots, commands, manifest, posted = self.stalled_test_runner()
        self.assertEqual(boots, ['old', 'new'])
        self.assertIn(('simulator-retire', ['xcrun', 'simctl', 'delete', 'old']), commands)
        self.assertEqual(manifest['destination']['udid'], 'new')
        tests = next(args for name, args in commands if name == 'xcode-tests')
        self.assertIn('id=new', tests)
        self.assertNotIn('id=old', tests)
        step = next(s for s in manifest['steps'] if s['name'] == 'simulator-boot')
        self.assertEqual((step['exit_code'], [s['udid'] for s in step['boot_stalls']]), (0, ['old']))
        self.assertIn('recovered', posted.call_args.args[2])

    def test_a_given_device_that_stalls_gets_no_retry(self):
        boots, commands, manifest, posted = self.stalled_test_runner(device='old')
        self.assertEqual(boots, ['old'])
        self.assertFalse(any(name == 'simulator-retire' for name, _ in commands))
        posted.assert_not_called()

    def run_xcode_plan(self, plan, order, fail_tests=False):
        """run.xcode(plan) with every boundary stubbed; `order` collects settle, tests and marker calls in sequence."""
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / 'repo'
            self.app_test_root(root)
            (root / '.build/verification/SpokenMarginsAppBehavior').mkdir(parents=True)
            run = verification.Run(Path(temporary) / 'run', plan)
            run.manifest['input_sha256'] = 'inputs'
            booted = {'udid': 'sim-1', 'state': 'Booted', 'runtime': 'iOS-26', 'name': 'Lane'}

            def command(name, *args, **kwargs):
                order.append(name)
                if name == 'xcode-tests' and fail_tests:
                    raise RuntimeError('tests failed')
                return ''

            with patch.object(verification, 'ROOT', root), \
                    patch.object(verification, 'input_identity', return_value='inputs'), \
                    patch.object(verification, 'capture', return_value='stub'), \
                    patch.object(run, 'simulator', return_value=(booted, False)), \
                    patch.object(verification, 'refuse_unsafe'), \
                    patch.object(verification.lane_sim, 'unsafe_devices', return_value={}), \
                    patch.object(verification, 'acquire_simulator_slot', return_value=None), \
                    patch.object(verification, 'settle_before_tests',
                                 side_effect=lambda udid: order.append(f'settle {udid}') or {'waited_seconds': 3.0}), \
                    patch.object(verification.lane_sim, 'mark_quiet', side_effect=lambda udid: order.append(f'marked {udid}')), \
                    patch.object(verification.subprocess, 'run'), \
                    patch.object(run, 'command', side_effect=command):
                try:
                    run.xcode(plan, None, rebuild=True, only=['SpeechTests'])
                except RuntimeError:
                    pass
            return run.manifest

    def test_app_hosted_plan_settles_the_simulator_before_its_tests_and_marks_their_end(self):
        # #705: the host app stalled when launched soon after boot or after another test run on the simulator.
        for plan in ('app', 'adapters'):
            with self.subTest(plan=plan):
                order = []
                manifest = self.run_xcode_plan(plan, order)
                self.assertEqual([step for step in order if step in ('settle sim-1', 'xcode-tests', 'marked sim-1')],
                                 ['settle sim-1', 'xcode-tests', 'marked sim-1'])
                self.assertEqual(manifest['settle_before_tests'], {'waited_seconds': 3.0})

    def test_a_failed_test_step_still_marks_the_end_so_the_next_plan_waits(self):
        order = []
        self.run_xcode_plan('adapters', order, fail_tests=True)
        self.assertEqual(order[-1], 'marked sim-1')

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
                    'Smoke': [selecting(uis, 'TourUITests/testTour')],
                    'ScreenTour': [selecting(uis, 'TourUITests/testTour')]}
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
        for plan in ('UISeams', 'SpeechCanary', 'Smoke', 'ScreenTour'):
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
                                      ('a spec summary of zero tests', 'ℹ tests 0'),
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
                with self.subTest(name=name, label='a spec summary of three tests (Node 24)'):
                    run.command(name, [sys.executable, '-c', 'print("✔ a test (1ms)\\nℹ tests 3\\nℹ pass 3")'])
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


class WarmLaunchTests(unittest.TestCase):
    """#2806: a UI plan's first launch of the app happens before its first test, not inside it."""
    UDID = 'A1B2C3D4-0000-0000-0000-SYNTHETIC00'
    APP = Path('/derived/SpokenMarginsApp.app')

    def warm(self, failing=(), uninstall_error=None):
        calls, slept = [], []

        def quietly(args, timeout=60):
            calls.append(args[0])
            return False if args[0] in failing else True

        def uninstall(udid, bundle_id):
            calls.append('uninstall')
            if uninstall_error:
                raise uninstall_error

        seen = verification.warm_launch(self.UDID, self.APP, 'com.example.app', sleep=slept.append,
                                        quietly=quietly, uninstall=uninstall)
        return calls, slept, seen

    def test_the_app_is_installed_run_for_a_few_seconds_stopped_and_removed_in_that_order(self):
        calls, slept, seen = self.warm()
        self.assertEqual(calls, ['install', 'launch', 'terminate', 'uninstall'])
        self.assertEqual(slept, [verification.WARM_LAUNCH_SECONDS])
        self.assertEqual(seen['ran_seconds'], verification.WARM_LAUNCH_SECONDS)

    def test_a_launch_that_timed_out_still_removes_the_app_so_the_tests_start_clean(self):
        calls, slept, seen = self.warm(failing=('launch',))
        self.assertEqual(calls, ['install', 'launch', 'terminate', 'uninstall'])
        self.assertEqual(slept, [], 'nothing to wait for when the app did not start')
        self.assertNotIn('ran_seconds', seen)

    def test_an_install_that_timed_out_is_still_removed_in_case_it_finished_late(self):
        calls, slept, _ = self.warm(failing=('install',))
        self.assertEqual((calls, slept), (['install', 'terminate', 'uninstall'], []))

    def test_an_app_that_cannot_be_removed_ends_the_run_rather_than_leave_data_for_the_first_test(self):
        with self.assertRaises(RuntimeError):
            self.warm(uninstall_error=RuntimeError('simulator-clean: simctl uninstall did not finish'))

    def test_it_installs_the_built_app_on_the_given_simulator(self):
        recorded = []
        verification.warm_launch(self.UDID, self.APP, 'com.example.app', sleep=lambda _: None,
                                 quietly=lambda args, timeout=60: recorded.append(args) or True,
                                 uninstall=lambda udid, bundle_id: None)
        self.assertEqual(recorded[0], ['install', self.UDID, str(self.APP)])
        self.assertEqual(recorded[1], ['launch', self.UDID, 'com.example.app'])


class SimulatorSettleTests(unittest.TestCase):
    """#705: don't launch the host app in the window where it stalls at startup."""
    UDID = 'A1B2C3D4-0000-0000-0000-SYNTHETIC00'

    def settle(self, quiet_for):
        slept = []
        with patch.object(verification.lane_sim, 'seconds_quiet', return_value=quiet_for):
            seen = verification.settle_before_tests(self.UDID, sleep=slept.append)
        return seen, slept

    def test_a_simulator_that_was_just_busy_waits_for_the_rest_of_20_seconds(self):
        # The app plan stalled 1-16 s after boot; the adapters plan starts 3-7 s after the app plan on the same device.
        seen, slept = self.settle(5)
        self.assertEqual(slept, [15])
        self.assertEqual(seen, {'seconds_quiet': 5, 'waited_seconds': 15.0})

    def test_a_quiet_simulator_is_launched_at_once(self):
        for quiet_for in (20, 25, 4000):
            with self.subTest(quiet_for=quiet_for):
                seen, slept = self.settle(quiet_for)
                self.assertEqual((slept, seen['waited_seconds']), ([], 0.0))

    def test_a_simulator_nobody_marked_never_holds_the_run(self):
        seen, slept = self.settle(None)
        self.assertEqual((slept, seen), ([], {'seconds_quiet': None, 'waited_seconds': 0.0}))

    def test_a_marker_dated_in_the_future_is_capped(self):
        # Clock set back: quiet for -10000 s would otherwise be a wait of hours.
        _, slept = self.settle(-10_000)
        self.assertEqual(slept, [verification.SETTLE_LIMIT_SECONDS])

    def test_it_reads_the_marker_the_lane_writes(self):
        with tempfile.TemporaryDirectory() as temporary, patch.dict(os.environ, {'SM_LANE_STATE_DIR': temporary}):
            lane_sim = verification.lane_sim
            lane_sim.mark_quiet(self.UDID)
            slept = []
            seen = verification.settle_before_tests(self.UDID, sleep=slept.append)
            self.assertEqual(len(slept), 1)
            self.assertAlmostEqual(slept[0], verification.SETTLE_SECONDS, delta=2)
            self.assertLess(seen['seconds_quiet'], 2)


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

    def test_bare_selectors_take_the_plans_own_target(self):
        tour = inventory.plan_tests(inventory.ROOT, 'ScreenTour')
        self.assertEqual(verification.full_selector('ScreenTourTests', tour), 'SpokenMarginsAppUITests/ScreenTourTests')
        self.assertTrue(any(verification.selected(t, 'SpokenMarginsAppUITests/ScreenTourTests') for t in tour))
        app = inventory.plan_tests(inventory.ROOT, 'AppBehavior')
        self.assertEqual(verification.full_selector('Gate1AppModelWorkflowTests', app),
                         'SpokenMarginsAppTests/Gate1AppModelWorkflowTests')
        release = inventory.plan_tests(inventory.ROOT, 'Release')  # two targets: bare names stay app tests
        self.assertEqual(verification.full_selector('Foo', release), 'SpokenMarginsAppTests/Foo')
        self.assertEqual(verification.full_selector('SpokenMarginsAppUITests/ScreenTourTests', release),
                         'SpokenMarginsAppUITests/ScreenTourTests')

    def test_the_tour_plan_runs_only_the_screen_tour_and_exports_its_screenshots(self):
        self.assertIn('tour', verification.PLANS)
        self.assertIn('tour', verification.SCREENSHOT_PLANS)
        tests = inventory.plan_tests(inventory.ROOT, 'ScreenTour')
        self.assertEqual({t.rsplit('/', 1)[0] for t in tests}, {'SpokenMarginsAppUITests/ScreenTourTests'})

    def test_exported_screenshots_are_named_after_their_attachments(self):
        with tempfile.TemporaryDirectory() as temporary:
            exported, screens = Path(temporary) / 'attachments', Path(temporary) / 'screens'
            exported.mkdir()
            attachments = []
            for index, name in enumerate(['tour-light-01-library', 'tour-dark-01-library', 'tour-dark-01-library']):
                exported_name = f'{index:08X}-0000-0000-0000-000000000000.png'
                (exported / exported_name).write_bytes(name.encode())
                attachments.append({'exportedFileName': exported_name, 'isAssociatedWithFailure': False,
                                    'suggestedHumanReadableName': f'{name}_{index}_1A2B3C4D-0000-0000-0000-00000000000{index}.png'})
            (exported / 'manifest.json').write_text(json.dumps([
                {'testIdentifier': 'ScreenTourTests/testTourInLightAppearance()', 'attachments': attachments[:1]},
                {'testIdentifier': 'ScreenTourTests/testTourInDarkAppearance()', 'attachments': attachments[1:]}]))
            names = verification.name_screenshots(exported, screens)
            self.assertEqual(names, ['tour-dark-01-library-2.png', 'tour-dark-01-library.png', 'tour-light-01-library.png'])
            self.assertEqual((screens / 'tour-light-01-library.png').read_bytes(), b'tour-light-01-library')
            self.assertEqual(sorted(p.name for p in screens.iterdir()), names)


if __name__ == '__main__':
    unittest.main()
