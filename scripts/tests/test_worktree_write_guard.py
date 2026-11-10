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

    def test_an_inline_comment_is_not_a_command(self):
        self.assert_allowed(f'ls  # then > {self.other}/x')
        self.assert_allowed(f'git status  # done; rm {self.other}/x\necho hi')
        target = f'{self.other}/a'
        for command in (f'echo a#b > {target}', f'echo ${{#x}} > {target}', f'echo "# x" > {target}',
                        f"echo '#' > {target}", f'echo hi # note\ntouch {target}', f"echo 'it''s # not' > {target}",
                        f'echo \\# > {target}'):
            self.assert_refused(command, target)

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
        for command in (f'cp x {target} 2>&1', f'cp x {target} >/dev/null 2>&1', f'install x {target} 2>&1',
                        f'ln -s x {target} 2>&1', f'rsync -a x {target} >&2', f'cp x {target} 3>&-', f'echo hi >& {target}'):
            self.assert_refused(command, target)

    def test_a_duplicated_stream_is_never_taken_for_a_file(self):
        for command in (f'cd {self.main} && rm -f /tmp/x >/dev/null 2>&1', f'cd {self.main} && cp docs/a.md /tmp/a.md 2>&1',
                        f'cd {self.main} && rm -f /tmp/x 2>&1 <&3', f'cd {self.main} && touch /tmp/x 3>&-'):
            self.assert_allowed(command)

    def test_an_input_redirect_does_not_hide_the_copys_destination(self):
        target = f'{self.other}/b'
        for command in (f'cp x {target} < /dev/null', f'cp x {target} </dev/null', f'mv x {target} 0< /dev/null',
                        f'install x {target} <<< ""', f'ln -s x {target} <<< y', f"rsync -a x {target} <<'EOF'\nbody\nEOF",
                        f'cp x {target} <<-EOF\n\tbody\n\tEOF', f'cp x {target} {{fd}}>/dev/null',
                        f'cp x {target} {{fd}}>&-'):
            self.assert_refused(command, target)

    def test_an_input_redirect_or_heredoc_word_is_never_taken_for_a_file(self):
        for command in (f"cd {self.main} && tee /tmp/n <<'EOF'\nbody\nEOF", f'cd {self.main} && rm -f /tmp/x < /dev/null',
                        f'cd {self.main} && touch /tmp/x <<< ""', f'cd {self.main} && tee /tmp/n <<-EOF\n\tbody\n\tEOF',
                        f'cd {self.main} && touch /tmp/x 0</dev/null'):
            self.assert_allowed(command)

    def test_a_file_opened_read_write_is_a_write(self):
        self.assert_refused(f'exec 3<> {self.other}/a', f'{self.other}/a')
        self.assert_refused(f'cat 0<>{self.other}/a', f'{self.other}/a')

    def test_process_substitution_is_a_stream_not_a_file_and_its_commands_are_read(self):
        target = f'{self.other}/a'
        self.assert_refused(f'tee >(cat) {target}', target)
        self.assert_refused(f'tee >(wc -l) {target} < x', target)
        self.assert_refused(f'diff <(ls) b; touch {target}', target)
        self.assert_refused(f'echo hi | tee >(cat > {target})', target)
        self.assert_allowed(f'cd {self.main} && tee >(cat) /tmp/x')
        self.assert_allowed(f'cd {self.main} && diff <(ls) <(ls -a) > /tmp/d')

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

    def test_removing_or_relinking_the_worktrees_own_links_into_the_main_checkout_is_allowed(self):
        os.makedirs(os.path.join(self.main, '.venv'))
        os.makedirs(os.path.join(self.main, 'Config'))
        Path(self.main, 'Config/Local.xcconfig').write_text('')
        os.makedirs(os.path.join(self.mine, 'Config'))
        os.symlink(os.path.join(self.main, '.venv'), os.path.join(self.mine, '.venv'))
        os.symlink(os.path.join(self.main, 'Config/Local.xcconfig'), os.path.join(self.mine, 'Config/Local.xcconfig'))
        for command in ('rm .venv', 'rm -f Config/Local.xcconfig', f'ln -sfn {self.main}/.venv .venv',
                        f'ln -sfh {self.main}/.venv .venv', f'ln -sf {self.main}/Config/Local.xcconfig Config/Local.xcconfig',
                        'mv .venv old-venv', f'unlink .venv'):
            self.assert_allowed(command)

    def test_a_command_that_writes_through_a_link_into_the_main_checkout_is_still_refused(self):
        os.makedirs(os.path.join(self.main, '.venv'))
        Path(self.main, 'Config.xcconfig').write_text('')
        os.symlink(os.path.join(self.main, '.venv'), os.path.join(self.mine, '.venv'))
        os.symlink(os.path.join(self.main, 'Config.xcconfig'), os.path.join(self.mine, 'Local.xcconfig'))
        self.assert_refused('echo x > Local.xcconfig', f'{self.main}/Config.xcconfig')
        self.assert_refused('cp a Local.xcconfig', f'{self.main}/Config.xcconfig')
        self.assert_refused('touch .venv/a', f'{self.main}/.venv/a')
        self.assert_refused('rm -rf .venv/', f'{self.main}/.venv')
        self.assert_refused('mv a .venv', f'{self.main}/.venv')
        self.assert_refused(f'ln -sf {self.main}/.venv .venv', f'{self.main}/.venv')  # no -n: ln writes inside it

    def test_the_folder_comes_back_after_a_subshell_popd_or_cd_dash(self):
        for command in (f'(cd {self.main} && git log -1) ; echo hi > notes.txt',
                        f'(cd {self.main}); echo hi > notes.txt',
                        f'pushd {self.main} >/dev/null; git status; popd >/dev/null; echo hi > notes.txt',
                        f'cd {self.main} && git log -1; cd -; touch x',
                        f'echo $(cd {self.main} && pwd) > notes.txt'):
            self.assert_allowed(command)
        self.assert_refused(f'(cd {self.main}; touch a)', f'{self.main}/a')
        self.assert_refused(f'(cd {self.mine}); cd {self.other}; touch a', f'{self.other}/a')

    def test_a_folder_it_cannot_work_out_lets_relative_writes_through_but_not_absolute_ones(self):
        self.assert_allowed(f'cd {self.main}; popd; touch x')
        self.assert_allowed('cd "$(git rev-parse --show-toplevel)"; touch x')
        self.assert_refused(f'cd "$UNKNOWN"; touch {self.other}/a', f'{self.other}/a')

    def test_a_bare_cd_goes_home(self):
        self.assert_allowed(f'cd {self.main}; cd; touch x')

    def test_pwd_follows_cd(self):
        self.assert_refused(f'cd {self.other}; touch "$PWD/a"', f'{self.other}/a')
        self.assert_allowed(f'cd {self.other}; cd {self.mine}; touch "$PWD/a"')

    def test_perl_and_sed_switches_that_only_contain_an_i_do_not_edit_in_place(self):
        for command in (f"perl -Mstrict -ne 'print if /x/' {self.other}/a.txt",
                        f"perl -MList::Util=sum -e 'print sum(1)' {self.main}/data.txt",
                        f"perl -Mwarnings -lne 'print' {self.main}/a", f"perl -V:intsize {self.main}/a", f"perl -I{self.main}/lib -e 1 {self.main}/a",
                        f"sed -E 's/i/j/' {self.other}/a", f"sed --posix 's/i/j/' {self.other}/a",
                        f"perl -CSDi -e 1 {self.other}/a", f"perl -Ci -ne 'print' {self.other}/a"):
            self.assert_allowed(command)

    def test_perl_and_sed_in_place_spellings_are_refused(self):
        target = f'{self.other}/a'
        for command in (f"perl -pi -e 's/a/b/' {target}", f"perl -i.bak -pe 's/a/b/' {target}",
                        f"perl -pie 's/a/b/' {target}", f"perl -Mstrict -pi -e 's/a/b/' {target}",
                        f"perl -0777 -pi -e 's/a/b/' {target}", f"perl -i -pe 's/a/b/' {target}",
                        f"sed -i 's/a/b/' {target}", f"sed -ni 's/a/b/p' {target}", f"sed -Ei 's/a/b/' {target}",
                        f"sed -ie 's/a/b/' {target}", f"sed --in-place=.bak 's/a/b/' {target}",
                        f"sed -i -ne 's/a/b/p' {target}", f"perl -lpi -e 's/a/b/' {target}", f"perl -pli -e 's/a/b/' {target}",
                        f"perl -l012pi -e 's/a/b/' {target}", f"perl -0777pi -e 's/a/b/' {target}", f"perl -0xFFpi -e 's/a/b/' {target}",
                        f"sed -I '' 's/a/b/' {target}", f"sed -I.bak 's/a/b/' {target}"):
            self.assert_refused(command, target)

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
