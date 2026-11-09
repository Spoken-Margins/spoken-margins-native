"""ops/test-trust/score.py judges an episode by the PR's own commits after the failing run (#3900).

A merge from main, or a rebase onto a moved main, after a red run is not a catch. A product-only fix is; a test-only
fix is not; a fix that changes product and tests together is reported apart.
"""
import contextlib
import importlib.util
import io
import json
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('test_trust_score_own', ROOT / 'ops' / 'test-trust' / 'score.py')
score = importlib.util.module_from_spec(spec)
spec.loader.exec_module(score)

TEST = 'SpokenMarginsAppTests/ModelTests/testSomething'
PRODUCT = 'App/SpokenMarginsApp/Sources/Model.swift'
FEATURE = 'App/SpokenMarginsApp/Sources/Feature.swift'
TEST_FILE = 'App/SpokenMarginsApp/Tests/ModelTests.swift'
BOT = 'github-actions[bot]'


def vcs(repo, *args):
    out = subprocess.run(['git', '-C', str(repo), '-c', 'user.name=t', '-c', 'user.email=t@example.test', *args],
                         capture_output=True, text=True, check=True)
    return out.stdout.strip()


def commit(repo, files, msg):
    for name, text in files.items():
        path = Path(repo) / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
    vcs(repo, 'add', '-A')
    vcs(repo, 'commit', '-q', '-m', msg)
    return vcs(repo, 'rev-parse', 'HEAD')


def report(verdict, at, head, nxt, failed=()):
    request = {'commit': head, 'next': nxt, 'tier': 'T3', 'tests': ['ModelTests']}
    body = f'Lane report pr7 — {verdict}\n<!-- lane-request: {json.dumps(request)} -->\napp plan\n'
    body += ''.join(f'Failed: {t}\n' for t in failed)
    return {'u': f'https://example.test/{at}', 'at': at, 'a': BOT, 'b': body}


class OwnCommitsTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.repo = Path(self.tmp.name) / 'repo'
        self.repo.mkdir()
        vcs(self.repo, 'init', '-q', '-b', 'main')
        self.base = commit(self.repo, {PRODUCT: 'v0\n', TEST_FILE: 't0\n', 'README.md': 'r\n'}, 'base')
        vcs(self.repo, 'checkout', '-q', '-b', 'pr')
        self.fail_head = commit(self.repo, {FEATURE: 'f\n'}, 'feature')

    def main_moves(self, files):
        vcs(self.repo, 'checkout', '-q', 'main')
        sha = commit(self.repo, files, 'main moves')
        vcs(self.repo, 'checkout', '-q', 'pr')
        return sha

    def head(self):
        return vcs(self.repo, 'rev-parse', 'HEAD')

    def kind(self, pass_head, pass_next):
        return score.classify_change(self.repo, self.fail_head, self.base, pass_head, pass_next)

    def test_a_merge_from_main_after_a_red_run_is_not_a_catch(self):
        moved = self.main_moves({PRODUCT: 'v1 from main\n'})
        vcs(self.repo, 'merge', '-q', '--no-ff', '-m', 'Merge main', 'main')
        self.assertEqual(self.kind(self.head(), moved), ('flake', 'none'))

    def test_a_rebase_onto_a_moved_main_is_not_a_catch(self):
        moved = self.main_moves({PRODUCT: 'v1 from main\n'})
        vcs(self.repo, 'rebase', '-q', 'main')
        self.assertNotEqual(self.head(), self.fail_head)
        self.assertEqual(self.kind(self.head(), moved), ('flake', 'none'))

    def test_a_product_only_fix_is_a_catch_even_after_a_main_merge(self):
        moved = self.main_moves({'docs/note.md': 'n\n'})
        vcs(self.repo, 'merge', '-q', '--no-ff', '-m', 'Merge main', 'main')
        fixed = commit(self.repo, {FEATURE: 'f fixed\n'}, 'fix the bug')
        self.assertEqual(self.kind(fixed, moved), ('catch', 'product-only'))

    def test_a_test_only_fix_is_not_a_catch(self):
        fixed = commit(self.repo, {TEST_FILE: 't1 longer wait\n'}, 'wait longer')
        self.assertEqual(self.kind(fixed, self.base), ('wrong-test', 'test-only'))

    def test_a_product_and_test_fix_is_reported_apart(self):
        fixed = commit(self.repo, {FEATURE: 'f2\n', TEST_FILE: 't2\n'}, 'both')
        self.assertEqual(self.kind(fixed, self.base), ('mixed', 'mixed'))

    def test_a_product_fix_then_a_test_fix_in_the_gap_is_mixed(self):
        commit(self.repo, {FEATURE: 'f2\n'}, 'fix')
        fixed = commit(self.repo, {TEST_FILE: 't2\n'}, 'update expectation')
        self.assertEqual(self.kind(fixed, self.base), ('mixed', 'mixed'))

    def test_fix_kind_table(self):
        self.assertEqual(score.fix_kind([PRODUCT]), 'product-only')
        self.assertEqual(score.fix_kind([PRODUCT, 'docs/a.md']), 'product-only')
        self.assertEqual(score.fix_kind([PRODUCT, TEST_FILE]), 'mixed')
        self.assertEqual(score.fix_kind([TEST_FILE]), 'test-only')
        self.assertEqual(score.fix_kind(['docs/a.md']), 'other')
        self.assertEqual(score.fix_kind([]), 'other')

    def test_pr_kind_reads_threading_in_the_prs_own_product_diff(self):
        commit(self.repo, {FEATURE: 'Task.detached(priority: .background) {}\n'}, 'bg')
        head = self.head()
        self.assertEqual(score.pr_kind(self.repo, head, self.base), 'thread-move')
        self.assertEqual(score.pr_kind(self.repo, self.fail_head, self.base), 'other')
        self.assertEqual(score.pr_kind(self.repo, head, ''), 'unknown')

    def run_end_to_end(self, pass_head, pass_next):
        here = Path(self.tmp.name) / 'out'
        here.mkdir()
        reports = [report('FAIL', '2026-11-03T03:00:00Z', self.fail_head, self.base, failed=[TEST]),
                   report('PASS', '2026-11-03T05:00:00Z', pass_head, pass_next)]
        (here / 'lane-comments.jsonl').write_text(''.join(json.dumps(r) + '\n' for r in reports))
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            score.main(['score.py', str(self.repo), str(here), '2026-10-07'])
        eps = [json.loads(line) for line in (here / 'episodes.jsonl').read_text().splitlines()]
        return eps, out.getvalue()

    def test_end_to_end_main_merge_is_not_counted(self):
        moved = self.main_moves({PRODUCT: 'v1 from main\n'})
        vcs(self.repo, 'merge', '-q', '--no-ff', '-m', 'Merge main', 'main')
        eps, printed = self.run_end_to_end(self.head(), moved)
        self.assertEqual([e['class'] for e in eps], ['next-moved'])
        self.assertIn('(product-only / mixed / test-only): 0 0 0', printed)

    def test_end_to_end_product_only_fix_counts_once(self):
        fixed = commit(self.repo, {FEATURE: 'f fixed\n'}, 'fix')
        eps, printed = self.run_end_to_end(fixed, self.base)
        self.assertEqual([(e['class'], e['fix']) for e in eps], [('catch-candidate', 'product-only')])
        self.assertIn('(product-only / mixed / test-only): 1 0 0', printed)

    def test_end_to_end_mixed_is_reported_apart(self):
        fixed = commit(self.repo, {FEATURE: 'f2\n', TEST_FILE: 't2\n'}, 'both')
        eps, printed = self.run_end_to_end(fixed, self.base)
        self.assertEqual([e['class'] for e in eps], ['mixed-fix'])
        self.assertIn(': 0 1 0', printed)


if __name__ == '__main__':
    unittest.main()
