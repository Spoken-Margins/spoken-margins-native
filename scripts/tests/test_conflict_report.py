from datetime import date
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import conflict_report as report  # noqa: E402

URL = 'https://api.github.com/repos/o/r/issues/'


def hosted(base='main', sha='2bd3335', files=('a/One.swift', 'b/Two.py'), more=0):
    shown = ', '.join(f'`{name}`' for name in files)
    tail = f' and {more} more' if more else ''
    return (f'Handing to the Mac finisher: the PR does not merge cleanly into `{base}` (`{sha}`) at its head `a3cf501`. '
            f'Conflicting files: {shown}{tail}.\n\nDone when: `{base}` is merged into the branch.\n'
            f'<!-- lane-conflict head=a3cf501 base={sha} -->')


def runner(base='main', sha='2bd3335', files=('a/One.swift',)):
    return ('Lane report pr1-r2 — INCONCLUSIVE\ncommit 79e3dca (tested merged with main at 6d81311) · tier T3\n'
            'ran: nothing\n'
            f'The PR does not merge cleanly into {base} ({sha}): {", ".join(files)}. '
            f'Merge {base} into your branch, push, and ask again.\ncrashes: none\n')


def comment(pr, day, body):
    return {'created_at': f'{day}T10:00:00Z', 'issue_url': f'{URL}{pr}', 'body': body}


class ParseNoticeTests(unittest.TestCase):
    def test_the_hosted_notice_gives_base_tip_and_files(self):
        self.assertEqual(report.parse_notice(hosted()), ('main', '2bd3335', ['a/One.swift', 'b/Two.py'], False))

    def test_the_runner_report_gives_the_same_shape(self):
        self.assertEqual(report.parse_notice(runner(files=('x/Y.swift', 'z.json'))),
                         ('main', '2bd3335', ['x/Y.swift', 'z.json'], False))

    def test_a_notice_that_says_and_more_is_marked_capped(self):
        names = tuple(f'f{i}.swift' for i in range(10))
        base, sha, files, capped = report.parse_notice(hosted(files=names, more=4))
        self.assertEqual(files, list(names))
        self.assertTrue(capped)

    def test_a_runner_report_with_ten_files_is_marked_capped(self):
        names = tuple(f'f{i}.swift' for i in range(10))
        self.assertTrue(report.parse_notice(runner(files=names))[3])

    def test_a_file_name_with_dots_and_spaces_is_kept_whole(self):
        _, _, files, _ = report.parse_notice(hosted(files=('docs/a.b.md', 'App/My File.swift')))
        self.assertEqual(files, ['docs/a.b.md', 'App/My File.swift'])

    def test_text_that_only_mentions_a_conflict_is_not_a_notice(self):
        for body in ('', None, 'The PR does not merge cleanly', 'Lane report — PASS\nran: everything',
                     'Fails on main too: not this PR'):
            self.assertIsNone(report.parse_notice(body), body)

    def test_a_notice_with_no_files_is_not_counted(self):
        self.assertIsNone(report.parse_notice(
            'The PR does not merge cleanly into main (abc1234): . Merge main into your branch'))


class EventsTests(unittest.TestCase):
    def test_both_notices_for_one_pr_and_tip_count_once_and_keep_every_file(self):
        events = report.events_from([
            comment(7, '2026-10-07', hosted(files=('a.swift',))),
            comment(7, '2026-10-07', runner(files=('a.swift', 'b.swift')))])
        self.assertEqual(len(events), 1)
        self.assertEqual(events[0]['files'], ['a.swift', 'b.swift'])

    def test_the_same_pr_after_trunk_moved_is_a_second_event(self):
        events = report.events_from([comment(7, '2026-10-07', hosted(sha='1111111')),
                                     comment(7, '2026-10-09', hosted(sha='2222222'))])
        self.assertEqual(len(events), 2)

    def test_two_prs_on_the_same_tip_are_two_events(self):
        events = report.events_from([comment(7, '2026-10-07', hosted()), comment(8, '2026-10-07', hosted())])
        self.assertEqual({event['pr'] for event in events}, {7, 8})

    def test_notices_before_since_are_left_out(self):
        events = report.events_from([comment(7, '2026-09-20', hosted()), comment(8, '2026-10-01', hosted())],
                                    since=date(2026, 9, 28))
        self.assertEqual([event['pr'] for event in events], [8])

    def test_the_week_starts_on_monday(self):
        self.assertEqual(report.week_of(date(2026, 11, 8)), date(2026, 11, 2))  # a Sunday
        self.assertEqual(report.week_of(date(2026, 11, 2)), date(2026, 11, 2))
        self.assertEqual(report.week_of(date(2026, 11, 9)), date(2026, 11, 9))

    def test_a_file_in_one_event_counts_once_however_many_notices_list_it(self):
        events = report.events_from([comment(7, '2026-10-07', hosted(files=('a.swift',))),
                                     comment(7, '2026-10-07', runner(files=('a.swift',)))])
        per_file, per_week, capped = report.tally(events)
        self.assertEqual(per_file['a.swift'][date(2026, 10, 5)], 1)
        self.assertEqual(per_week[date(2026, 10, 5)], 1)
        self.assertEqual(capped, 0)


class RenderTests(unittest.TestCase):
    def test_the_table_has_a_row_per_file_with_conflicts_commits_and_a_rate(self):
        events = report.events_from([comment(7, '2026-10-07', hosted(files=('a.swift', 'b.swift'))),
                                     comment(8, '2026-10-08', hosted(sha='9999999', files=('a.swift',)))])
        churn = {'a.swift': {date(2026, 10, 5): 40}, 'b.swift': {}}
        text = report.render(events, churn, date(2026, 9, 28), date(2026, 10, 14))
        self.assertIn('2 events across 2 PRs', text)
        self.assertIn('| `a.swift` |  | 2 |  | 2 | 40 | 5.0 |', text)
        self.assertIn('| `b.swift` |  | 1 |  | 1 | 0 | n/a |', text)
        self.assertLess(text.index('`a.swift`'), text.index('`b.swift`'))

    def test_no_events_still_renders(self):
        text = report.render([], {}, date(2026, 9, 28), date(2026, 10, 14))
        self.assertIn('0 events across 0 PRs', text)


class ChurnTests(unittest.TestCase):
    def test_commits_touching_a_file_are_counted_per_week_and_merges_are_not(self):
        with tempfile.TemporaryDirectory() as root:
            def git(*args, env=None):
                subprocess.run(['git', '-C', root, '-c', 'user.name=t', '-c', 'user.email=t@t', *args],
                               check=True, capture_output=True, env=env)
            import os
            git('init', '-q', '-b', 'main')
            for day, name in (('2026-10-06', 'a.txt'), ('2026-10-07', 'a.txt'), ('2026-10-14', 'b.txt')):
                Path(root, name).write_text(day)
                git('add', name)
                git('commit', '-q', '-m', day, env=dict(os.environ, GIT_AUTHOR_DATE=f'{day}T12:00:00',
                                                         GIT_COMMITTER_DATE=f'{day}T12:00:00'))
            counted = report.churn(Path(root), date(2026, 9, 28), 'main')
            self.assertEqual(dict(counted['a.txt']), {date(2026, 10, 5): 2})
            self.assertEqual(dict(counted['b.txt']), {date(2026, 10, 12): 1})


if __name__ == '__main__':
    unittest.main()
