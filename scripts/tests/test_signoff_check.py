"""The sign-off check (#2114): signed, unsigned, merge commit, bot and collaborator, plus a real git history."""
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import signoff_check as so

SIGNED = 'Add a thing\n\nSigned-off-by: Ada Lovelace <ada@example.com>\n'


def commit(body, parents=('p',), email='ada@example.com'):
    return {'sha': 'a' * 40, 'parents': list(parents), 'author_email': email, 'body': body}


class CheckTests(unittest.TestCase):
    def test_table(self):
        cases = [
            ('signed outsider', [commit(SIGNED)], 'NONE', 'ada', 0),
            ('unsigned outsider', [commit('Add a thing\n')], 'CONTRIBUTOR', 'ada', 1),
            ('unsigned first-timer', [commit('x')], 'FIRST_TIME_CONTRIBUTOR', 'ada', 1),
            ('one of two unsigned', [commit(SIGNED), commit('Fix typo\n')], 'NONE', 'ada', 1),
            ('unsigned merge commit', [commit('Merge branch main', parents=('p', 'q'))], 'NONE', 'ada', 0),
            ('unsigned commit by a bot account', [commit('x', email='41898282+dependabot[bot]@users.noreply.github.com')],
             'NONE', 'ada', 0),
            ('unsigned PR by a bot', [commit('x')], 'NONE', 'dependabot[bot]', 0),
            ('unsigned collaborator', [commit('x')], 'COLLABORATOR', 'cole', 0),
            ('unsigned owner', [commit('x')], 'OWNER', 'cole', 0),
            ('unsigned member', [commit('x')], 'MEMBER', 'cole', 0),
            ('no commits', [], 'NONE', 'ada', 0),
        ]
        for name, commits, association, login, wrong in cases:
            with self.subTest(name):
                self.assertEqual(len(so.check(commits, association, login)), wrong)

    def test_neighbouring_signoff_spellings(self):
        for body, ok in [
            ('x\n\nSigned-off-by: Ada <ada@example.com>', True),
            ('x\n\nsigned-off-by: Ada <ada@example.com>', True),             # git writes it capitalised, but case is not the point
            ('x\n\nSigned-off-by: Ada <ada@example.com>   \n', True),
            ('x\n\nSigned-off-by: Ada Lovelace <ada@example.com>\nCo-authored-by: B <b@example.com>', True),
            ('x\n\nSigned-off-by:\n', False),                                 # empty
            ('x\n\nSigned-off-by: Ada\n', False),                             # no email
            ('x\n\nSigned-off-by: Ada <not-an-email>\n', False),
            ('x\n\nI signed-off-by: Ada <ada@example.com> in prose\n', False),  # must start the line
            ('Signed-off-by is required here\n', False),
        ]:
            with self.subTest(body=body):
                self.assertEqual(not so.unsigned([commit(body)]), ok)

    def test_parse_log_round_trips_a_multiline_body(self):
        raw = (f'{"a" * 40}{so.FIELD}{"b" * 40} {"c" * 40}{so.FIELD}x@example.com{so.FIELD}Merge\n\nbody{so.RECORD}'
               f'\n{"d" * 40}{so.FIELD}{"e" * 40}{so.FIELD}y@example.com{so.FIELD}{SIGNED}{so.RECORD}')
        commits = so.parse_log(raw)
        self.assertEqual([len(c['parents']) for c in commits], [2, 1])
        self.assertEqual(commits[1]['author_email'], 'y@example.com')
        self.assertFalse(so.unsigned(commits))


class GitHistoryTests(unittest.TestCase):
    """The log format against a real repository: a signed commit passes, an unsigned one is named."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.repo = Path(self.tmp.name)
        self.git('init', '-q', '-b', 'main')
        self.git('config', 'user.email', 'ada@example.com')
        self.git('config', 'user.name', 'Ada')
        self.git('commit', '-q', '--allow-empty', '-m', 'base')

    def git(self, *args):
        return subprocess.run(['git', *args], cwd=self.repo, check=True, capture_output=True, text=True).stdout.strip()

    def run_check(self, association):
        return subprocess.run([sys.executable, str(Path(so.__file__)), '--base', 'main', '--head', 'topic',
                               '--association', association, '--login', 'ada'],
                              cwd=self.repo, capture_output=True, text=True)

    def test_signed_and_unsigned_branches(self):
        self.git('switch', '-q', '-c', 'topic')
        self.git('commit', '-q', '--allow-empty', '-s', '-m', 'signed')
        self.assertEqual(self.run_check('NONE').returncode, 0)
        self.git('commit', '-q', '--allow-empty', '-m', 'unsigned\n\nA body with two lines.\nSecond line.')
        unsigned_sha = self.git('rev-parse', 'HEAD')[:7]
        done = self.run_check('NONE')
        self.assertEqual(done.returncode, 1, done.stdout + done.stderr)
        self.assertIn(unsigned_sha, done.stdout)
        self.assertIn('1 of 2 commits', done.stdout)
        self.assertIn('git rebase --signoff', done.stdout)
        self.assertEqual(self.run_check('COLLABORATOR').returncode, 0)  # collaborators aren't checked

    def test_merge_commit_in_the_branch_is_exempt(self):
        self.git('switch', '-q', '-c', 'topic')
        self.git('commit', '-q', '--allow-empty', '-s', '-m', 'signed')
        self.git('switch', '-q', 'main')
        self.git('commit', '-q', '--allow-empty', '-m', 'main moved')
        self.git('switch', '-q', 'topic')
        self.git('merge', '-q', '--no-ff', '-m', 'Merge main into topic', 'main')
        self.assertEqual(self.run_check('NONE').returncode, 0)


if __name__ == '__main__':
    unittest.main()
