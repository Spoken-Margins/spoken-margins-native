"""#2493: a runner that can't start the main checkout's .venv Python reports a runner fault, not the PR's FAIL.

At 01:18 UTC on 2026-10-23 macOS denied runner 2's service process (`node`) the Documents folder. From then on every
host-test run there died in 6 s with `PermissionError: [Errno 1] Operation not permitted: .../.venv/pyvenv.cfg`, and
the lane reported it as a FAIL on #2463, #2466, #2467, #2470, #2477 and others. The guard (lane-runner.py,
tools_python_fault) starts that Python once before any host test or T3.
"""
import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

SCRIPTS = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('lane_runner_tools_python', SCRIPTS / 'lane-runner.py')
lane = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lane)

# What the lane saw on 2026-10-23 (pr2466-r39877742296's verify-fast.log), word for word.
DENIED = ('Fatal Python error: init_import_site: Failed to import the site module\n'
          'Python runtime state: initialized\n'
          'Traceback (most recent call last):\n'
          '  File "<frozen site>", line 623, in venv\n'
          "PermissionError: [Errno 1] Operation not permitted: '/Users/x/Documents/GitHub/spoken-margins-native/.venv/"
          "pyvenv.cfg'\n")


class ToolsPythonTestCase(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.home = Path(temporary.name)
        self.tree = self.home / 'tree'
        self.tree.mkdir()
        steps = mock.patch.object(lane, 'STEP_RUNS', [])
        steps.start()
        self.addCleanup(steps.stop)

    def steps(self):
        return [(step['step'], step['verdict']) for step in lane.STEP_RUNS]

    def venv(self) -> Path:
        """A real venv in the tools checkout, linked into the tree as link_tools does."""
        tools = self.home / 'tools/.venv'
        subprocess.run([sys.executable, '-m', 'venv', '--without-pip', str(tools)], check=True, capture_output=True)
        (self.tree / '.venv').symlink_to(tools)
        return tools


class ToolsPythonGuardTests(ToolsPythonTestCase):
    def test_a_venv_python_that_starts_passes(self):
        self.venv()
        self.assertIsNone(lane.tools_python_fault(self.tree))
        self.assertEqual(self.steps(), [(lane.TOOLS_PYTHON_STEP, 'PASS')])

    def test_no_venv_is_no_fault(self):
        # The plans fall back to the lane's own Python then, as before.
        self.assertIsNone(lane.tools_python_fault(self.tree, run=lambda *a, **k: self.fail('nothing to start')))
        self.assertEqual(self.steps(), [])

    @unittest.skipIf(os.geteuid() == 0, 'root reads a file whatever its mode')
    def test_an_unreadable_pyvenv_cfg_is_a_runner_fault(self):
        # The real boundary: the venv's own Python dies in site.venv(), as on the Mac. chmod gives EACCES; macOS's
        # privacy refusal gives EPERM, which the next test feeds in.
        tools = self.venv()
        (tools / 'pyvenv.cfg').chmod(0)
        self.addCleanup((tools / 'pyvenv.cfg').chmod, 0o644)
        problem = lane.tools_python_fault(self.tree)
        self.assertTrue(problem.startswith(lane.TOOLS_PYTHON_FAULT), problem)
        self.assertIn('Permission denied', problem)
        self.assertIn(os.path.realpath(tools), problem)
        self.assertNotIn(lane.MACOS_PRIVACY_NOTE, problem)  # EACCES is a file mode, not the privacy setting
        self.assertEqual(self.steps(), [(lane.TOOLS_PYTHON_STEP, 'INCONCLUSIVE')])

    def test_operation_not_permitted_names_the_macos_privacy_setting(self):
        (self.tree / '.venv').mkdir()
        problem = lane.tools_python_fault(self.tree, run=lambda command, **k: subprocess.CompletedProcess(
            command, 1, '', DENIED))
        self.assertTrue(problem.startswith(lane.TOOLS_PYTHON_FAULT), problem)
        self.assertIn('Operation not permitted', problem)
        self.assertIn(lane.MACOS_PRIVACY_NOTE, problem)
        self.assertIn('Files and Folders', problem)

    def test_a_link_to_a_venv_that_is_gone_is_a_fault_not_a_silent_fallback(self):
        (self.tree / '.venv').symlink_to(self.home / 'gone/.venv')
        problem = lane.tools_python_fault(self.tree)
        self.assertTrue(problem.startswith(lane.TOOLS_PYTHON_FAULT), problem)
        self.assertIn('FileNotFoundError', problem)

    def test_a_python_that_hangs_at_startup_is_a_fault(self):
        (self.tree / '.venv').mkdir()

        def hang(command, **kwargs):
            raise subprocess.TimeoutExpired(command, kwargs['timeout'])

        self.assertIn('did not start', lane.tools_python_fault(self.tree, run=hang))


class LaneUseTests(ToolsPythonTestCase):
    def test_host_tests_stop_before_running_when_the_venv_python_cannot_start(self):
        # Before the fix this ran verify-tests.py, which died on startup, and reported FAIL on the PR.
        (self.tree / '.venv').mkdir()
        with tempfile.TemporaryDirectory() as evidence, \
                mock.patch.object(lane, 'ROOT', self.tree), \
                mock.patch.object(lane, 'ensure_lfs_files', return_value=None), \
                mock.patch.object(lane.subprocess, 'run', return_value=subprocess.CompletedProcess([], 1, '', DENIED)), \
                mock.patch.object(lane.subprocess, 'Popen', side_effect=AssertionError('no host tests')):
            verdict, details = lane.run_host_plan('fast', Path(evidence), lane.run_bounded, None)
        self.assertEqual(verdict, 'INCONCLUSIVE')
        (line,) = details
        self.assertTrue(line.startswith(lane.TOOLS_PYTHON_FAULT), line)

    def test_its_report_is_not_counted_against_the_newest_lane_change(self):
        # Auto-revert reverts a lane change after two runner faults; a privacy setting on the Mac is no lane change.
        (self.tree / '.venv').mkdir()
        problem = lane.tools_python_fault(self.tree, run=lambda command, **k: subprocess.CompletedProcess(
            command, 1, '', DENIED))
        wanted = lane.identity('auto', 'f' * 40, 'a' * 40, [])
        body = lane.report('pr9-r1', 'INCONCLUSIVE', 'f' * 40, 'a' * 40, 'auto', 'host only', 6, 'nothing', [problem],
                           'none', '/e', 'owner', wanted, base_name='main')
        self.assertEqual(lane.lane_report_verdict(body),
                         (False, "INCONCLUSIVE (the Mac's privacy settings, not a lane change (#2493))"))
        # A .venv that is merely broken could be a lane change's doing (link_tools), so it still counts.
        other = body.replace(problem, f'{lane.TOOLS_PYTHON_FAULT} (/x/.venv): exit 1: boom. Fix or re-create that '
                                      '.venv, then run the lane again; nothing was tested.')
        self.assertTrue(lane.lane_report_verdict(other)[0])


if __name__ == '__main__':
    unittest.main()
