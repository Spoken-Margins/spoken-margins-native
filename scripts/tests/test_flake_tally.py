"""scripts/flake_tally.py and scripts/flake_tally_report.py: the retry-pass tally on #2176."""
import datetime as dt
import sys
import unittest
from pathlib import Path
from unittest import mock

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
import flake_tally as ft  # noqa: E402
import flake_tally_report as report  # noqa: E402

NOW = dt.datetime(2026, 10, 26, 12, 0, tzinfo=dt.timezone.utc)
TEST = 'SupertonicSpeechTests/testGenerationTokenCancelsStaleRenderAfterReplay()'
OTHER = 'Gate1FlowUITests/testOther()'
BOT = 'github-actions[bot]'


def comment(test, run, days_ago=1.0, login=BOT, association='NONE', delta=dt.timedelta()):
    when = NOW - dt.timedelta(days=days_ago) + delta
    return {'body': ft.tally_line(test, 'abcdef1234', run, when) + '\n\nnote', 'user': {'login': login},
            'author_association': association}


def issue(test, login=BOT, association='NONE'):
    return {'body': ft.flake_marker(test), 'user': {'login': login}, 'author_association': association}


class Format(unittest.TestCase):
    def test_line_round_trips(self):
        line = ft.tally_line(TEST, 'abcdef1234', '99', NOW)
        self.assertEqual(line, f'flake-tally: {TEST} abcdef1 99 2026-10-26T12:00:00Z')
        self.assertEqual(ft.parse_line(line + '\n\nbody'), (TEST, '99', NOW))

    def test_name_with_spaces_and_junk(self):
        self.assertEqual(ft.parse_line('flake-tally: a b c abcdef1 5 2026-10-26T12:00:00Z')[0], 'a b c')
        for bad in ('', None, 'flake-tally: nonsense', 'flake-tally: t s 1 not-a-time', 'other: t s 1 2026-10-26T12:00:00Z'):
            self.assertIsNone(ft.parse_line(bad), bad)


class Counting(unittest.TestCase):
    def test_trust_filter_ignores_a_strangers_lookalike(self):
        comments = [comment(TEST, '1'), comment(TEST, '2', login='mallory', association='NONE'),
                    comment(TEST, '3', login='github-actions', association='NONE'),
                    comment(TEST, '4', login='alice', association='COLLABORATOR')]
        self.assertEqual(ft.tally_counts(comments, NOW), {TEST: ['1', '4']})

    def test_integration_run_trusts_only_the_bot(self):
        comments = [comment(TEST, '1'), comment(TEST, '4', login='alice', association='COLLABORATOR')]
        self.assertEqual(ft.tally_counts(comments, NOW, trust=ft.bot_only), {TEST: ['1']})

    def test_window_edges(self):
        edge = dt.timedelta(seconds=1)
        comments = [comment(TEST, 'in', days_ago=7, delta=edge), comment(TEST, 'exactly', days_ago=7),
                    comment(TEST, 'out', days_ago=7, delta=-edge), comment(TEST, 'future', days_ago=-0.01)]
        self.assertEqual(ft.tally_counts(comments, NOW), {TEST: ['in', 'exactly']})

    def test_same_run_counts_once(self):
        self.assertEqual(ft.tally_counts([comment(TEST, '1'), comment(TEST, '1', days_ago=2)], NOW), {TEST: ['1']})


class Report(unittest.TestCase):
    def comments(self, n, test=TEST):
        return [comment(test, str(i), days_ago=i * 0.5) for i in range(n)]

    def test_due_at_three_not_two(self):
        self.assertEqual(report.build_report(self.comments(2), [], NOW)[1], [])
        self.assertEqual(report.build_report(self.comments(3), [], NOW)[1], [TEST])

    def test_open_issue_dedupes_but_a_strangers_marker_does_not(self):
        self.assertEqual(report.build_report(self.comments(3), [issue(TEST)], NOW)[1], [])
        self.assertEqual(report.build_report(self.comments(3), [issue(TEST, login='mallory')], NOW)[1], [TEST])
        self.assertEqual(report.build_report(self.comments(3), [issue(TEST + 'X')], NOW)[1], [TEST])

    def test_dry_run_files_nothing_and_file_issues_files_one_per_test(self):
        comments = self.comments(3) + self.comments(4, OTHER)
        with mock.patch.object(report, 'fetch_comments', return_value=comments), \
                mock.patch.object(report, 'fetch_open_issues', return_value=[issue(OTHER)]), \
                mock.patch.object(report, 'open_issue', return_value='url') as opener, \
                mock.patch('builtins.print'):
            self.assertEqual(report.main([]), 0)
            opener.assert_not_called()
            report.main(['--file-issues'])
            self.assertEqual(opener.call_count, 1)
            title, body = opener.call_args[0][1:]
            self.assertTrue(title.startswith('Flaky: testGenerationToken'))
            self.assertIn(ft.flake_marker(TEST), body)


if __name__ == '__main__':
    unittest.main()
