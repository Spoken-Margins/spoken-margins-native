"""The lane runner finds lane_slots even when the PR's tree predates it (#904).

The workflow runs next's lane-runner.py from $RUNNER_TEMP and copies next's lane_slots.py beside it. The
runner puts the PR tree's scripts/ first on sys.path, so the tree's copy wins when it has one, and
Python's script directory ($RUNNER_TEMP) is the fallback when it doesn't. Before this, #886 (a branch
from before lane_slots existed) stopped in wait_for_room_to_build with ModuleNotFoundError, twice.
"""
from __future__ import annotations

import shutil
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
WORKFLOW = SCRIPTS.parent / '.github/workflows/lane.yml'

DRIVER = textwrap.dedent('''
    import importlib.util, sys
    from pathlib import Path
    here = Path(__file__).resolve().parent
    spec = importlib.util.spec_from_file_location('lane_runner', here / 'lane-runner.py')
    runner = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(runner)
    sys.path.insert(0, sys.argv[1])  # what main() does with --tree
    problem = runner.wait_for_room_to_build(max_wait=0, simulator_jobs=lambda: 0, pressure=lambda: 1,
                                            free=lambda: 10 ** 13, builds=lambda: 0)
    import lane_slots
    print(Path(lane_slots.__file__).resolve().parent)
    print(problem)
''')


class LaneSlotsFallbackTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix='lane-slots-fallback-'))
        self.runner_temp = self.tmp / 'runner-temp'
        self.tree_scripts = self.tmp / 'tree' / 'scripts'
        self.runner_temp.mkdir()
        self.tree_scripts.mkdir(parents=True)
        shutil.copy(SCRIPTS / 'lane-runner.py', self.runner_temp / 'lane-runner.py')
        (self.runner_temp / 'driver.py').write_text(DRIVER)

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def run_driver(self):
        return subprocess.run([sys.executable, str(self.runner_temp / 'driver.py'), str(self.tree_scripts)],
                              capture_output=True, text=True, timeout=60, cwd=self.tmp)

    def test_old_tree_without_lane_slots_fails_without_the_copy(self):
        result = self.run_driver()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("No module named 'lane_slots'", result.stderr)

    def test_old_tree_uses_the_copy_beside_the_runner(self):
        shutil.copy(SCRIPTS / 'lane_slots.py', self.runner_temp / 'lane_slots.py')
        result = self.run_driver()
        self.assertEqual(result.returncode, 0, result.stderr)
        found, problem = result.stdout.splitlines()[-2:]
        self.assertEqual(Path(found), self.runner_temp.resolve())
        self.assertEqual(problem, 'None')

    def test_tree_copy_wins_when_present(self):
        shutil.copy(SCRIPTS / 'lane_slots.py', self.runner_temp / 'lane_slots.py')
        shutil.copy(SCRIPTS / 'lane_slots.py', self.tree_scripts / 'lane_slots.py')
        result = self.run_driver()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(Path(result.stdout.splitlines()[-2]), self.tree_scripts.resolve())

    def test_both_lane_jobs_copy_lane_slots_beside_the_runner(self):
        workflow = WORKFLOW.read_text()
        self.assertEqual(workflow.count('> "$RUNNER_TEMP/lane-runner.py"'), 2)
        self.assertEqual(workflow.count(
            'git show "origin/$BASE_REF:scripts/lane_slots.py" > "$RUNNER_TEMP/lane_slots.py"'), 2)


if __name__ == '__main__':
    unittest.main()
