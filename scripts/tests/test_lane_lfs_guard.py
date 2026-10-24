"""#2139: the lane never tests a checkout whose Git LFS files are pointers, and no Mac job writes pointers.

On 2026-10-19 shipped-build-compat.yml checked out without LFS in the lane's workspace on runner 1. Its pointer files
stayed through the lane's own `lfs: true` checkout, and every T3 that reached the Supertonic test failed with
`Protobuf parsing failed`, read as the PR's FAIL. The guard (lane-runner.py, ensure_lfs_files) restores a pointer from
the LFS cache, and reports one it can't restore as a runner fault before anything is built or tested.
"""
import importlib.util
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest
from unittest import mock

SCRIPTS = Path(__file__).resolve().parents[1]
WORKFLOWS = SCRIPTS.parent / '.github/workflows'
spec = importlib.util.spec_from_file_location('lane_runner_lfs', SCRIPTS / 'lane-runner.py')
lane = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lane)

MODEL = 'Resources/model.onnx'
CONTENT = b'\x08\x07\x12\x07pytorch' + bytes(range(256)) * 8  # stands in for an ONNX graph
OID = 'sha256:' + '4d7a214614ab2935c943f9e0ff69d22eadbb8f32b1258daaa5e2ca24d17e2393'
ATTRIBUTES = '*.onnx filter=lfs diff=lfs merge=lfs -text\n'
POINTER = f'version https://git-lfs.github.com/spec/v1\noid {OID}\nsize 132\n'.encode()


def git(tree, *args, **kwargs):
    return subprocess.run(['git', '-C', str(tree), *args], check=True, capture_output=True, **kwargs)


def has_git_lfs() -> bool:
    return shutil.which('git-lfs') is not None and subprocess.run(['git', 'lfs', 'version'],
                                                                   capture_output=True).returncode == 0


class GuardTestCase(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.tree = Path(temporary.name) / 'tree'
        self.tree.mkdir()
        # The VPS runner sets GIT_LFS_SKIP_SMUDGE=1 for its own jobs; these tests decide it themselves.
        environment = mock.patch.dict(os.environ)
        environment.start()
        self.addCleanup(environment.stop)
        os.environ.pop('GIT_LFS_SKIP_SMUDGE', None)
        steps = mock.patch.object(lane, 'STEP_RUNS', [])
        steps.start()
        self.addCleanup(steps.stop)
        printing = mock.patch('builtins.print')
        printing.start()
        self.addCleanup(printing.stop)

    def init(self):
        git(self.tree, 'init', '--quiet')
        git(self.tree, 'config', 'user.name', 'lane test')
        git(self.tree, 'config', 'user.email', 'lane@localhost')
        (self.tree / 'Resources').mkdir()
        (self.tree / 'Resources/notes.txt').write_bytes(POINTER)  # not an LFS path: never the guard's business

    def steps(self):
        return [(step['step'], step['verdict']) for step in lane.STEP_RUNS]


class PointerGuardTests(GuardTestCase):
    """Plain Git, no git-lfs needed: the model is committed as whatever bytes the test writes. The attribute comes
    after the commit, so no LFS filter a machine has configured runs; ls-files reads it from the working tree."""

    def setUp(self):
        super().setUp()
        self.init()
        (self.tree / MODEL).write_bytes(POINTER)
        git(self.tree, 'add', '.')
        git(self.tree, 'commit', '--quiet', '-m', 'model')
        (self.tree / '.gitattributes').write_text(ATTRIBUTES)

    def test_finds_only_lfs_paths_that_hold_a_pointer(self):
        self.assertEqual(lane.lfs_pointer_files(self.tree), [MODEL])
        (self.tree / MODEL).write_bytes(CONTENT)
        self.assertEqual(lane.lfs_pointer_files(self.tree), [])

    def test_a_large_file_that_starts_like_a_pointer_is_content(self):
        (self.tree / MODEL).write_bytes(POINTER + b'\0' * 1024)
        self.assertEqual(lane.lfs_pointer_files(self.tree), [])

    def test_a_missing_file_or_a_folder_that_is_no_checkout_is_not_a_pointer(self):
        (self.tree / MODEL).unlink()
        self.assertEqual(lane.lfs_pointer_files(self.tree), [])
        self.assertEqual(lane.lfs_pointer_files(self.tree.parent), [])

    def test_a_pointer_the_cache_restores_is_repaired_and_the_run_goes_on(self):
        calls = []

        def restore(command, **kwargs):
            calls.append(command)
            (self.tree / MODEL).write_bytes(CONTENT)
            return subprocess.CompletedProcess(command, 0, '', '')

        self.assertIsNone(lane.ensure_lfs_files(self.tree, run=restore))
        self.assertEqual(calls, [['git', '-C', str(self.tree), 'lfs', 'checkout', MODEL]])
        self.assertEqual(self.steps(), [(lane.LFS_STEP, 'REPAIRED')])

    def test_a_pointer_left_after_the_repair_is_a_runner_fault_naming_the_file(self):
        def nothing(command, **kwargs):
            return subprocess.CompletedProcess(command, 0, '', 'Skipped checkout for "model.onnx", content not local.\n')

        problem = lane.ensure_lfs_files(self.tree, run=nothing)
        self.assertIn(f'{MODEL}: LFS pointer, not the model', problem)
        self.assertTrue(problem.startswith('runner fault, not the PR (#2139)'), problem)
        self.assertIn('content not local', problem)
        self.assertEqual(self.steps(), [(lane.LFS_STEP, 'INCONCLUSIVE')])

    def test_real_files_pass_without_running_git_lfs(self):
        (self.tree / MODEL).write_bytes(CONTENT)
        self.assertIsNone(lane.ensure_lfs_files(self.tree, run=lambda *a, **k: self.fail('nothing to repair')))
        self.assertEqual(self.steps(), [(lane.LFS_STEP, 'PASS')])

    def test_a_job_that_skips_lfs_on_purpose_is_not_checked(self):
        # the hosted fast checks keep pointers on purpose.
        for value in ('1', 'true', 'TRUE'):
            os.environ['GIT_LFS_SKIP_SMUDGE'] = value
            self.assertIsNone(lane.ensure_lfs_files(self.tree, run=lambda *a, **k: self.fail('skipped jobs repair nothing')))
        self.assertEqual(self.steps(), [])
        os.environ['GIT_LFS_SKIP_SMUDGE'] = '0'
        self.assertIsNotNone(lane.ensure_lfs_files(self.tree, run=lambda command, **k: subprocess.CompletedProcess(
            command, 0, '', '')))

    def test_host_tests_stop_before_running_when_a_pointer_stays(self):
        with tempfile.TemporaryDirectory() as evidence, \
                mock.patch.object(lane, 'ROOT', self.tree), \
                mock.patch.object(lane, 'ensure_lfs_files', return_value='runner fault, not the PR (#2139): x'), \
                mock.patch.object(lane.subprocess, 'Popen', side_effect=AssertionError('no host tests')):
            verdict, details = lane.run_host_plan('fast', Path(evidence), lane.run_bounded, None)
        self.assertEqual((verdict, details), ('INCONCLUSIVE', ['runner fault, not the PR (#2139): x']))


@unittest.skipUnless(has_git_lfs(), 'git-lfs is not installed')
class GitLfsGuardTests(GuardTestCase):
    """The real `git lfs checkout`, from a real LFS cache: the scratch-copy proof the issue asks for."""

    def setUp(self):
        super().setUp()
        self.init()
        git(self.tree, 'lfs', 'install', '--local')
        (self.tree / '.gitattributes').write_text(ATTRIBUTES)
        (self.tree / MODEL).write_bytes(CONTENT)
        git(self.tree, 'add', '.')
        git(self.tree, 'commit', '--quiet', '-m', 'model')
        self.assertTrue(git(self.tree, 'show', f'HEAD:{MODEL}').stdout.startswith(lane.LFS_POINTER_HEADER))

    def write_pointer(self):
        """What a checkout without LFS leaves: the committed pointer, not the model."""
        (self.tree / MODEL).write_bytes(git(self.tree, 'show', f'HEAD:{MODEL}').stdout)
        self.assertEqual(lane.lfs_pointer_files(self.tree), [MODEL])

    def test_a_pointer_with_the_model_in_the_cache_is_restored_and_the_tree_stays_clean(self):
        self.write_pointer()
        self.assertIsNone(lane.ensure_lfs_files(self.tree))
        self.assertEqual((self.tree / MODEL).read_bytes(), CONTENT)
        self.assertEqual(git(self.tree, 'status', '--porcelain', text=True).stdout, '')
        self.assertEqual(self.steps(), [(lane.LFS_STEP, 'REPAIRED')])

    def test_a_pointer_with_no_model_in_the_cache_fails_with_the_file_named(self):
        self.write_pointer()
        shutil.rmtree(self.tree / '.git/lfs/objects')
        problem = lane.ensure_lfs_files(self.tree)
        self.assertIn(f'{MODEL}: LFS pointer, not the model', problem)
        self.assertTrue((self.tree / MODEL).read_bytes().startswith(lane.LFS_POINTER_HEADER))
        self.assertEqual(self.steps(), [(lane.LFS_STEP, 'INCONCLUSIVE')])


def jobs(text: str):
    """(name, body) for each job in a workflow, read as text: the repo's Python has no YAML parser."""
    block = text.split('\njobs:\n', 1)[1]
    return re.findall(r'^  ([\w-]+):\n((?:(?:    .*|\s*)\n)*)', block + '\n', re.M)


def checkouts(body: str):
    """The `with:` text of each actions/checkout step in a job body."""
    return re.findall(r'uses: actions/checkout@\S+[^\n]*\n(?:        with:\n)?((?:          .*\n)*)', body)


class MacCheckoutTests(unittest.TestCase):
    def test_every_checkout_on_the_mac_runners_fetches_lfs(self):
        # The Mac runners keep one workspace per runner, which the lane reuses. A checkout there without LFS
        # leaves pointers the lane's own checkout never rewrites (#2139: shipped-build-compat.yml's).
        mac_jobs = 0
        for workflow in sorted(WORKFLOWS.glob('*.yml')):
            for name, body in jobs(workflow.read_text()):
                runs_on = re.search(r'^    runs-on: (.*)$', body, re.M)
                if not runs_on or 'macOS' not in runs_on.group(1) or 'self-hosted' not in runs_on.group(1):
                    continue
                mac_jobs += 1
                for options in checkouts(body):
                    with self.subTest(workflow=workflow.name, job=name):
                        lfs = re.search(r'^\s+lfs: (.*)$', options, re.M)
                        self.assertIsNotNone(lfs, f'{workflow.name} {name}: its checkout needs `lfs: true`')
                        self.assertNotIn(lfs.group(1).strip(), ('false', "'false'"))
        self.assertGreaterEqual(mac_jobs, 3)  # lane, automerge, release (compat moved to a hosted Mac, #2596): the parse found the Mac jobs

    def test_the_compat_job_runs_hosted_in_a_fresh_workspace(self):
        # The compat job moved to the hosted xcode-27 Mac (#2596). A hosted run starts from an empty workspace, so
        # no lane checkout shares it and LFS pointers cannot linger; it builds only SessionKit, which bundles no
        # model. The rule that matters now: it must not go back to a self-hosted runner without `lfs: true`.
        text = (WORKFLOWS / 'shipped-build-compat.yml').read_text()
        compat = dict(jobs(text))['compat']
        self.assertRegex(compat, r'(?m)^    runs-on: xcode-27$')
        self.assertNotRegex(compat, r'(?m)^    runs-on:.*self-hosted')


if __name__ == '__main__':
    unittest.main()
