import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
import context_handoff_hook as hook  # noqa: E402

DAY = 24 * 3600


def touch(path, age_days):
    Path(path).write_text('1')
    stamp = time.time() - age_days * DAY
    os.utime(path, (stamp, stamp))


class PruneStateTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.state = temporary.name

    def names(self):
        return sorted(os.listdir(self.state))

    def test_old_session_files_go_and_recent_ones_stay(self):
        touch(f'{self.state}/old-session', 30)
        touch(f'{self.state}/kind-old-session', 8)
        touch(f'{self.state}/week-edge', 6)
        touch(f'{self.state}/today', 0)
        self.assertEqual(hook.prune_state(self.state), 2)
        self.assertEqual(self.names(), ['.pruned', 'today', 'week-edge'])

    def test_it_runs_once_a_day(self):
        touch(f'{self.state}/old-session', 30)
        self.assertEqual(hook.prune_state(self.state), 1)
        touch(f'{self.state}/another-old-session', 30)
        self.assertEqual(hook.prune_state(self.state), 0, 'the marker is under a day old')
        self.assertIn('another-old-session', self.names())
        touch(f'{self.state}/.pruned', 2)
        self.assertEqual(hook.prune_state(self.state), 1, 'a day later it runs again')

    def test_marker_folders_and_links_are_left_alone(self):
        os.mkdir(f'{self.state}/folder')
        os.utime(f'{self.state}/folder', (0, 0))
        target = Path(self.state).parent / 'prune-target-outside'
        touch(target, 30)
        self.addCleanup(lambda: target.unlink(missing_ok=True))
        os.symlink(target, f'{self.state}/link')
        touch(f'{self.state}/.hidden', 30)
        self.assertEqual(hook.prune_state(self.state), 0)
        self.assertTrue(target.exists())
        self.assertEqual(self.names(), ['.hidden', '.pruned', 'folder', 'link'])

    def test_a_missing_folder_is_not_an_error(self):
        self.assertEqual(hook.prune_state(os.path.join(self.state, 'missing')), 0)


class HookRunTests(unittest.TestCase):
    """The hook as Claude Code runs it: JSON on stdin, JSON on stdout, state under $HOME."""

    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.home = temporary.name
        self.state = Path(self.home, '.claude/hooks/state/context-handoff')
        self.transcript = Path(self.home, 'spoken-margins-native-session.jsonl')

    def run_hook(self, context_tokens, name='PostToolUse', session='s1', tool='Read'):
        self.transcript.write_text(json.dumps({'type': 'assistant',
                                               'message': {'usage': {'input_tokens': context_tokens}}}) + '\n')
        event = {'hook_event_name': name, 'session_id': session, 'tool_name': tool,
                 'transcript_path': str(self.transcript), 'cwd': '/x/spoken-margins-native'}
        done = subprocess.run([sys.executable, str(SCRIPTS / 'context_handoff_hook.py')], input=json.dumps(event),
                              capture_output=True, text=True, env={**os.environ, 'HOME': self.home}, check=True)
        return json.loads(done.stdout) if done.stdout.strip() else None

    def test_it_still_nudges_at_the_line_and_stays_quiet_below_it(self):
        self.assertIsNone(self.run_hook(100_000))
        out = self.run_hook(260_000)
        self.assertIn('hand-off line', out['hookSpecificOutput']['additionalContext'])
        self.assertIsNone(self.run_hook(265_000), 'once, then every further 20k')

    def test_it_still_denies_at_the_backstop(self):
        out = self.run_hook(310_000, name='PreToolUse', tool='WebSearch')
        self.assertEqual(out['hookSpecificOutput']['permissionDecision'], 'deny')
        self.assertIsNone(self.run_hook(310_000, name='PreToolUse', tool='Read'), 'reading stays allowed')

    def test_writing_state_prunes_the_stale_files_beside_it(self):
        self.state.mkdir(parents=True)
        touch(self.state / 'ended-session', 20)
        touch(self.state / 'kind-ended-session', 20)
        self.run_hook(260_000)
        self.assertEqual(sorted(os.listdir(self.state)), ['.pruned', 'kind-s1', 's1'])


if __name__ == '__main__':
    unittest.main()
