"""verify-tests.py's split of --plan fast and the hosted-portable.yml jobs that run it (#1389, #2596).

hosted-portable.yml runs fast-portable on Linux and fast-hosted-sessionkit and fast-mac-rest on hosted Macs on every
PR. These tests came from the retired test_lane_hosted_fast.py and test_lane_runner.py (#4769), which tested them
next to the dispatcher that has gone.
"""
import contextlib
import copy as copy_module
import importlib.util
import io
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

import yaml

TESTS = Path(__file__).resolve().parent
SCRIPTS = TESTS.parent
ROOT = SCRIPTS.parent
sys.path.insert(0, str(SCRIPTS))
sys.path.insert(0, str(TESTS))
spec = importlib.util.spec_from_file_location('verification', SCRIPTS / 'verify-tests.py')
verification = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verification)


class SplitPlanTests(unittest.TestCase):
    """verify-tests.py: the three plans together run every step of --plan fast, each on the machine it needs."""

    def test_the_three_plans_cover_every_fast_step(self):
        import test_fast_portable
        covered = (set(verification.PORTABLE_STEPS) | set(verification.HOSTED_SESSIONKIT_STEPS)
                   | set(verification.MAC_REST_STEPS))
        self.assertEqual(test_fast_portable.literal_steps() - covered, set())
        # What the portable plan leaves out, the other two run.
        self.assertEqual(set(verification.PORTABLE_LEFT_OUT) - covered, set())
        self.assertIn('package', verification.MAC_REST_STEPS)  # the sound-output step never leaves the Mac
        self.assertNotIn('package', verification.HOSTED_SESSIONKIT_STEPS)

    def run_plan(self, plan, changed):
        calls = []
        with tempfile.TemporaryDirectory() as temporary:
            (Path(temporary) / 'node_modules').mkdir()
            run = verification.Run(Path(temporary) / 'run', plan, changed)
            with mock.patch.object(run, 'command', side_effect=lambda name, args, **kw: calls.append((name, args))), \
                    mock.patch.object(run, 'ops_steps', side_effect=lambda **kw: calls.append(('ops', kw))), \
                    mock.patch.object(run, 'package_core', side_effect=lambda core: calls.append(('package-core', core))), \
                    mock.patch.object(run, 'package_steps',
                                      side_effect=lambda expected, **kw: calls.append(('package-steps', kw))), \
                    mock.patch.object(verification, 'ROOT', Path(temporary)), \
                    mock.patch.object(verification, 'swift_tests', return_value={'T/test'}), \
                    mock.patch.object(verification, 'in_codex_sandbox', return_value=False), \
                    mock.patch.object(verification.sessionkit_pass, 'toolchain', return_value=None), \
                    mock.patch.object(verification.sessionkit_pass, 'find', return_value=None), \
                    mock.patch.object(verification, 'host_test_slot',
                                      side_effect=lambda *a, **k: calls.append(('slot', None)) or contextlib.nullcontext({})), \
                    mock.patch.object(verification, 'input_identity', return_value=run.manifest['input_sha256']), \
                    contextlib.redirect_stdout(io.StringIO()):
                run.fast()
            skipped = {step['name'] for step in run.manifest['steps'] if 'skipped' in step}
        return calls, skipped

    def test_hosted_sessionkit_builds_and_runs_the_core_tests_without_a_mac_slot(self):
        calls, skipped = self.run_plan('fast-hosted-sessionkit', None)
        self.assertEqual([name for name, _ in calls], ['package-build', 'package-core'])
        self.assertEqual(calls[1][1], {'SessionKitCoreTests/T/test'})
        self.assertEqual(skipped, {'package'})

    def test_mac_rest_for_an_app_diff_runs_only_the_sessionkit_rest(self):
        calls, skipped = self.run_plan('fast-mac-rest', ['App/SpokenMarginsApp/X.swift'])
        self.assertEqual(calls, [('slot', None), ('package-steps', {'core_elsewhere': True})])
        self.assertEqual(skipped, {'hot-file-ratchet', 'runner-tests', 'ops', 'tools', 'shipped-compat'})

    def test_mac_rest_for_a_lane_diff_also_runs_the_apple_tool_tests_and_ops_disk(self):
        calls, _ = self.run_plan('fast-mac-rest', ['scripts/phone-build'])
        by_name = dict(calls)
        self.assertEqual(by_name['runner-tests'][1:3], ['-c', verification.MAC_REST_RUNNER_LOADER])
        self.assertEqual(by_name['runner-tests'][3:], list(verification.PORTABLE_RUNNER_TESTS_LEFT_OUT))
        self.assertEqual(by_name['ops'], {'only': verification.PORTABLE_OPS_LEFT_OUT})

    def test_the_mac_rest_loader_runs_only_the_listed_tests(self):
        with tempfile.TemporaryDirectory() as temporary:
            tests = Path(temporary) / 'scripts' / 'tests'
            tests.mkdir(parents=True)
            (tests / 'test_apple.py').write_text(
                'import unittest\nclass A(unittest.TestCase):\n    def test_needs_xcode(self): pass\n')
            (tests / 'test_other.py').write_text(
                'import unittest\nclass B(unittest.TestCase):\n    def test_elsewhere(self): self.fail("ran")\n')
            done = subprocess.run([sys.executable, '-c', verification.MAC_REST_RUNNER_LOADER, 'test_apple.'],
                                  cwd=temporary, capture_output=True, text=True)
            self.assertEqual(done.returncode, 0, done.stderr)
            self.assertIn('Ran 1 test', done.stderr)

    def test_package_steps_with_the_core_elsewhere_runs_only_the_rest(self):
        calls = []
        with tempfile.TemporaryDirectory() as temporary:
            run = verification.Run(Path(temporary) / 'run', 'fast-mac-rest')
            with mock.patch.object(run, 'command', side_effect=lambda name, args, **kw: calls.append((name, args, kw))), \
                    mock.patch.object(run, 'package_core', side_effect=lambda core: calls.append(('package-core',))), \
                    mock.patch.object(verification.host_audio, 'audio_output', return_value={'usable': True}), \
                    mock.patch.object(verification, 'in_codex_sandbox', return_value=False):
                run.package_steps({'SessionKitTests/A/test'}, core_elsewhere=True)
        self.assertEqual([call[0] for call in calls], ['package-build', 'package'])
        self.assertIn('--rest', calls[1][1])
        self.assertEqual(calls[1][2]['expected'], {'SessionKitTests/A/test'})


class HostedPortableWorkflowTests(unittest.TestCase):
    """The hosted jobs free their Mac slots on a red portable run, and no job runs on the retired VPS."""

    @classmethod
    def setUpClass(cls):
        cls.hosted = (ROOT / '.github/workflows/hosted-portable.yml').read_text()

    def test_a_red_portable_job_cancels_the_run_so_its_mac_jobs_free_their_slots(self):
        # #2596: the cancel job runs on Linux, only after `portable` ended `failure`, and holds no more than actions: write.
        # The Mac jobs may wait only for the ~20 s `scope` job and the ~2-minute `guards` job (merge groups only, which
        # frees the Macs from a group a repository rule already fails): the merge queue waits on them.
        jobs = yaml.safe_load(self.hosted)['jobs']
        stop = jobs['stop-macs-on-red']
        self.assertEqual(stop['needs'], 'portable')
        self.assertEqual(stop['runs-on'], 'ubuntu-latest')
        self.assertEqual(stop['permissions'], {'actions': 'write'})
        self.assertIn("needs.portable.result == 'failure'", stop['if'])
        self.assertIn('gh run cancel', stop['steps'][0]['run'])
        for name in ('sessionkit', 'mac-rest'):
            self.assertEqual(self.slow_needs(jobs[name]), [], name)
        # Only `scope` (a Linux job of about 20 seconds, #2650) and `guards` may come first; any other need fails the check.
        for allowed in ('scope', ['scope'], ['scope', 'guards']):
            copy = copy_module.deepcopy(jobs['mac-rest'])
            copy['needs'] = allowed
            self.assertEqual(self.slow_needs(copy), [], allowed)
        for slow in ('portable', ['scope', 'portable'], ['sessionkit']):
            copy = copy_module.deepcopy(jobs['mac-rest'])
            copy['needs'] = slow
            self.assertNotEqual(self.slow_needs(copy), [], slow)

    @staticmethod
    def slow_needs(job):
        needs = job.get('needs', [])
        needs = [needs] if isinstance(needs, str) else list(needs)
        return [name for name in needs if name not in ('scope', 'guards')]

    def test_no_workflow_job_runs_on_the_vps(self):
        # #2442, #2383: CI left the owner's VPS. linux-t1.yml is gone, and the lane-open pings keep their 10-minute
        # limit on a data branch (a compare-and-swap in ops/lane/sm_lane_open.py), not on the VPS runner's disk.
        workflows = ROOT / '.github/workflows'
        self.assertFalse((workflows / 'linux-t1.yml').exists())
        on_vps = {}
        for path in sorted(workflows.glob('*.yml')):
            text = path.read_text()
            self.assertNotIn('sm-vps-t1]', text, path.name)
            jobs = text.split('\njobs:\n', 1)[-1]
            for job, body in re.findall(r'(?ms)^  ([\w-]+):\n(.*?)(?=^  [\w-]+:\n|\Z)', jobs):
                if any('sm-vps' in runs_on for runs_on in re.findall(r'(?m)^    runs-on: (.*)$', body)):
                    on_vps.setdefault(path.name, []).append(job)
        self.assertEqual(on_vps, {})


class OnlyTestingTests(unittest.TestCase):
    def test_selectors_cover_classes_and_methods_only(self):
        self.assertTrue(verification.selected('T/A/test1', 'T/A'))
        self.assertTrue(verification.selected('T/A/test1', 'T/A/test1'))
        self.assertFalse(verification.selected('T/AB/test1', 'T/A'))

    def test_an_unknown_selector_fails_before_anything_is_built(self):
        with tempfile.TemporaryDirectory() as temporary:
            run = verification.Run(Path(temporary) / 'run', 'app')
            real_capture = verification.capture

            def capture(args):
                if args[0] in ('xcrun', 'xcodebuild', 'xcodegen'):
                    raise AssertionError(f'nothing should run: {args}')
                return real_capture(args)

            with mock.patch.object(verification, 'capture', side_effect=capture), \
                    mock.patch.object(verification.Run, 'command', side_effect=AssertionError('nothing should run')):
                with self.assertRaisesRegex(RuntimeError, 'Not in the AppBehavior test plan: SpokenMarginsAppTests/Nope'):
                    run.xcode('app', None, False, None, ['Nope'])


if __name__ == '__main__':
    unittest.main()
