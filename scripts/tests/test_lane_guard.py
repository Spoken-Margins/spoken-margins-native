import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
import lane_guard as guard  # noqa: E402

REPO = str(SCRIPTS.parent)
STREAM = {}
DESK = {guard.TEST_DESK_ENV: guard.TEST_DESK_VALUE}


def bash(command, cwd=REPO):
    return {'tool_name': 'Bash', 'tool_input': {'command': command}, 'cwd': cwd}


class LaneGuardTests(unittest.TestCase):
    def decide(self, event, environ=STREAM, repos=(REPO,)):
        return guard.decide(event, list(repos), environ)

    def test_stream_session_cannot_touch_simulators(self):
        for command in ('xcrun simctl boot 31A5C797-9CE5-409F-9C65-4A8D4C339D44',
                        'xcrun simctl install booted App.app',
                        'xcrun simctl launch booted com.example',
                        'xcrun simctl erase all',
                        'xcrun --sdk iphonesimulator simctl shutdown all',
                        '/Applications/Xcode.app/Contents/Developer/usr/bin/simctl boot X',
                        'xcrun devicectl device install app --device X App.app',
                        'scripts/xcodebuild-lane -scheme SpokenMarginsApp -destination id=X test',
                        '.venv/bin/python scripts/verify-tests.py --plan app',
                        'python3 scripts/verify-tests.py --plan=adapters',
                        'bash scripts/smoke-simulator.sh',
                        'open -a Simulator',
                        'killall Simulator',
                        'cd /tmp && timeout 600 xcrun simctl boot X',
                        'FOO=1 caffeinate -i xcrun simctl boot X',
                        'bash -c "xcrun simctl boot X"',
                        'echo $(xcrun simctl boot X)',
                        'echo `xcrun simctl boot X`',
                        'git status; xcrun simctl boot X 2>&1 | tail -3'):
            with self.subTest(command=command):
                reason = self.decide(bash(command))
                self.assertIsNotNone(reason)
                self.assertIn('Only the Test Desk', reason)
                self.assertIsNone(self.decide(bash(command), DESK))

    def test_test_desk_may_touch_simulators(self):
        for command in ('xcrun simctl boot X', '.venv/bin/python scripts/verify-tests.py --plan app',
                        'scripts/xcodebuild-lane -scheme S test-without-building', 'open -a Simulator'):
            with self.subTest(command=command):
                self.assertIsNone(self.decide(bash(command), DESK))

    def test_host_work_and_read_only_queries_pass(self):
        for command in ('xcrun simctl list devices available',
                        'xcrun simctl help', 'xcrun devicectl list devices',
                        'xcrun --find xcodebuild', 'xcodebuild -version',
                        'xcodebuild -list -project SpokenMarginsNative.xcodeproj',
                        'PATH="/usr/bin:/bin:$PATH" xcodebuild -exportArchive -archivePath a -exportPath b',
                        '.venv/bin/python scripts/verify-tests.py --plan fast',
                        '.venv/bin/python scripts/verify-tests.py',
                        '.venv/bin/python scripts/verify-tests.py --plan app --list',
                        'scripts/xcodebuild-lane -scheme SpokenMarginsApp build-for-testing',
                        'swift test --package-path Packages/SessionKit',
                        'grep -rn "xcrun simctl boot" scripts/',
                        'git commit -m "Block xcrun simctl boot in stream sessions"',
                        "git commit -F - <<'EOF'\nGuard the lane\n\nxcrun simctl boot is blocked.\nxcodebuild test too.\nEOF",
                        'python -u'):
            with self.subTest(command=command):
                self.assertIsNone(self.decide(bash(command)))

    def test_raw_xcodebuild_builds_go_through_the_wrapper_even_for_the_desk(self):
        for environ in (STREAM, DESK):
            for command in ('xcodebuild -project SpokenMarginsNative.xcodeproj -scheme SpokenMarginsApp build',
                            'xcrun xcodebuild -scheme S archive',
                            'cd App && xcodebuild -scheme S -destination "generic/platform=iOS" build'):
                with self.subTest(command=command, desk=bool(environ)):
                    self.assertIn('scripts/xcodebuild-lane', self.decide(bash(command), environ))

    def test_simulator_mcp_tools_are_desk_only(self):
        event = {'tool_name': 'mcp__Claude_Code_iOS_Simulator__control', 'tool_input': {'action': 'launch'},
                 'cwd': REPO}
        self.assertIn('Only the Test Desk', self.decide(event))
        self.assertIsNone(self.decide(event, DESK))

    def test_other_projects_are_never_blocked(self):
        with tempfile.TemporaryDirectory() as other:
            subprocess.run(['git', 'init', '-q', other], check=True)
            for command in ('xcrun simctl boot X', 'xcodebuild -scheme Other build', 'xcodebuild test'):
                with self.subTest(command=command):
                    self.assertIsNone(self.decide(bash(command, cwd=other)))

    def test_worktrees_outside_the_repository_folder_are_guarded(self):
        # Streams have made worktrees in session scratch folders, outside the checkout.
        with tempfile.TemporaryDirectory() as parent:
            main, worktree = os.path.join(parent, 'main'), os.path.join(parent, 'elsewhere', 'wt')
            git = ['git', '-c', 'user.name=t', '-c', 'user.email=t@example.com']
            subprocess.run(git + ['init', '-q', main], check=True)
            subprocess.run(git + ['-C', main, 'commit', '-q', '--allow-empty', '-m', 'start'], check=True)
            subprocess.run(git + ['-C', main, 'worktree', 'add', '-q', '--detach', worktree], check=True)
            self.assertIsNotNone(self.decide(bash('xcrun simctl boot X', cwd=worktree), repos=(main,)))
            self.assertIsNone(self.decide(bash('xcrun simctl boot X', cwd=parent), repos=(main,)))

    def test_a_command_naming_the_repository_is_guarded_from_anywhere(self):
        with tempfile.TemporaryDirectory() as other:
            self.assertIsNotNone(self.decide(bash(f'cd {REPO} && xcrun simctl boot X', cwd=other)))

    def test_hook_protocol_exit_codes(self):
        # Runs the file the way Claude Code does: JSON on stdin, exit 2 and stderr to block.
        # Also proves it runs under the system Python 3.9 that the installed hook uses.
        python = '/usr/bin/python3' if Path('/usr/bin/python3').exists() else sys.executable
        environment = {k: v for k, v in os.environ.items() if k != guard.TEST_DESK_ENV}

        def run(event, env):
            return subprocess.run([python, str(SCRIPTS / 'lane_guard.py'), '--repo', REPO],
                                  input=json.dumps(event), capture_output=True, text=True, env=env)

        blocked = run(bash('xcrun simctl boot X'), environment)
        self.assertEqual(blocked.returncode, 2, blocked.stderr)
        self.assertIn('Only the Test Desk', blocked.stderr)
        allowed = run(bash('xcrun simctl boot X'), {**environment, **DESK})
        self.assertEqual((allowed.returncode, allowed.stderr), (0, ''))
        broken = subprocess.run([python, str(SCRIPTS / 'lane_guard.py'), '--repo', REPO],
                                input='not json', capture_output=True, text=True, env=environment)
        self.assertEqual(broken.returncode, 0)
        self.assertIn('allowed the call', broken.stderr)


class HeredocTests(unittest.TestCase):
    def test_heredoc_body_is_not_a_command_but_the_next_line_is(self):
        command = "cat <<EOF > notes.txt\nxcrun simctl boot X\nEOF\nxcrun simctl boot Y"
        self.assertEqual(guard.classify_command(command), [(guard.SIM, 'simctl boot')])


if __name__ == '__main__':
    unittest.main()
