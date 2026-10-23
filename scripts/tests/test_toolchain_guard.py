import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
import toolchain_guard as guard  # noqa: E402


class ToolchainGuardTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = os.path.realpath(temporary.name)
        self.brew = os.path.join(self.root, 'fake-homebrew')  # stands in for /opt/homebrew
        os.makedirs(os.path.join(self.brew, 'Cellar/python/bin'))
        os.makedirs(os.path.join(self.brew, 'bin'))
        self.python = os.path.join(self.brew, 'Cellar/python/bin/python3.14')
        Path(self.python).write_text('real python')
        self.work = os.path.join(self.root, 'work')
        os.makedirs(os.path.join(self.work, '.venv/bin'))
        os.symlink(self.python, os.path.join(self.work, '.venv/bin/python3.14'))
        self.roots = guard.PROTECTED_ROOTS + (self.brew,)

    def decide(self, command):
        return guard.decide(command, self.work, self.roots)

    def test_blocked(self):
        for command, path in (
                ('cp /bin/sleep .venv/bin/python3.14', self.python),
                (f'cp /bin/sleep {self.work}/.venv/bin/python3.14', self.python),
                ('cp -f /bin/sleep .venv/bin/newtool', '.venv/bin/newtool'),
                (f'cp /bin/sleep {self.brew}/bin/sleep', self.brew),
                ('mv x /opt/homebrew/bin/y', '/opt/homebrew/bin/y'),
                ('mv /opt/homebrew/bin/brew /tmp/x', '/opt/homebrew/bin/brew'),
                ('echo > /usr/bin/z', '/usr/bin/z'),
                ('echo hi >> /bin/z', '/bin/z'),
                ('ln -sf a /opt/homebrew/opt/python', '/opt/homebrew/opt/python'),
                ('install -m 755 x /usr/local/Cellar/foo/bin/foo', '/usr/local/Cellar/foo'),
                ('echo x | tee /usr/sbin/q', '/usr/sbin/q'),
                ('cp -t /Library/Developer/CommandLineTools x', '/Library/Developer/CommandLineTools'),
                ('cp x /Applications/Xcode.app/Contents/y', '/Applications/Xcode.app'),
                ('cp x /Applications/Xcode-beta.app/y', '/Applications/Xcode-beta.app'),
                ('echo hi > .venv/lib/python3.14/site.py', '.venv/lib'),
                ('cd /tmp && cp a /opt/homebrew/bin/b', '/opt/homebrew/bin/b'),
                ('bash -c "cp a /opt/homebrew/bin/b"', '/opt/homebrew/bin/b'),
                ('FOO=1 sudo cp a /usr/bin/b', '/usr/bin/b'),
                ('cp /bin/sleep .venv/bin', '.venv/bin')):
            with self.subTest(command=command):
                reason = self.decide(command)
                self.assertIsNotNone(reason)
                self.assertIn(path, reason)
                self.assertIn('Toolchain paths are read-only for agents.', reason)

    def test_allowed(self):
        for command in ('cp a $TMPDIR/x', f'cp a {self.root}/new', '.venv/bin/python -m pip install foo',
                        'cat /opt/homebrew/bin/brew', 'brew reinstall python@3.14', 'ls -la /usr/bin',
                        'cp /bin/sleep ./stand-in', 'cp /usr/bin/env /tmp/x', '.venv/bin/python3.14 -V',
                        'echo hi > out.txt', 'echo hi 2>&1 | tee log.txt', 'ln -s /usr/bin/true ./true',
                        'git commit -m "cp x /usr/bin/y"', 'echo "cp a /usr/bin/b"', 'cp a /binary/x'):
            with self.subTest(command=command):
                self.assertIsNone(self.decide(command))

    def test_hook_exit_codes(self):
        def run(stdin):
            return subprocess.run([sys.executable, str(SCRIPTS / 'toolchain_guard.py')], input=stdin,
                                  text=True, capture_output=True)

        def event(command):
            return json.dumps({'tool_name': 'Bash', 'tool_input': {'command': command}, 'cwd': self.work})
        blocked = run(event('echo > /usr/bin/z'))
        self.assertEqual(blocked.returncode, 2)
        self.assertIn('/usr/bin/z', blocked.stderr)
        self.assertEqual(run(event('ls /usr/bin')).returncode, 0)
        self.assertEqual(run('not json').returncode, 0)


if __name__ == '__main__':
    unittest.main()
