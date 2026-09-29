from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import hot_file_ratchet as ratchet  # noqa: E402

MODEL = ratchet.HOT_FILES[0]


class RatchetTests(unittest.TestCase):
    """The hot-file ceiling is the smallest size on next since the start; a PR may not grow past it."""

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.git('init', '-q', '-b', 'next')
        self.start = self.write(100, 'the ratchet starts')

    def git(self, *args):
        return subprocess.run(['git', '-c', 'user.name=t', '-c', 'user.email=t@example.com', '-C', str(self.root),
                               *args], check=True, capture_output=True, text=True).stdout.strip()

    def write(self, lines, message, path=MODEL):
        target = self.root / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(''.join(f'line {n}: {message}\n' for n in range(lines)))
        self.git('add', '.')
        self.git('commit', '-q', '-m', message)
        return self.git('rev-parse', 'HEAD')

    def branch(self, name, at='next'):
        self.git('checkout', '-q', '-b', name, at)

    def check(self, head='HEAD', labels=()):
        return ratchet.violations(self.root, 'next', head, labels, start=self.start)

    def test_the_ceiling_is_the_smallest_size_since_the_start(self):
        self.write(90, 'a split moved lines out')
        self.write(95, 'a hot-file-ok change grew it')
        self.assertEqual(ratchet.ceiling(self.root, 'next', MODEL, self.start), 90)

    def test_a_pr_may_not_grow_the_file_past_its_ceiling(self):
        self.write(90, 'shrunk')
        self.branch('pr')
        self.write(91, 'one more line')
        found = self.check()
        self.assertEqual(len(found), 1)
        self.assertIn('Gate1AppModel.swift would be 91 lines, above its ceiling of 90', found[0])
        self.assertIn('Move 1 lines out', found[0])
        self.assertEqual(self.check(labels={'hot-file-ok'}), [])

    def test_moving_lines_out_pays_for_lines_added(self):
        self.branch('pr')
        self.write(100, 'added five, moved five out')
        self.assertEqual(self.check(), [])
        self.write(97, 'net smaller')
        self.assertEqual(self.check(), [])

    def test_after_a_hot_file_ok_growth_the_file_may_not_grow_further(self):
        self.write(90, 'shrunk')
        self.write(95, 'grew under hot-file-ok')
        self.branch('pr')
        self.write(95, 'same size')
        self.assertEqual(self.check(), [])
        self.write(96, 'one more')
        self.assertIn('would be 96 lines', self.check()[0])

    def test_a_branch_behind_next_is_judged_by_what_would_land(self):
        self.branch('pr', at=self.start)
        self.write(102, 'two lines added on an old base')
        self.git('checkout', '-q', 'next')
        self.write(90, 'next shrank meanwhile')
        self.assertEqual(ratchet.size_after_merge(self.root, 'next', 'pr', MODEL), 92)
        self.assertIn('Move 2 lines out', self.check('pr')[0])
        self.git('checkout', '-q', '-b', 'untouched', self.start)
        self.write(5, 'another file only', path='docs/note.md')
        self.assertEqual(self.check('untouched'), [])  # not blamed for next's changes

    def test_without_the_start_in_history_the_size_on_next_is_the_ceiling(self):
        self.assertEqual(ratchet.ceiling(self.root, 'next', MODEL, start='0' * 40), 100)


if __name__ == '__main__':
    unittest.main()
