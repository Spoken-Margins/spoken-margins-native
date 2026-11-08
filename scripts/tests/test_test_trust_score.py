"""ops/test-trust/score.py: a test a merged PR broke on main is trunk-red, not next-moved noise (#3702)."""
import contextlib
import importlib.util
import io
import json
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('test_trust_score', ROOT / 'ops' / 'test-trust' / 'score.py')
score = importlib.util.module_from_spec(spec)
spec.loader.exec_module(score)

TEST = 'SpokenMarginsAppTests/Build23SharingSeamsTests/testTwoMarginsWithLocalSkimReferencesProduceVerifiedShareFile'
OTHER = 'SpokenMarginsAppTests/OtherTests/testUnrelated'
CLASS = 'Build23SharingSeamsTests'
BOT = 'github-actions[bot]'


def report(pr, verdict, at, head, nxt, failed=(), tests=(CLASS, 'OtherTests')):
    request = {'commit': head, 'next': nxt, 'tier': 'T3', 'tests': list(tests)}
    body = f'Lane report pr{pr} — {verdict}\n<!-- lane-request: {json.dumps(request)} -->\napp plan\n'
    body += ''.join(f'Failed: {t}\n' for t in failed)
    return {'u': f'https://example.test/{pr}/{at}', 'at': at, 'a': BOT, 'b': body}


def episode(test, key, at, cls='next-moved'):
    return {'test': test, 'key': key, 'at': at, 'class': cls}


WINDOW = {'test': TEST, 'issue': 3475, 'from': '2026-11-02T00:00:00Z', 'to': '2026-11-04T00:00:00Z'}


class ReclassifyTests(unittest.TestCase):
    def test_two_prs_failing_the_test_inside_an_issue_window_are_trunk_red(self):
        eps = [episode(TEST, 'pr:3460', '2026-11-03T01:00:00Z'), episode(TEST, 'pr:3478', '2026-11-03T05:00:00Z')]
        out = score.trunk_red_from_issues(eps, [WINDOW])
        self.assertEqual([e['class'] for e in out], ['trunk-red', 'trunk-red'])
        self.assertEqual({e['trunk_issue'] for e in out}, {3475})

    def test_one_pr_alone_stays_next_moved(self):
        eps = [episode(TEST, 'pr:3460', '2026-11-03T01:00:00Z')]
        self.assertEqual(score.trunk_red_from_issues(eps, [WINDOW])[0]['class'], 'next-moved')

    def test_the_same_pr_twice_is_not_two_prs(self):
        eps = [episode(TEST, 'pr:3460', '2026-11-03T01:00:00Z'), episode(TEST, 'pr:3460', '2026-11-03T02:00:00Z')]
        self.assertEqual({e['class'] for e in score.trunk_red_from_issues(eps, [WINDOW])}, {'next-moved'})

    def test_episodes_outside_the_window_or_for_another_test_or_class_are_untouched(self):
        eps = [episode(TEST, 'pr:1', '2026-11-01T23:59:59Z'), episode(TEST, 'pr:2', '2026-11-04T00:00:01Z'),
               episode(OTHER, 'pr:3', '2026-11-03T01:00:00Z'), episode(OTHER, 'pr:4', '2026-11-03T02:00:00Z'),
               episode(TEST, 'pr:5', '2026-11-03T01:00:00Z', 'catch-candidate'),
               episode(TEST, 'pr:6', '2026-11-03T01:00:00Z', 'rerun-pass')]
        out = score.trunk_red_from_issues(eps, [WINDOW])
        self.assertEqual([e['class'] for e in out],
                         ['next-moved', 'next-moved', 'next-moved', 'next-moved', 'catch-candidate', 'rerun-pass'])

    def test_no_windows_changes_nothing(self):
        eps = [episode(TEST, 'pr:1', '2026-11-03T01:00:00Z'), episode(TEST, 'pr:2', '2026-11-03T02:00:00Z')]
        self.assertEqual({e['class'] for e in score.trunk_red_from_issues(eps, [])}, {'next-moved'})


class ScoreRunTests(unittest.TestCase):
    """The #3475 case end to end: two PRs fail the same test with no change of their own, next moves, then each passes."""

    def run_score(self, windows):
        with tempfile.TemporaryDirectory() as tmp:
            here = Path(tmp)
            reports = []
            for pr, head, base in ((3460, 'aaa1111', 3), (3478, 'bbb2222', 3)):
                reports.append(report(pr, 'FAIL', f'2026-11-03T0{base}:00:00Z', head, 'n1', failed=[TEST]))
                reports.append(report(pr, 'PASS', f'2026-11-03T0{base + 2}:00:00Z', head, 'n2'))
            (here / 'lane-comments.jsonl').write_text(''.join(json.dumps(r) + '\n' for r in reports))
            if windows:
                (here / 'trunk-red-issues.jsonl').write_text(''.join(json.dumps(w) + '\n' for w in windows))
            with contextlib.redirect_stdout(io.StringIO()):
                score.main(['score.py', str(ROOT), str(here), '2026-10-07'])
            return [json.loads(line) for line in (here / 'episodes.jsonl').read_text().splitlines()]

    def test_without_the_issue_window_both_read_as_next_moved(self):
        self.assertEqual([e['class'] for e in self.run_score([])], ['next-moved', 'next-moved'])

    def test_with_the_issue_window_both_read_as_trunk_red(self):
        eps = self.run_score([WINDOW])
        self.assertEqual([e['class'] for e in eps], ['trunk-red', 'trunk-red'])
        per_test = {e['test'] for e in eps}
        self.assertEqual(per_test, {TEST})


if __name__ == '__main__':
    unittest.main()
