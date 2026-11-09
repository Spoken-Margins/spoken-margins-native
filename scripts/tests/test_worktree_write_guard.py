import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
import worktree_write_guard as guard  # noqa: E402


class WorktreeWriteGuardTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = os.path.realpath(temporary.name)
        self.main = os.path.join(self.root, 'repo')
        self.mine = os.path.join(self.main, '.claude/worktrees/mine')
        self.other = os.path.join(self.main, '.claude/worktrees/other')
        self.outside = os.path.join(self.root, 'scratchpad')
        os.makedirs(self.outside)
        for name, path in (('mine', self.mine), ('other', self.other)):
            os.makedirs(path)
            record = os.path.join(self.main, '.git/worktrees', name)
            os.makedirs(record)
            Path(record, 'gitdir').write_text(f'{path}/.git\n')

    def refused(self, command, cwd=None, transcript=''):
        verdict = guard.decide(command, cwd or self.mine, self.main, transcript)
        return verdict[1] if verdict else None

    def assert_refused(self, command, path, **kwargs):
        self.assertEqual(self.refused(command, **kwargs), path, command)

    def assert_allowed(self, command, **kwargs):
        self.assertIsNone(self.refused(command, **kwargs), command)

    def test_each_way_of_writing_into_another_worktree_is_refused(self):
        target = f'{self.other}/a.txt'
        for command in (f'echo hi > {target}', f'echo hi >> {target}', f'echo hi >| {target}', f'echo hi | tee {target}',
                        f'cp a.txt {target}', f'cp -R a {target}', f'mv a.txt {target}', f'mv {target} b.txt',
                        f'install a {target}', f'ln -s a {target}', f'rsync -a a/ {target}', f'truncate -s 0 {target}',
                        f'dd if=/dev/zero of={target}', f'rm -f {target}', f'touch {target}',
                        f"sed -i '' 's/a/b/' {target}", f"sed -i.bak 's/a/b/' {target}", f"sed -i -e 's/a/b/' {target}",
                        f"perl -pi -e 's/a/b/' {target}", f"bash -c 'echo hi > {target}'", f"zsh -lc \"rm {target}\"",
                        f'sudo tee {target}', f'A=1 tee {target}', f'for f in x; do cp $f {target}; done',
                        f'if true; then touch {target}; fi', f'echo a && echo b; cp a {target}'):
            self.assert_refused(command, target)

    def test_a_heredoc_into_another_worktree_is_refused_even_with_an_apostrophe_in_its_body(self):
        target = f'{self.other}/a.py'
        self.assert_refused(f"cat > {target} <<'EOF'\nit's text, with a stray quote\nEOF", target)

    def test_a_heredoc_body_is_text_not_commands(self):
        self.assert_allowed(f"cat > notes.md <<'EOF'\nrm -rf {self.other}/x\necho hi > {self.main}/y\nEOF\n")
        self.assert_allowed(f"cat <<-EOF > notes.md\n\ttouch {self.other}/x\n\tEOF\necho done")

    def test_a_write_after_a_heredoc_is_still_seen(self):
        target = f'{self.other}/b'
        self.assert_refused(f"cat > a <<E\nbody\nE\ntouch {target}", target)

    def test_a_comment_line_is_not_a_command(self):
        self.assert_allowed(f'# then touch {self.other}/x\necho hi')

    def test_the_main_checkout_is_refused_too(self):
        self.assert_refused(f'echo hi > {self.main}/error.log', f'{self.main}/error.log')
        self.assert_refused(f'cp a {self.main}/.git/config', f'{self.main}/.git/config')

    def test_the_sessions_own_worktree_is_allowed(self):
        for command in ('echo hi > a.txt', f'echo hi > {self.mine}/a.txt', "sed -i '' 's/a/b/' scripts/x.py",
                        f'cp {self.other}/a.txt copied.txt', f'cp {self.main}/a.txt {self.mine}/b.txt',
                        f'ln -s {self.main}/.venv .venv', f'rm {self.mine}/a', 'rm -rf tmp'):
            self.assert_allowed(command)

    def test_the_allowed_folders_of_any_checkout_are_allowed(self):
        for folder in guard.ALLOWED_FOLDERS:
            self.assert_allowed(f'echo hi > {self.main}/{folder}/x/a.txt')
            self.assert_allowed(f'rm -rf {self.other}/{folder}')

    def test_an_allowed_name_deeper_in_the_tree_earns_nothing(self):
        self.assert_refused(f'touch {self.other}/src/build/a', f'{self.other}/src/build/a')

    def test_anything_outside_the_repository_is_allowed(self):
        for command in (f'echo hi > {self.outside}/a', 'echo hi > /tmp/a', 'echo hi > /dev/null', 'ls 2>/dev/null',
                        'ls 2>&1 | tee /tmp/out', 'echo hi >&2', 'touch ~/.claude/projects/x/memory/a.md'):
            self.assert_allowed(command)

    def test_redirecting_a_stream_does_not_hide_the_copys_destination(self):
        target = f'{self.other}/a'
        self.assert_refused(f'cp x {target} 2> /dev/null', target)
        self.assert_refused(f'cp x {target} 2>/dev/null', target)

    def test_cd_is_followed_within_the_command(self):
        self.assert_refused(f'cd {self.other} && touch a', f'{self.other}/a')
        self.assert_refused('cd ../other; echo hi > b', f'{self.other}/b')
        self.assert_allowed(f'cd {self.other} && ls && cd {self.mine} && touch a')

    def test_a_variable_set_in_the_command_is_followed(self):
        self.assert_refused(f'T={self.other}; touch "$T/a"', f'{self.other}/a')
        self.assert_refused(f'T={self.other}; cp x ${{T}}/a', f'{self.other}/a')

    def test_a_path_only_known_at_run_time_is_let_through(self):
        self.assert_allowed('touch "$UNKNOWN/a"')
        self.assert_allowed('touch $(git rev-parse --show-toplevel)/a')
        self.assert_allowed(f'T=$(pwd); touch $T/a')

    def test_a_symlink_into_another_checkout_counts_as_that_checkout(self):
        os.symlink(self.other, os.path.join(self.mine, 'link'))
        self.assert_refused('touch link/a', f'{self.other}/a')

    def test_reading_commands_are_not_writes(self):
        for command in (f'cat {self.other}/a', f'grep x {self.main}/a', f"sed -n 1,5p {self.other}/a",
                        f'git -C {self.other} status', f'diff {self.other}/a {self.main}/a', f"sed 's/a/b/' {self.main}/a"):
            self.assert_allowed(command)

    def test_the_transcript_says_whose_session_it_is_after_the_shell_has_left(self):
        transcript = f'/Users/x/.claude/projects/{guard.project_folder_name(self.mine)}/abc.jsonl'
        self.assert_refused('touch a', f'{self.main}/a', cwd=self.main, transcript=transcript)
        subagent = f'/Users/x/.claude/projects/{guard.project_folder_name(self.mine)}/abc/subagents/agent-1.jsonl'
        self.assert_refused('touch a', f'{self.main}/a', cwd=self.main, transcript=subagent)

    def test_a_helper_in_its_own_worktree_writes_there_though_its_transcript_is_under_its_parent(self):
        transcript = f'/Users/x/.claude/projects/{guard.project_folder_name(self.mine)}/abc/subagents/agent-1.jsonl'
        self.assert_allowed(f'touch {self.other}/a', cwd=self.other, transcript=transcript)
        self.assert_refused(f'touch {self.mine}/a', f'{self.mine}/a', cwd=self.other, transcript=transcript)

    def test_a_shell_outside_the_repository_still_belongs_to_the_session_that_started_it(self):
        transcript = f'/Users/x/.claude/projects/{guard.project_folder_name(self.mine)}/abc.jsonl'
        self.assert_refused(f'touch {self.other}/a', f'{self.other}/a', cwd=self.outside, transcript=transcript)

    def test_a_session_in_the_main_checkout_is_not_restricted(self):
        self.assert_allowed(f'touch {self.other}/a', cwd=self.main)

    def test_another_repository_is_left_alone(self):
        self.assert_allowed(f'touch {self.main}/a', cwd=self.outside)

    def run_hook(self, event, home):
        return subprocess.run([sys.executable, str(SCRIPTS / 'worktree_write_guard.py'), '--repo', self.main],
                              input=json.dumps(event) if isinstance(event, dict) else event,
                              capture_output=True, text=True, env={**os.environ, 'HOME': home})

    def test_a_refusal_exits_2_says_why_and_is_logged(self):
        event = {'tool_input': {'command': f'touch {self.other}/a'}, 'cwd': self.mine, 'transcript_path': ''}
        result = self.run_hook(event, self.outside)
        self.assertEqual(result.returncode, 2)
        self.assertIn(f'{self.other}/a', result.stderr)
        self.assertIn('your own worktree', result.stderr)
        entry = json.loads(Path(self.outside, '.claude/hooks/state/worktree-write-guard.jsonl').read_text())
        self.assertEqual((entry['event'], entry['path']), ('refused', f'{self.other}/a'))

    def test_an_allowed_command_logs_nothing(self):
        result = self.run_hook({'tool_input': {'command': 'touch a'}, 'cwd': self.mine}, self.outside)
        self.assertEqual(result.returncode, 0)
        self.assertFalse(Path(self.outside, '.claude/hooks/state/worktree-write-guard.jsonl').exists())

    def test_a_command_it_cannot_read_fails_open_and_leaves_a_mark(self):
        result = self.run_hook({'tool_input': {'command': "echo 'unbalanced"}, 'cwd': self.mine}, self.outside)
        self.assertEqual(result.returncode, 0)
        entry = json.loads(Path(self.outside, '.claude/hooks/state/worktree-write-guard.jsonl').read_text())
        self.assertEqual(entry['event'], 'unreadable')

    def test_a_garbled_event_fails_open(self):
        self.assertEqual(self.run_hook('not json', self.outside).returncode, 0)


if __name__ == '__main__':
    unittest.main()
