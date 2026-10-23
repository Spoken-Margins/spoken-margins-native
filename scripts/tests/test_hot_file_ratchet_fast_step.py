"""verify-tests.py --plan fast runs the hot-file ratchet in the author's own loop (#2175).

On 2026-10-19 #2159 (+9 lines to Gate1AppModel.swift), #2155 (+6) and #2067 each failed only the lane's ratchet,
each after hours in the Mac queue, for a check that takes seconds. The fast plan now runs it first, before the
host-test slot, and fails with the lane's words; a lane run leaves it to the runner, which knows the PR's labels.
"""
import contextlib
import importlib.util
import io
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))


def load(name, file):
    spec = importlib.util.spec_from_file_location(name, SCRIPTS / file)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


verification = load('verification', 'verify-tests.py')
ratchet = load('hot_file_ratchet', 'hot_file_ratchet.py')
HOT = ratchet.HOT_FILES[0]


class FastPlanOrderTests(unittest.TestCase):
    def run_fast(self, changed, env=None):
        calls = []
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / 'node_modules').mkdir()
            subprocess.run(['git', 'init', '-q', '-b', 'next', str(root)], check=True)
            subprocess.run(['git', '-C', str(root), '-c', 'user.name=t', '-c', 'user.email=t@example.com',
                            'commit', '-q', '--allow-empty', '-m', 'start'], check=True)
            subprocess.run(['git', '-C', str(root), 'update-ref', 'refs/remotes/origin/next', 'HEAD'], check=True)
            run = verification.Run(root / 'run', 'fast', changed)
            with mock.patch.object(run, 'command', side_effect=lambda name, args, **kw: calls.append((name, args))), \
                    mock.patch.object(run, 'host_steps', side_effect=lambda: calls.append(('host-steps', None))), \
                    mock.patch.object(verification, 'ROOT', root), \
                    mock.patch.object(verification, 'host_test_slot',
                                      side_effect=lambda *a, **k: calls.append(('slot', None)) or contextlib.nullcontext({})), \
                    mock.patch.dict(os.environ, {'SM_TRUNK': 'next', **(env or {})}), \
                    contextlib.redirect_stdout(io.StringIO()):
                # These tests may themselves run in the lane, whose workflows set SM_TRUNK from the repository
                # variable; the fixture's trunk is next whatever that variable says (#2180 audit).
                for key in ('SM_HOT_FILE_OK', 'GITHUB_ACTIONS'):
                    if key not in (env or {}):
                        os.environ.pop(key, None)
                run.fast()
            skipped = {step['name']: step['skipped'] for step in run.manifest['steps'] if 'skipped' in step}
        return calls, skipped

    def test_the_author_s_fast_run_checks_the_ratchet_first_outside_the_slot(self):
        calls, _ = self.run_fast(None)
        self.assertEqual([name for name, _ in calls], ['hot-file-ratchet', 'slot', 'host-steps'])
        self.assertEqual(calls[0][1][1:], ['scripts/hot_file_ratchet.py', '--base', 'origin/next'])

    def test_a_lane_run_leaves_the_ratchet_to_the_runner(self):
        # The runner judges next's copy with the PR's labels; a hot-file-ok PR must not fail here.
        calls, skipped = self.run_fast(['App/SpokenMarginsApp/X.swift'])
        self.assertNotIn('hot-file-ratchet', [name for name, _ in calls])
        self.assertIn('lane runner', skipped['hot-file-ratchet'])

    def test_a_ci_job_without_changed_paths_leaves_the_ratchet_to_the_runner(self):
        # The lane drops --changed-files when a path can't be passed (a name with a newline or edge whitespace),
        # and its runner-tests step runs these tests inside the lane job too. Either way the runner has already
        # judged the ratchet with the PR's labels, so a hot-file-ok PR must not fail here (#2180 audit).
        calls, skipped = self.run_fast(None, env={'GITHUB_ACTIONS': 'true'})
        self.assertNotIn('hot-file-ratchet', [name for name, _ in calls])
        self.assertIn('lane runner', skipped['hot-file-ratchet'])

    def test_a_granted_hot_file_ok_skips_it_by_name(self):
        calls, skipped = self.run_fast(None, env={'SM_HOT_FILE_OK': '1'})
        self.assertNotIn('hot-file-ratchet', [name for name, _ in calls])
        self.assertIn('hot-file-ok', skipped['hot-file-ratchet'])


class RatchetStepVerdictTests(unittest.TestCase):
    """The real ratchet script on a fixture repository, run through the step: the lane's words, or a pass."""

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name) / 'repo'
        (self.root / 'scripts').mkdir(parents=True)
        shutil.copy(SCRIPTS / 'hot_file_ratchet.py', self.root / 'scripts')
        self.git('init', '-q', '-b', 'next')
        self.write(100, 'next')
        self.git('checkout', '-q', '-b', 'pr')

    def git(self, *args):
        subprocess.run(['git', '-c', 'user.name=t', '-c', 'user.email=t@example.com', '-C', str(self.root), *args],
                       check=True, capture_output=True)

    def write(self, lines, message):
        target = self.root / HOT
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(''.join(f'{n}: {message}\n' for n in range(lines)))
        self.git('add', '.')
        self.git('commit', '-q', '-m', message)

    def step(self):
        run = verification.Run(Path(self.temporary.name) / 'run', 'fast', None)
        with mock.patch.object(verification, 'ROOT', self.root), mock.patch.dict(os.environ), \
                contextlib.redirect_stdout(io.StringIO()):
            for key in ('SM_HOT_FILE_OK', 'GITHUB_ACTIONS'):  # the lane's runner-tests step runs these inside a CI job
                os.environ.pop(key, None)
            run.hot_file_ratchet(base='next')
        return run

    def test_growing_the_model_fails_with_the_lane_s_message(self):
        self.write(109, 'nine more lines, as #2159 did')
        with self.assertRaises(RuntimeError) as failed:
            self.step()
        message = str(failed.exception)
        self.assertIn(f'hot-file ratchet — {Path(HOT).name} would be 109 lines, above its ceiling of 100', message)
        self.assertIn('Move 9 lines out of it, or ask the desk for the hot-file-ok label.', message)

    def test_moving_as_many_lines_out_as_were_added_passes(self):
        self.write(100, 'added six, moved six out')
        run = self.step()
        self.assertEqual(run.manifest['steps'][-1]['errors'], [])

    def test_a_clone_without_the_base_names_the_skip(self):
        run = verification.Run(Path(self.temporary.name) / 'run', 'fast', None)
        with mock.patch.object(verification, 'ROOT', self.root), mock.patch.dict(os.environ), \
                contextlib.redirect_stdout(io.StringIO()):
            for key in ('SM_HOT_FILE_OK', 'GITHUB_ACTIONS'):
                os.environ.pop(key, None)
            os.environ['SM_TRUNK'] = 'main'  # the lane sets it from the repository variable once #1492 moves the trunk
            run.hot_file_ratchet(base='origin/next')
        # The fetch it names is the base it was given, not whatever the environment calls the trunk (#2180 audit).
        self.assertIn('git fetch origin next', run.manifest['steps'][-1]['skipped'])

    def test_a_clone_without_the_trunk_names_the_trunk_s_fetch(self):
        run = verification.Run(Path(self.temporary.name) / 'run', 'fast', None)
        with mock.patch.object(verification, 'ROOT', self.root), mock.patch.dict(os.environ, {'SM_TRUNK': 'main'}), \
                contextlib.redirect_stdout(io.StringIO()):
            for key in ('SM_HOT_FILE_OK', 'GITHUB_ACTIONS'):
                os.environ.pop(key, None)
            run.hot_file_ratchet()
        self.assertIn('origin/main is not in this clone; run `git fetch origin main`',
                      run.manifest['steps'][-1]['skipped'])


if __name__ == '__main__':
    unittest.main()
