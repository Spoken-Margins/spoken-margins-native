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


def bash(command, cwd=REPO):
    return {'tool_name': 'Bash', 'tool_input': {'command': command}, 'cwd': cwd}


class LaneGuardTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.stream = {'SM_LANE_STATE_DIR': self.temporary.name}
        self.desk = {**self.stream, guard.TEST_DESK_ENV: guard.TEST_DESK_VALUE}

    def decide(self, event, environ=None, repos=(REPO,)):
        return guard.decide(event, list(repos), self.stream if environ is None else environ)

    def test_stream_session_cannot_touch_simulators(self):
        for command in ('xcrun simctl boot 31A5C797-9CE5-409F-9C65-4A8D4C339D44',
                        'xcrun simctl install booted App.app',
                        'xcrun simctl launch booted com.example',
                        'xcrun simctl erase 31A5C797-9CE5-409F-9C65-4A8D4C339D44',
                        'xcrun --sdk iphonesimulator simctl shutdown booted',
                        '/Applications/Xcode.app/Contents/Developer/usr/bin/simctl boot X',
                        'scripts/xcodebuild-lane -scheme SpokenMarginsApp -destination id=X test',
                        '.venv/bin/python scripts/verify-tests.py --plan app',
                        'python3 scripts/verify-tests.py --plan=adapters',
                        'bash scripts/smoke-simulator.sh',
                        '/usr/bin/python3 scripts/lane-runner.py --pr 1 --event-head a --merge-sha b --run-id 1',
                        'open -a Simulator',
                        'killall Simulator',
                        'cd /tmp && timeout 600 xcrun simctl boot X',
                        'FOO=1 caffeinate -i xcrun simctl boot X',
                        'env -u CLAUDECODE xcrun simctl boot X',
                        'timeout -s KILL 60 xcrun simctl boot X',
                        'bash -c "xcrun simctl boot X"',
                        'echo $(xcrun simctl boot X)',
                        'echo `xcrun simctl boot X`',
                        'git status; xcrun simctl boot X 2>&1 | tail -3',
                        # Shell syntax an agent would plausibly write (fresh-context review, M1).
                        "for d in $(xcrun simctl list devices booted | grep -oE '[0-9A-F-]{36}'); "
                        "do xcrun simctl shutdown $d; done",
                        'if ! xcrun simctl boot X; then echo failed; fi',
                        'while true; do xcrun simctl launch booted com.example; sleep 5; done',
                        '{ xcrun simctl boot X; }',
                        '! xcrun simctl boot X',
                        "bash -lc 'xcrun simctl boot X'",
                        'zsh -ec "scripts/xcodebuild-lane -scheme S test"',
                        'echo "booting $(xcrun simctl boot X)"',
                        'UDID="$(xcrun simctl create Temp com.apple.CoreSimulator.SimDeviceType.iPhone-17)"',
                        'echo "`xcrun simctl boot X`"'):
            with self.subTest(command=command):
                reason = self.decide(bash(command))
                self.assertIsNotNone(reason)
                self.assertIn('Only the Test Desk', reason)
                desk = self.decide(bash(command), self.desk)
                self.assertTrue(desk is None or 'scripts/lane-sim-boot' in desk, desk)

    def test_test_desk_may_touch_simulators(self):
        for command in ('xcrun simctl install booted App.app', '.venv/bin/python scripts/verify-tests.py --plan app',
                        'scripts/xcodebuild-lane -scheme S test-without-building', 'open -a Simulator',
                        'scripts/lane-sim-boot 31A5C797-9CE5-409F-9C65-4A8D4C339D44'):
            with self.subTest(command=command):
                self.assertIsNone(self.decide(bash(command), self.desk))

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
                        "git commit -m 'Block `xcrun simctl boot` in streams'",
                        "echo '$(xcrun simctl boot X)'",
                        'command -v xcodebuild', 'xcodebuild -h',
                        'git show HEAD:scripts/lane-runner.py > scripts/lane-runner.py',
                        'cat notes.txt >> scripts/smoke-simulator.sh 2>&1',
                        'python -u'):
            with self.subTest(command=command):
                self.assertIsNone(self.decide(bash(command)))

    def test_the_desk_boots_through_the_boot_lock_and_streams_cannot_boot_at_all(self):
        self.assertIn('scripts/lane-sim-boot', self.decide(bash('xcrun simctl boot X'), self.desk))
        self.assertIn('Only the Test Desk', self.decide(bash('scripts/lane-sim-boot X')))
        # A branch from before the helper existed isn't redirected (nothing to redirect to).
        main, _ = self.repository_with_test_desk()
        self.assertIsNone(self.decide(bash('xcrun simctl boot X', cwd=main), self.desk, repos=(main,)))

    def test_a_device_marked_unsafe_can_only_be_deleted_or_shut_down(self):
        unsafe = '942055FF-57EF-48BC-BE5F-D3E014763E2B'
        with open(os.path.join(self.temporary.name, 'unsafe-simulators.json'), 'w') as handle:
            json.dump({unsafe: {'reason': 'simctl boot failed: Invalid argument'}}, handle)
        for command in (f'xcrun simctl boot {unsafe}', f'scripts/lane-sim-boot {unsafe}',
                        f'scripts/xcodebuild-lane -scheme S -destination id={unsafe} test',
                        f'.venv/bin/python scripts/verify-tests.py --plan app --device {unsafe}',
                        f'xcrun simctl install {unsafe} App.app'):
            with self.subTest(command=command):
                self.assertIn('is marked unsafe', self.decide(bash(command), self.desk))
        for command in (f'xcrun simctl delete {unsafe}', f'xcrun simctl shutdown {unsafe}'):
            with self.subTest(command=command):
                self.assertIsNone(self.decide(bash(command), self.desk))
        self.assertIsNone(self.decide(bash('xcrun simctl install booted App.app'), self.desk))

    def test_raw_xcodebuild_builds_go_through_the_wrapper_even_for_the_desk(self):
        for environ in (self.stream, self.desk):
            for command in ('xcodebuild -project SpokenMarginsNative.xcodeproj -scheme SpokenMarginsApp build',
                            'xcrun xcodebuild -scheme S archive',
                            'if ! xcodebuild -scheme S build; then echo failed; fi',
                            'cd App && xcodebuild -scheme S -destination "generic/platform=iOS" build'):
                with self.subTest(command=command, desk=environ is self.desk):
                    self.assertIn('scripts/xcodebuild-lane', self.decide(bash(command), environ))

    def test_branches_without_the_wrapper_can_still_build(self):
        # The guard is installed user-wide before every branch has scripts/xcodebuild-lane.
        main, _ = self.repository_with_test_desk()
        command = bash('xcodebuild -scheme S build', cwd=main)
        self.assertIsNone(self.decide(command, repos=(main,)))
        os.makedirs(os.path.join(main, 'scripts'))
        open(os.path.join(main, 'scripts', 'xcodebuild-lane'), 'w').close()
        self.assertIn('scripts/xcodebuild-lane', self.decide(command, repos=(main,)))
        self.assertIn('Only the Test Desk', self.decide(bash('xcodebuild -scheme S test', cwd=main), repos=(main,)))

    def test_every_device_and_physical_device_changes_are_blocked_even_for_the_desk(self):
        for command in ('xcrun simctl erase all', 'xcrun simctl shutdown all', 'xcrun simctl delete unavailable',
                        'xcrun devicectl device install app --device X App.app',
                        'xcrun devicectl device process launch --device X com.example'):
            for environ in (self.stream, self.desk):
                with self.subTest(command=command, desk=environ is self.desk):
                    self.assertIn('in every session', self.decide(bash(command), environ))
        self.assertIsNone(self.decide(bash('xcrun simctl shutdown 31A5C797-9CE5-409F-9C65-4A8D4C339D44'), self.desk))

    def test_other_tools_that_run_shell_commands_are_guarded(self):
        # The terminal tool runs in its own cwd; Monitor runs in the session's.
        with tempfile.TemporaryDirectory() as other:
            terminal = {'tool_name': 'mcp__terminal__run_in_terminal', 'cwd': other,
                        'tool_input': {'command': '.venv/bin/python scripts/verify-tests.py --plan app', 'cwd': REPO}}
            self.assertIn('Only the Test Desk', self.decide(terminal))
            elsewhere = {**terminal, 'tool_input': {**terminal['tool_input'], 'cwd': other}}
            self.assertIsNone(self.decide(elsewhere))
        monitor = {'tool_name': 'Monitor', 'cwd': REPO,
                   'tool_input': {'command': 'xcodebuild -scheme S build 2>&1 | grep --line-buffered error'}}
        self.assertIn('scripts/xcodebuild-lane', self.decide(monitor))

    def test_simulator_mcp_tools_are_desk_only(self):
        event = {'tool_name': 'mcp__Claude_Code_iOS_Simulator__control', 'tool_input': {'action': 'launch'},
                 'cwd': REPO}
        self.assertIn('Only the Test Desk', self.decide(event))
        self.assertIsNone(self.decide(event, self.desk))

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
        environment = {k: v for k, v in os.environ.items() if k not in (guard.TEST_DESK_ENV, 'CLAUDE_PROJECT_DIR')}
        environment['SM_LANE_STATE_DIR'] = self.temporary.name

        def run(event, env):
            return subprocess.run([python, str(SCRIPTS / 'lane_guard.py'), '--repo', REPO],
                                  input=json.dumps(event), capture_output=True, text=True, env=env)

        blocked = run(bash('xcrun simctl boot X'), environment)
        self.assertEqual(blocked.returncode, 2, blocked.stderr)
        self.assertIn('Only the Test Desk', blocked.stderr)
        allowed = run(bash('xcrun simctl install booted X'), {**environment, guard.TEST_DESK_ENV: guard.TEST_DESK_VALUE})
        self.assertEqual((allowed.returncode, allowed.stderr), (0, ''))
        broken = subprocess.run([python, str(SCRIPTS / 'lane_guard.py'), '--repo', REPO],
                                input='not json', capture_output=True, text=True, env=environment)
        self.assertEqual(broken.returncode, 0)
        self.assertIn('allowed the call', broken.stderr)

    def repository_with_test_desk(self):
        """A throwaway repository and its <repo>-test-desk worktree, like the Mac's layout."""
        parent = os.path.realpath(self.temporary.name)
        main, desk = os.path.join(parent, 'repo'), os.path.join(parent, 'repo-test-desk')
        git = ['git', '-c', 'user.name=t', '-c', 'user.email=t@example.com']
        subprocess.run(git + ['init', '-q', main], check=True)
        subprocess.run(git + ['-C', main, 'commit', '-q', '--allow-empty', '-m', 'start'], check=True)
        subprocess.run(git + ['-C', main, 'worktree', 'add', '-q', '--detach', desk], check=True)
        return main, desk

    def test_a_session_opened_on_the_test_desk_folder_is_the_test_desk(self):
        main, desk = self.repository_with_test_desk()
        event = bash('xcrun simctl boot X', cwd=desk)
        self.assertIsNone(self.decide(event, {**self.stream, 'CLAUDE_PROJECT_DIR': desk}, repos=(main,)))
        # Without CLAUDE_PROJECT_DIR, the transcript's project folder name identifies the session.
        transcript = f'/Users/x/.claude/projects/{guard.project_key(desk)}/session.jsonl'
        self.assertIsNone(self.decide({**event, 'transcript_path': transcript}, repos=(main,)))

    def test_changing_directory_into_the_test_desk_folder_does_not_make_a_test_desk(self):
        main, desk = self.repository_with_test_desk()
        event = bash('xcrun simctl boot X', cwd=desk)
        self.assertIsNotNone(self.decide(event, {**self.stream, 'CLAUDE_PROJECT_DIR': main}, repos=(main,)))
        transcript = f'/Users/x/.claude/projects/{guard.project_key(main)}/session.jsonl'
        self.assertIsNotNone(self.decide({**event, 'transcript_path': transcript}, repos=(main,)))

    def test_guarded_calls_are_logged_and_ordinary_ones_are_not(self):
        self.decide(bash('xcrun simctl boot X'))
        self.decide(bash('xcrun simctl install booted X'), self.desk)
        self.decide(bash('ls -la'))
        lines = [json.loads(line) for line in open(os.path.join(self.temporary.name, 'guard.log'))]
        self.assertEqual([(l['decision'], l['test_desk']) for l in lines],
                         [('blocked', None), ('allowed', guard.TEST_DESK_ENV)])


class HeredocTests(unittest.TestCase):
    def test_heredoc_body_is_not_a_command_but_the_next_line_is(self):
        command = "cat <<EOF > notes.txt\nxcrun simctl boot X\nEOF\nxcrun simctl boot Y"
        self.assertEqual(guard.classify_command(command), [(guard.SIM, 'simctl boot'), (guard.BOOT, 'raw simctl boot')])


if __name__ == '__main__':
    unittest.main()
