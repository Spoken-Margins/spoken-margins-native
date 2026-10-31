import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPTS = Path(__file__).resolve().parents[1]
INSTALL = SCRIPTS / 'install-lane-guard.py'
SOURCES = ('lane_guard.py', 'toolchain_guard.py', 'context_handoff_hook.py')
INSTALLED = ('spoken-margins-lane-guard.py', 'spoken-margins-toolchain-guard.py', 'spoken-margins-context-handoff.py')


class InstallLaneGuardTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.home = Path(temporary.name)
        self.hooks = self.home / '.claude/hooks'

    def run_install(self, *args):
        return subprocess.run([sys.executable, str(INSTALL), *args], capture_output=True, text=True,
                              env={**os.environ, 'HOME': str(self.home)})

    def test_a_missing_hook_fails_the_drift_check(self):
        result = self.run_install('--check')
        self.assertEqual(result.returncode, 1)
        self.assertIn('spoken-margins-context-handoff.py: missing or different', result.stdout)

    def test_a_plain_install_leaves_the_context_handoff_hook_alone(self):
        result = self.run_install()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.hooks / INSTALLED[0]).exists())
        self.assertTrue((self.hooks / INSTALLED[1]).exists())
        self.assertFalse((self.hooks / INSTALLED[2]).exists())
        self.assertEqual(self.run_install('--check').returncode, 1)

    def test_a_plain_install_does_not_overwrite_a_different_live_handoff_hook(self):
        self.hooks.mkdir(parents=True)
        (self.hooks / INSTALLED[2]).write_text('# the live copy\n')
        result = self.run_install()
        self.assertEqual((self.hooks / INSTALLED[2]).read_text(), '# the live copy\n')
        self.assertIn('--context-handoff', result.stdout)

    def test_the_flag_installs_it_and_the_check_then_passes(self):
        result = self.run_install('--context-handoff')
        self.assertEqual(result.returncode, 0, result.stderr)
        for source, installed in zip(SOURCES, INSTALLED):
            self.assertEqual((self.hooks / installed).read_bytes(), (SCRIPTS / source).read_bytes())
        self.assertIn('hooks.PostToolUse', result.stdout)
        self.assertEqual(self.run_install('--check').returncode, 0)


if __name__ == '__main__':
    unittest.main()
