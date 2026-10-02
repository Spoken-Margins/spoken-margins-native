"""Host tests for the lane stall check's decision and report matching. No network.

Run: python3 -m unittest ops/lane/test_sm_lane_stall.py
"""
import contextlib
import datetime as dt
import io
import sys
import unittest
from pathlib import Path

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
