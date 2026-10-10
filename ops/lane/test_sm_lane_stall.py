"""Host tests for the lane stall check's decision and report matching. No network.

Run: python3 -m unittest ops/lane/test_sm_lane_stall.py
"""
import contextlib
import datetime as dt
import io
import re
import sys
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).parent))
import sm_lane_stall as s  # noqa: E402

NOW = dt.datetime(2026, 10, 1, 18, 0, tzinfo=dt.timezone.utc)
URL = 'https://github.com/uncomposed/spoken-margins-native/pull/608#issuecomment-1'


class Decide(unittest.TestCase):
    def test_stall_when_jobs_wait_and_reports_stopped(self):
        stalled, line = s.decide(NOW, NOW - dt.timedelta(hours=3, minutes=5), URL, 4, 2, 24)
        self.assertTrue(stalled)
        self.assertEqual(line, f'STALL: no lane report for 3h 5m while 4 lane jobs are queued (newest report: {URL})')

    def test_stall_when_no_report_in_the_whole_window(self):
        stalled, line = s.decide(NOW, None, None, 1, 2, 24)
        self.assertTrue(stalled)
        self.assertTrue(line.startswith('STALL: no lane report for over 24h 0m while 1 lane job is queued'))

    def test_ok_when_queue_is_empty_however_old_the_report(self):
        stalled, line = s.decide(NOW, NOW - dt.timedelta(hours=9), URL, 0, 2, 24)
        self.assertFalse(stalled)
        self.assertTrue(line.startswith('OK'))
        stalled, line = s.decide(NOW, None, None, 0, 2, 24)
        self.assertFalse(stalled)
        self.assertTrue(line.startswith('OK'))

    def test_ok_when_a_report_is_recent(self):
        stalled, line = s.decide(NOW, NOW - dt.timedelta(minutes=40), URL, 6, 2, 24)
        self.assertFalse(stalled)
        self.assertEqual(line, 'OK: newest lane report 0h 40m ago; 6 lane jobs queued or running')

    def test_threshold_is_the_flag(self):
        quiet = NOW - dt.timedelta(hours=3)
        self.assertTrue(s.decide(NOW, quiet, URL, 2, 2, 24)[0])
        self.assertFalse(s.decide(NOW, quiet, URL, 2, 4, 24)[0])
        self.assertTrue(s.decide(NOW, NOW - dt.timedelta(hours=2), URL, 2, 2, 24)[0])


class ReportMatching(unittest.TestCase):
    def test_plain_and_fenced_reports_match(self):
        self.assertTrue(s.is_lane_report('Lane report pr608-r1 — PASS\ncommit 27663da'))
        self.assertTrue(s.is_lane_report('```text\nLane report pr608-r1 — FAIL\n```'))
        self.assertTrue(s.is_lane_report('\n```text\r\nLane report pr1-r1 — INCONCLUSIVE'))

    def test_other_comments_do_not_match(self):
        self.assertFalse(s.is_lane_report(None))
        self.assertFalse(s.is_lane_report(''))
        self.assertFalse(s.is_lane_report('/lane T3\ntests: Foo'))
        self.assertFalse(s.is_lane_report('See the Lane report above'))
        self.assertFalse(s.is_lane_report('```\nLane report pr1-r1'))


class GitHubReads(unittest.TestCase):
    """What the check asks GitHub and how it adds the answers up: only `gh_json` is replaced, so the queries
    and the paging run. (Main below replaces both readers, which leaves this code unrun.)"""

    REPO = 'owner/repo'

    def report(self, created, number):
        return {'body': f'Lane report pr{number}-r1 — PASS\ncommit abc1234', 'created_at': created,
                'html_url': f'https://example.test/c{number}'}

    def other(self, number):
        return {'body': f'just a comment {number}', 'created_at': '2026-10-01T10:00:00Z', 'html_url': 'x'}

    def test_queued_pending_and_running_runs_all_count_as_waiting_lane_jobs(self):
        counts = {'queued': 2, 'pending': 1, 'in_progress': 4}
        asked = []

        def gh_json(path):
            asked.append(path)
            return {'total_count': counts[re.search(r'status=(\w+)&', path)[1]]}

        with mock.patch.object(s, 'gh_json', gh_json):
            self.assertEqual(s.active_lane_jobs(self.REPO), 7)
        self.assertEqual(sorted(asked), sorted(
            f'repos/owner/repo/actions/workflows/lane.yml/runs?status={status}&per_page=1' for status in counts))

    def test_the_newest_report_is_found_on_a_later_page(self):
        pages = {1: [self.other(n) for n in range(100)],
                 2: [self.other(100), self.report('2026-10-01T09:30:00Z', 7), self.report('2026-10-01T08:00:00Z', 6)]}
        asked = []

        def gh_json(path):
            asked.append(path)
            return pages[int(re.search(r'&page=(\d+)$', path)[1])]

        with mock.patch.object(s, 'gh_json', gh_json):
            found = s.newest_report(self.REPO, NOW, 24, 20)
        self.assertEqual(found, (dt.datetime(2026, 10, 1, 9, 30, tzinfo=dt.timezone.utc), 'https://example.test/c7'))
        self.assertEqual(len(asked), 2)  # page 2 had a report, so it stops there
        self.assertTrue(asked[0].startswith('repos/owner/repo/issues/comments?sort=created&direction=desc'
                                            '&since=2026-09-30T18:00:00Z&per_page=100&page=1'), asked[0])
        self.assertTrue(asked[1].endswith('&page=2'), asked[1])

    def test_it_stops_at_a_short_page_or_the_page_limit_and_finds_no_report(self):
        full = [self.other(n) for n in range(100)]
        for label, answer, max_pages, expected_requests in (
                ('a page shorter than 100 ends the search', lambda path: full[:40], 20, 1),
                ('the page limit ends it', lambda path: full, 3, 3),
                ('an empty window', lambda path: [], 20, 1)):
            with self.subTest(label):
                asked = []
                with mock.patch.object(s, 'gh_json', lambda path: asked.append(path) or answer(path)):
                    self.assertEqual(s.newest_report(self.REPO, NOW, 24, max_pages), (None, None))
                self.assertEqual(len(asked), expected_requests)

    def test_a_failing_gh_call_is_reported_with_the_path_it_asked(self):
        failed = mock.Mock(returncode=1, stdout='', stderr='HTTP 502')
        with mock.patch.object(s.subprocess, 'run', return_value=failed) as run:
            with self.assertRaisesRegex(RuntimeError, r'gh api repos/owner/repo/actions/workflows/lane.yml/runs failed: HTTP 502'):
                s.gh_json('repos/owner/repo/actions/workflows/lane.yml/runs?status=queued&per_page=1')
        self.assertEqual(run.call_args.args[0], ['gh', 'api', 'repos/owner/repo/actions/workflows/lane.yml/runs?status=queued&per_page=1'])


class Main(unittest.TestCase):
    def setUp(self):
        self.saved = (s.active_lane_jobs, s.newest_report)

    def tearDown(self):
        s.active_lane_jobs, s.newest_report = self.saved

    def run_main(self, jobs, report, argv=()):
        s.active_lane_jobs = lambda repo: jobs
        s.newest_report = lambda repo, now, lookback, pages: report
        with contextlib.redirect_stdout(io.StringIO()):
            return s.main(list(argv))

    def test_exit_codes(self):
        old = (dt.datetime.now(dt.timezone.utc) - dt.timedelta(hours=5), URL)
        self.assertEqual(self.run_main(3, old), 1)
        self.assertEqual(self.run_main(3, old, ['--hours', '6']), 0)
        self.assertEqual(self.run_main(0, old), 0)

    def test_unreadable_github_is_an_error_not_ok(self):
        def fail(repo):
            raise RuntimeError('gh api failed')
        s.active_lane_jobs = fail
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            self.assertEqual(s.main([]), 2)
        self.assertTrue(out.getvalue().startswith('ERROR:'))


if __name__ == '__main__':
    unittest.main()
