"""The SessionKit steps of --plan fast (#1328): skipping a package that already passed, and the parallel core run."""
import importlib.util
import json
import os
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
import lane_next_rerun  # noqa: E402

spec = importlib.util.spec_from_file_location('verification_for_sessionkit_steps', SCRIPTS / 'verify-tests.py')
verification = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verification)

KEY = 'k' * 64
CORE = {'SessionKitCoreTests/AlphaTests/testOne', 'SessionKitCoreTests/AlphaTests/testTwo'}
REST = {'SessionKitTests/RealPlayerTests/testPlays', 'SessionKitTraceTests/TraceTests/testReplay'}

XUNIT = '''<?xml version="1.0" encoding="UTF-8"?>
<testsuites>
<testsuite name="TestResults" errors="0" tests="3" failures="1" time="0.5">
<testcase classname="SessionKitCoreTests.AlphaTests" name="testOne" time="0.1">
</testcase>
<testcase classname="SessionKitCoreTests.AlphaTests" name="testTwo()" time="0.2">
<failure message="failed"></failure>
</testcase>
<testcase classname="SessionKitCoreTests.BetaTests" name="testThree" time="0.2">
<skipped/>
</testcase>
</testsuite>
</testsuites>
'''


class Host:
    """The host steps of a fast run with every command replaced by a recorder."""

    def __init__(self, test, changed, key=KEY, toolchain='swift 6', environment=None, fail=(), core=CORE, rest=REST):
        # key: the tree's key, or the keys the successive looks at it return (the last one repeats)
        self.test, self.changed, self.toolchain = test, changed, toolchain
        self.keys = list(key) if isinstance(key, (list, tuple)) else [key]
        self.environment, self.fail, self.core, self.rest = environment or {}, set(fail), core, rest
        self.calls = []

    def run(self, state):
        def command(run, name, args, **kw):
            self.calls.append((name, args, kw))
            run.manifest['steps'].append({'name': name, 'command': args})
            if name in self.fail:
                run.manifest['steps'][-1]['errors'] = [f'Failed: {name}']
                raise RuntimeError(f'{name} failed')

        with tempfile.TemporaryDirectory() as temporary, patch.dict(os.environ, self.environment, clear=False):
            if 'CODEX_SANDBOX' not in self.environment:
                os.environ.pop('CODEX_SANDBOX', None)
            run = verification.Run(Path(temporary) / 'run', 'fast', self.changed)
            self.run_object = run
            with patch.object(run, 'command', side_effect=lambda name, args, **kw: command(run, name, args, **kw)), \
                    patch.object(run, 'ops_steps'), \
                    patch.object(verification.host_audio, 'audio_output', return_value={'usable': True, 'why': 't'}), \
                    patch.object(verification, 'state_dir', return_value=Path(state)), \
                    patch.object(verification.sessionkit_pass, 'toolchain', return_value=self.toolchain), \
                    patch.object(verification.sessionkit_pass, 'key', side_effect=lambda root, tc: self.next_key() if tc else None), \
                    patch.object(verification, 'swift_tests',
                                 side_effect=lambda folder: {t.split('/', 1)[1] for t in self.tests_in(folder.name)}), \
                    patch.object(verification, 'input_identity', return_value=run.manifest['input_sha256']):
                try:
                    run.host_steps()
                    self.error = None
                except RuntimeError as error:
                    self.error = error
            self.manifest = json.loads((Path(temporary) / 'run/manifest.json').read_text())
        return self

    def tests_in(self, target):
        return {t for t in self.core | self.rest if t.startswith(target + '/')}

    def next_key(self):
        return self.keys.pop(0) if len(self.keys) > 1 else self.keys[0]

    @property
    def names(self):
        return [name for name, _, _ in self.calls]

    def step(self, name):
        return next((args, kw) for n, args, kw in self.calls if n == name)

    @property
    def skipped(self):
        return {step['name']: step['skipped'] for step in self.manifest['steps']
                if step.get('skipped') and step['name'].startswith('package')}


class SkipTests(unittest.TestCase):
    def passed(self, state, **kw):
        host = Host(self, ['scripts/x.py'], **kw).run(state)
        self.assertIsNone(host.error)
        return host

    def test_a_first_run_builds_tests_and_records_the_pass(self):
        with tempfile.TemporaryDirectory() as state:
            host = Host(self, ['docs/a.md']).run(state)
            self.assertIsNone(host.error)
            self.assertTrue({'package-build', 'package-core', 'package'} <= set(host.names))
            record = verification.sessionkit_pass.find(state, KEY)
            self.assertEqual((record['tests'], record['head']), (len(CORE | REST), host.manifest['head']))

    def test_a_lane_run_on_the_same_inputs_skips_the_build_and_the_tests_and_says_so(self):
        with tempfile.TemporaryDirectory() as state:
            self.passed(state)
            host = Host(self, ['docs/a.md']).run(state)
            self.assertIsNone(host.error)
            self.assertFalse({'package-build', 'package-core', 'package'} & set(host.names))
            self.assertEqual(sorted(host.skipped), ['package', 'package-build'])
            self.assertIn('passed all 4 tests', host.skipped['package'])
            self.assertEqual(host.manifest['sessionkit_pass']['reused'], KEY)
            self.assertTrue(any(n.startswith('SessionKit build and tests skipped') for n in host.manifest['notes']))

    def test_a_run_given_no_changed_paths_never_skips(self):
        # The Test Desk's run on next and a session's own run have no list: they are the backstop.
        for changed in (None, []):
            with self.subTest(changed=changed), tempfile.TemporaryDirectory() as state:
                self.passed(state)
                host = Host(self, changed).run(state)
                self.assertTrue({'package-build', 'package-core', 'package'} <= set(host.names))
                self.assertFalse(host.skipped)

    def test_a_different_key_runs_the_tests(self):
        # The key changes with any input, the toolchain or the runner (tests/test_sessionkit_pass.py).
        with tempfile.TemporaryDirectory() as state:
            self.passed(state)
            host = Host(self, ['Packages/SessionKit/Sources/SessionKit/A.swift'], key='j' * 64).run(state)
            self.assertTrue({'package-build', 'package-core', 'package'} <= set(host.names))
            self.assertIsNotNone(verification.sessionkit_pass.find(state, 'j' * 64))

    def test_an_unknown_toolchain_neither_skips_nor_records(self):
        with tempfile.TemporaryDirectory() as state:
            self.passed(state, toolchain=None)
            self.assertFalse(list(Path(state).rglob('*.json')))
            host = Host(self, ['docs/a.md'], toolchain=None).run(state)
            self.assertIn('package', host.names)

    def test_a_failed_run_records_nothing_and_the_next_run_tests_again(self):
        for failing in ('package-build', 'package'):
            with self.subTest(failing), tempfile.TemporaryDirectory() as state:
                host = Host(self, ['docs/a.md'], fail=[failing]).run(state)
                self.assertIsNotNone(host.error)
                self.assertIsNone(verification.sessionkit_pass.find(state, KEY))
                self.assertIn('package', Host(self, ['docs/a.md']).run(state).names)

    def test_inputs_that_change_during_the_run_record_nothing(self):
        with tempfile.TemporaryDirectory() as state:
            host = Host(self, ['docs/a.md'], key=[KEY, 'j' * 64]).run(state)  # the key before the run, then after it
            self.assertIsNone(host.error)
            self.assertIn('package', host.names)
            self.assertFalse(list(Path(state).rglob('*.json')))

    def test_inside_the_codex_sandbox_nothing_is_skipped_or_recorded(self):
        # Its audio tests are allowed to fail there, so a pass there proves less than a pass outside it.
        with tempfile.TemporaryDirectory() as state:
            verification.sessionkit_pass.record(state, KEY, head='abc', tests=1)
            host = Host(self, ['docs/a.md'], environment={'CODEX_SANDBOX': 'seatbelt'}).run(state)
            self.assertIsNone(host.error)
            self.assertIn('package', host.names)
            self.assertFalse(host.skipped)
            self.assertNotIn('package-core', host.names)  # one serial step, as before
            self.assertEqual(host.step('package')[0][-1], '--skip-build')


class ParallelCoreTests(unittest.TestCase):
    def test_core_runs_in_parallel_and_the_rest_serially_and_each_expects_only_its_own_tests(self):
        with tempfile.TemporaryDirectory() as state:
            host = Host(self, None).run(state)
            self.assertIsNone(host.error)
            self.assertEqual(host.names.index('package-build') + 1, host.names.index('package-core'))
            args, kw = host.step('package-core')
            self.assertEqual(args[:2], ['bash', 'scripts/run-sessionkit-tests.sh'])
            self.assertEqual(args[2], '--core-parallel')
            self.assertEqual(Path(args[3]).name, 'package-core.xunit.xml')
            self.assertEqual((kw['expected'], kw['tests']), (CORE, True))
            self.assertTrue(callable(kw['record_source']))
            args, kw = host.step('package')
            self.assertEqual(args[-1], '--rest')
            self.assertEqual((kw['expected'], kw['tests']), (REST, True))
            self.assertIn('SessionKitTests/SharingTests/testHeldOutPublicDomainPodcastAnchorCorpus', kw['allowed_skips'])
            # Every PocketRendererTests case that calls fetchedWeights() skips on the lane Mac, which has no weights.
            source = (SCRIPTS.parent / 'Packages/SessionKit/Tests/SessionKitTests/PocketRendererTests.swift').read_text()
            needing = {name for name, body in re.findall(r'func (test\w+)\(\)[^{]*\{(.*?)(?=\n    func |\Z)', source, re.S)
                       if 'fetchedWeights()' in body}
            self.assertGreaterEqual(len(needing), 4)
            for test in needing:
                self.assertIn(f'SessionKitTests/PocketRendererTests/{test}', kw['allowed_skips'])
            # Together they are the same tests the one step expected before.
            self.assertEqual(CORE | REST, host.step('package-core')[1]['expected'] | kw['expected'])

    def test_the_read_meter_tests_that_skip_by_design_are_allowed_in_both_core_steps(self):
        # #2258: the known-oversized Library read skips on every fast run, and the cost table skips unless asked for.
        source = (SCRIPTS.parent / 'Packages/SessionKit/Tests/SessionKitCoreTests/StoreReadMeterTests.swift').read_text()
        skipping = {name for name, body in re.findall(r'func (test\w+)\(\)[^{]*\{(.*?)(?=\n    func |\n    private func |\Z)',
                                                      source, re.S)
                    if 'XCTSkip' in body or 'expectKnownOversized(' in body}
        self.assertEqual(skipping, {'testTheLibraryListDoesNotDecodeEveryArticleText', 'testReadCostTableAtEveryScale'})
        with tempfile.TemporaryDirectory() as state:
            host = Host(self, None, fail=['package-core']).run(state)
            for step in ('package-core', 'package-core-serial'):
                allowed = host.step(step)[1]['allowed_skips']
                for test in skipping:
                    self.assertIn(f'SessionKitCoreTests/StoreReadMeterTests/{test}', allowed, step)
                self.assertTrue(verification.HANG_PROBE_TIMING_TESTS <= set(allowed), step)

    def test_a_failed_parallel_run_is_run_again_serially_and_the_serial_run_decides(self):
        with tempfile.TemporaryDirectory() as state:
            host = Host(self, None, fail=['package-core']).run(state)
            self.assertIsNone(host.error)
            self.assertEqual(host.names.count('package-core'), 1)
            self.assertLess(host.names.index('package-core'), host.names.index('package-core-serial'))
            serial_args, serial_kw = host.step('package-core-serial')
            self.assertEqual(serial_args[-1], '--core-serial')
            self.assertEqual(serial_kw['expected'], CORE)
            self.assertNotIn('record_source', serial_kw)  # the log is its record
            parallel = next(s for s in host.manifest['steps'] if s['name'] == 'package-core')
            self.assertTrue(parallel['superseded'])
            self.assertTrue(any('parallel run failed' in note for note in host.manifest['notes']))
            self.assertIn('package', host.names)  # the rest still runs
            self.assertIsNotNone(verification.sessionkit_pass.find(state, KEY))

    def test_when_the_serial_run_fails_too_the_run_fails_and_nothing_is_recorded(self):
        with tempfile.TemporaryDirectory() as state:
            host = Host(self, None, fail=['package-core', 'package-core-serial']).run(state)
            self.assertIn('package-core-serial failed', str(host.error))
            self.assertNotIn('package', host.names)
            self.assertIsNone(verification.sessionkit_pass.find(state, KEY))

    def test_a_failure_in_the_rest_stays_the_prs_even_after_a_clean_parallel_run(self):
        with tempfile.TemporaryDirectory() as state:
            host = Host(self, None, fail=['package']).run(state)
            self.assertIn('package failed', str(host.error))
            self.assertNotIn('package-core-serial', host.names)

    def test_a_run_the_lane_stopped_is_not_run_again_serially(self):
        # The lane interrupts a timed-out job; a serial run started then would outlive it in its own session.
        with tempfile.TemporaryDirectory() as temporary:
            run = verification.Run(Path(temporary) / 'run', 'fast')
            ran = []

            def command(name, args, **kw):
                ran.append(name)
                run.manifest['steps'].append({'name': name, 'signalled': name == 'package-core'})
                raise RuntimeError('stopped')
            with patch.object(run, 'command', side_effect=command), self.assertRaises(RuntimeError):
                run.package_core(CORE)
            self.assertEqual(ran, ['package-core'])

    def test_command_marks_an_interrupt_apart_from_its_own_time_limit(self):
        with tempfile.TemporaryDirectory() as temporary:
            run = verification.Run(Path(temporary) / 'run', 'test')
            with self.assertRaises(RuntimeError):
                run.command('slow', [sys.executable, '-c', 'import time; time.sleep(30)'], timeout=1)
            step = run.manifest['steps'][-1]
            self.assertEqual((step['interrupted'], step['signalled']), (True, False))

    def test_a_package_with_no_core_tests_keeps_the_one_serial_step(self):
        with tempfile.TemporaryDirectory() as state:
            host = Host(self, None, core=set()).run(state)
            self.assertNotIn('package-core', host.names)
            self.assertEqual(host.step('package')[0][-1], '--skip-build')
            self.assertEqual(host.step('package')[1]['expected'], REST)

    def test_xunit_results_become_test_records(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / 'x.xml'
            path.write_text(XUNIT)
            records = verification.xunit_records(path)
            self.assertEqual({k: v['status'] for k, v in records.items()}, {
                'SessionKitCoreTests/AlphaTests/testOne': 'passed',
                'SessionKitCoreTests/AlphaTests/testTwo': 'failed',  # "testTwo()" is the same method
                'SessionKitCoreTests/BetaTests/testThree': 'skipped'})
            self.assertAlmostEqual(records['SessionKitCoreTests/AlphaTests/testOne']['seconds'], 0.1)

    def test_a_missing_empty_or_broken_result_file_has_no_records_so_the_step_fails(self):
        with tempfile.TemporaryDirectory() as temporary:
            for text in (None, '', 'not xml', '<testsuites/>', '<testsuites><testcase classname="x" name="y"/></testsuites>'):
                path = Path(temporary) / 'x.xml'
                path.unlink(missing_ok=True)
                if text is not None:
                    path.write_text(text)
                self.assertEqual(verification.xunit_records(path), {}, text)
        errors = verification.reconcile(CORE, {})
        self.assertIn('No completed tests recorded', errors)

    def test_the_xunit_records_meet_the_same_checks_as_the_log_records(self):
        records = {f'{test}': {'status': 'passed', 'seconds': 0.1} for test in CORE}
        self.assertEqual(verification.reconcile(CORE, records), [])
        self.assertTrue(verification.reconcile(CORE | {'SessionKitCoreTests/AlphaTests/testMissing'}, records))
        records['SessionKitCoreTests/AlphaTests/testTwo']['status'] = 'skipped'
        self.assertEqual(verification.reconcile(CORE, records), ['Unexpected skip: SessionKitCoreTests/AlphaTests/testTwo'])

    def test_command_takes_its_records_from_the_result_file_not_the_log(self):
        # The parallel run prints no "Test Case ... passed" line, so a step run for real must read the file.
        script = ('import sys; from pathlib import Path; Path(sys.argv[1]).write_text(sys.argv[2]); '
                  'print("[1/2] Testing SessionKitCoreTests.AlphaTests/testOne")')
        with tempfile.TemporaryDirectory() as temporary:
            xunit = Path(temporary) / 'x.xml'
            run = verification.Run(Path(temporary) / 'run', 'test')
            good = XUNIT.replace('<failure message="failed"></failure>', '').replace('<skipped/>', '')
            run.command('package-core', [sys.executable, '-c', script, str(xunit), good],
                        expected={'SessionKitCoreTests/AlphaTests/testOne', 'SessionKitCoreTests/AlphaTests/testTwo',
                                  'SessionKitCoreTests/BetaTests/testThree'},
                        tests=True, record_source=lambda: verification.xunit_records(xunit))
            step = run.manifest['steps'][-1]
            self.assertEqual((step['test_evidence'], step['counts']['passed'], step['errors']), ('xunit', 3, []))
            with self.assertRaises(RuntimeError) as raised:  # the same output with a failing case
                run.command('package-core', [sys.executable, '-c', script, str(xunit), XUNIT],
                            expected={'SessionKitCoreTests/AlphaTests/testOne', 'SessionKitCoreTests/AlphaTests/testTwo',
                                      'SessionKitCoreTests/BetaTests/testThree'},
                            tests=True, record_source=lambda: verification.xunit_records(xunit))
            self.assertIn('Failed: SessionKitCoreTests/AlphaTests/testTwo', str(raised.exception))
            with self.assertRaises(RuntimeError) as raised:  # no file at all
                run.command('package-core', [sys.executable, '-c', 'print("nothing")'], expected=CORE, tests=True,
                            record_source=lambda: verification.xunit_records(Path(temporary) / 'none.xml'))
            self.assertIn('No completed tests recorded', str(raised.exception))


class DownstreamTests(unittest.TestCase):
    """What reads the manifest: a superseded parallel run must not read as the PR's failure."""

    def manifest(self, steps):
        with tempfile.TemporaryDirectory() as temporary:
            (Path(temporary) / 'manifest.json').write_text(json.dumps({'steps': steps}))
            return lane_next_rerun.failing_tests(Path(temporary), Path(temporary))

    def test_the_failing_tests_come_from_the_serial_run_that_replaced_the_parallel_one(self):
        parallel = {'name': 'package-core', 'superseded': 'run again serially', 'errors': ['Failed: SessionKitCoreTests/A/testX'],
                    'tests': {'SessionKitCoreTests/A/testX': {'status': 'failed'}}}
        serial = {'name': 'package-core-serial', 'errors': ['Process exit 1', 'Failed: SessionKitCoreTests/A/testX'],
                  'tests': {'SessionKitCoreTests/A/testX': {'status': 'failed'}}}
        self.assertEqual(self.manifest([parallel, serial]), ('swift', 'Packages/SessionKit', ['SessionKitCoreTests/A/testX']))
        self.assertIsNone(self.manifest([parallel]))  # nothing else decided

    def test_a_pr_failing_in_the_rest_names_those_tests(self):
        step = {'name': 'package', 'errors': ['Failed: SessionKitTests/B/testY'],
                'tests': {'SessionKitTests/B/testY': {'status': 'failed'}}}
        self.assertEqual(self.manifest([step]), ('swift', 'Packages/SessionKit', ['SessionKitTests/B/testY']))


class ScriptTests(unittest.TestCase):
    def run_script(self, *args, **env):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / 'scripts').mkdir()
            (root / 'Packages/SessionKit').mkdir(parents=True)
            (root / 'scripts/run-sessionkit-tests.sh').write_text((SCRIPTS / 'run-sessionkit-tests.sh').read_text())
            lane = root / 'scripts/host-test-lane'
            lane.write_text(f'#!/bin/sh\nprintf "%s\\037" "$@" >> "{root}/calls"\necho >> "{root}/calls"\n')
            lane.chmod(0o755)
            environment = {key: value for key, value in os.environ.items() if key != 'CODEX_SANDBOX'}
            done = subprocess.run(['bash', str(root / 'scripts/run-sessionkit-tests.sh'), *args],
                                  env={**environment, **env}, capture_output=True, text=True, timeout=30)
            calls = (root / 'calls').read_text().splitlines() if (root / 'calls').exists() else []
            return done, [call.rstrip('\x1f').split('\x1f') for call in calls]

    def test_the_groups_are_anchored_on_their_modules_and_only_core_runs_in_parallel(self):
        done, calls = self.run_script('--core-parallel', '/tmp/x.xml')
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual(calls, [['swift', 'test', '--skip-build', '--parallel', '--num-workers', '4', '--filter',
                                  '^SessionKitCoreTests\\.', '--xunit-output', '/tmp/x.xml']])
        done, calls = self.run_script('--core-serial')
        self.assertEqual(calls, [['swift', 'test', '--skip-build', '--filter', '^SessionKitCoreTests\\.']])
        done, calls = self.run_script('--rest')
        self.assertEqual(calls, [['swift', 'test', '--skip-build', '--filter',
                                  '^(SessionKitTests|SessionKitTraceTests)\\.']])
        self.assertNotIn('--parallel', calls[0])  # the real-time AVFoundation tests stay serial

    def test_the_filters_match_every_test_of_their_target_and_none_of_another(self):
        import re
        core, rest = r'^SessionKitCoreTests\.', r'^(SessionKitTests|SessionKitTraceTests)\.'
        ids = {'core': 'SessionKitCoreTests.AlphaTests/testOne', 'sk': 'SessionKitTests.RealPlayerTests/testPlays',
               'trace': 'SessionKitTraceTests.TraceTests/testReplay'}
        self.assertEqual([k for k, v in ids.items() if re.search(core, v)], ['core'])
        self.assertEqual([k for k, v in ids.items() if re.search(rest, v)], ['sk', 'trace'])

    def test_the_parallel_mode_needs_a_result_file_and_the_sandbox_flag_follows_every_mode(self):
        done, calls = self.run_script('--core-parallel')
        self.assertEqual((done.returncode, calls), (2, []))
        for args in (('--core-parallel', '/tmp/x.xml'), ('--core-serial',), ('--rest',)):
            done, calls = self.run_script(*args, CODEX_SANDBOX='seatbelt')
            self.assertEqual(calls[0][-1], '--disable-sandbox', args)


if __name__ == '__main__':
    unittest.main()
