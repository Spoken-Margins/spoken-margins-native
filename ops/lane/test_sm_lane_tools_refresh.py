"""Host tests for the lane tools refresh, with real git clones and an injected installer. No network.

Run: python3 -m unittest ops/lane/test_sm_lane_tools_refresh.py
"""
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import sm_lane_tools_refresh as r  # noqa: E402

NOW = 1_800_000_000.0


def git(cwd, *args):
    subprocess.run(['git', '-C', str(cwd), '-c', 'user.name=t', '-c', 'user.email=t@t', *args],
                   check=True, capture_output=True)


class Base(unittest.TestCase):
    def setUp(self):
        self.dir = Path(tempfile.mkdtemp())
        self.addCleanup(lambda: subprocess.run(['rm', '-rf', str(self.dir)]))
        self.origin = self.dir / 'origin'
        self.origin.mkdir()
        git(self.origin, 'init', '-q', '-b', 'main')
        self.commit({'requirements-dev.txt': 'a\n', 'package-lock.json': '{"v":1}\n'}, 'first')
        self.tools = self.dir / 'tools'
        subprocess.run(['git', 'clone', '-q', '--depth', '1', f'file://{self.origin}', str(self.tools)], check=True)
        (self.tools / '.venv').mkdir()
        (self.tools / '.venv/.requirements-dev.txt').write_text('a\n')
        (self.tools / 'node_modules').mkdir()
        self.state = self.dir / 'state/state.json'
        self.commands, self.posted, self.lines = [], [], []
        self.is_busy = False

    def commit(self, files, message):
        for name, text in files.items():
            (self.origin / name).write_text(text)
        git(self.origin, 'add', '-A')
        git(self.origin, 'commit', '-q', '-m', message)

    def fake_run(self, args, cwd, env=None, timeout=1800):
        if args[0] == 'git':
            return r.sh(args, cwd, env, timeout)
        self.commands.append(args)
        return subprocess.CompletedProcess(args, 0, '', '')

    def refresh(self, now=NOW, run=None):
        return r.Refresh(self.tools, self.state, now, run=run or self.fake_run, busy=lambda: self.is_busy,
                         post=self.posted.append, log=self.lines.append)


class Follows(Base):
    def test_a_new_commit_moves_the_copy_and_nothing_else_runs(self):
        self.commit({'docs.md': 'x\n'}, 'docs')
        self.assertEqual(self.refresh().go(), 0)
        self.assertTrue((self.tools / 'docs.md').exists())
        self.assertEqual(self.commands, [])
        self.assertEqual(self.posted, [])

    def test_current_copy_is_left_alone(self):
        self.assertEqual(self.refresh().go(), 0)
        self.assertIn('tools copy is current', self.lines)
        self.assertEqual(self.commands, [])

    def test_a_changed_requirements_file_runs_the_bootstrap(self):
        self.commit({'requirements-dev.txt': 'a\nb\n'}, 'dep')
        self.refresh().go()
        self.assertEqual(self.commands, [['bash', 'scripts/bootstrap-python-tools.sh']])

    def test_a_changed_lockfile_runs_npm_ci_and_stamps_it(self):
        self.commit({'package-lock.json': '{"v":2}\n'}, 'lock')
        self.refresh().go()
        self.assertEqual(self.commands, [['npm', 'ci', '--no-audit', '--no-fund']])
        self.assertEqual((self.tools / 'node_modules' / r.LOCK_STAMP).read_text(), r.digest(self.tools / 'package-lock.json'))
        self.commands.clear()
        self.refresh().go()
        self.assertEqual(self.commands, [], 'the stamp says the install is current')

    def test_an_unchanged_lockfile_does_not_reinstall_when_the_stamp_is_missing(self):
        self.commit({'docs.md': 'x\n'}, 'docs')
        self.refresh().go()
        self.assertEqual(self.commands, [])


class Waiting(Base):
    def test_a_running_lane_job_defers_the_install_quietly_at_first(self):
        self.commit({'requirements-dev.txt': 'a\nb\n'}, 'dep')
        self.is_busy = True
        self.assertEqual(self.refresh().go(), 0)
        self.assertEqual(self.commands, [])
        self.assertEqual(self.posted, [])

    def test_after_six_hours_of_waiting_it_says_so_once(self):
        self.commit({'requirements-dev.txt': 'a\nb\n'}, 'dep')
        self.is_busy = True
        self.refresh().go()
        later = NOW + r.DEFER_LIMIT + 60
        self.assertEqual(self.refresh(later).go(), 1)
        self.assertEqual(len(self.posted), 1)
        self.assertIn('6 hours', self.posted[0])
        self.refresh(later + 3600).go()
        self.assertEqual(len(self.posted), 1, 'once a day per problem')

    def test_the_install_runs_when_the_lane_goes_quiet(self):
        self.commit({'requirements-dev.txt': 'a\nb\n'}, 'dep')
        self.is_busy = True
        self.refresh().go()
        self.is_busy = False
        self.refresh(NOW + 600).go()
        self.assertEqual(self.commands, [['bash', 'scripts/bootstrap-python-tools.sh']])


class Faults(Base):
    def test_a_failed_bootstrap_is_reported_on_337(self):
        self.commit({'requirements-dev.txt': 'a\nb\n'}, 'dep')

        def failing(args, cwd, env=None, timeout=1800):
            if args[0] == 'git':
                return r.sh(args, cwd, env, timeout)
            return subprocess.CompletedProcess(args, 1, '', 'pip exploded')
        self.assertEqual(self.refresh(run=failing).go(), 1)
        self.assertIn('pip exploded', self.posted[0])

    def test_a_missing_remote_is_reported(self):
        subprocess.run(['rm', '-rf', str(self.origin)])
        self.assertEqual(self.refresh().go(), 1)
        self.assertIn('could not fetch', self.posted[0])

    def test_a_path_that_is_not_a_checkout_is_reported(self):
        subprocess.run(['rm', '-rf', str(self.tools / '.git')])
        self.assertEqual(self.refresh().go(), 1)
        self.assertIn('not a git checkout', self.posted[0])

    def test_a_reference_into_documents_is_reported(self):
        (self.tools / '.venv/pyvenv.cfg').write_text('command = python -m venv /Users/x/Documents/GitHub/repo/.venv\n')
        self.assertEqual(self.refresh().go(), 1)
        self.assertIn('~/Documents', self.posted[0])

    def test_a_failed_comment_does_not_stop_the_run(self):
        (self.tools / '.venv/pyvenv.cfg').write_text('command = /Users/x/Documents/y\n')

        def broken(text):
            raise RuntimeError('offline')
        refresh = self.refresh()
        refresh.post = broken
        self.assertEqual(refresh.go(), 1)


if __name__ == '__main__':
    unittest.main()
