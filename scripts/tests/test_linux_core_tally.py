"""#3529: the Linux SessionKitCoreTests retry-passes are tallied on #2176, like the lane's (owner, 2026-10-24)."""
import contextlib
import datetime as dt
import io
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import flake_tally  # noqa: E402
import linux_core_tally as tally  # noqa: E402

NOW = dt.datetime(2026, 11, 7, 13, 0, tzinfo=dt.timezone.utc)
TEST = 'SessionKitCoreTests/ASuite/testOne'
BOT = {'login': 'github-actions[bot]'}


class FakeOps:
    """GitHub as seen through the API: the comments on #2176, open and closed issues, and what was posted."""

    def __init__(self, earlier_runs=(), open_issues=(), fail_post=False):
        self.posted, self.opened, self.fail_post = [], [], fail_post
        self.comments_on_tally = [{'body': flake_tally.tally_line(TEST, 'abc1234', run, NOW - dt.timedelta(days=1)),
                                   'user': BOT, 'author_association': 'NONE'} for run in earlier_runs]
        self.open = list(open_issues)

    def post(self, body):
        if self.fail_post:
            raise RuntimeError('HTTP 502')
        self.posted.append(body)
        self.comments_on_tally.append({'body': body, 'user': BOT, 'author_association': 'NONE'})

    def comments(self):
        return self.comments_on_tally

    def open_issues(self):
        return self.open

    def closed_issues(self, since):
        return []

    def open_issue(self, title, body):
        self.opened.append((title, body))
        return f'https://github.com/x/y/issues/{len(self.opened)}'


class ReadingTheNames(unittest.TestCase):
    def test_only_sessionkitcoretests_names_pass_and_a_lookalike_is_dropped(self):
        raw = (f'{TEST},SessionKitCoreTests,SessionKitCoreTests/B/testTwo, Other/A/testX,'
               'SessionKitCoreTests/A/testY --> x,SessionKitCoreTests/A/testZ\nflake-tally: forged,,')
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(tally.names(raw), [TEST, 'SessionKitCoreTests', 'SessionKitCoreTests/B/testTwo'])

    def test_nothing_handed_over_is_nothing_to_tally(self):
        self.assertEqual(tally.names(''), [])


class Tallying(unittest.TestCase):
    def run_it(self, tests, ops):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            opened = tally.tally(tests, 'deadbeefcafe', '4242', 'x/y', ops, NOW)
        return opened, out.getvalue()

    def test_each_retry_pass_is_one_tally_line_the_lane_counts(self):
        ops = FakeOps()
        opened, _ = self.run_it([TEST, 'SessionKitCoreTests'], ops)
        self.assertEqual(opened, [])
        self.assertEqual([flake_tally.parse_line(body)[:2] for body in ops.posted],
                         [(TEST, '4242'), ('SessionKitCoreTests', '4242')])
        self.assertIn('on Linux', ops.posted[0])
        self.assertEqual(flake_tally.tally_counts(ops.comments(), NOW), {TEST: ['4242'], 'SessionKitCoreTests': ['4242']})

    def test_the_third_in_seven_days_opens_one_flaky_issue(self):
        ops = FakeOps(earlier_runs=['1', '2'])
        opened, _ = self.run_it([TEST], ops)
        self.assertEqual(len(opened), 1)
        title, body = ops.opened[0]
        self.assertEqual(title, 'Flaky: testOne')
        self.assertIn(flake_tally.flake_marker(TEST), body)

    def test_a_test_that_already_has_an_open_issue_gets_no_second(self):
        issue = {'body': flake_tally.flake_marker(TEST), 'author_association': 'OWNER', 'user': {'login': 'o'}}
        ops = FakeOps(earlier_runs=['1', '2'], open_issues=[issue])
        opened, _ = self.run_it([TEST], ops)
        self.assertEqual((opened, len(ops.posted)), ([], 1))

    def test_a_github_error_is_a_warning_and_never_turns_the_run_red(self):
        opened, out = self.run_it([TEST], FakeOps(fail_post=True))
        self.assertEqual(opened, [])
        self.assertIn('::warning title=linux-core-tally::', out)
        self.assertIn('HTTP 502', out)

    def test_the_cli_with_nothing_handed_over_posts_nothing(self):
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(tally.main([], environ={'RETRIED': ''}, ops=FakeOps()), 0)


if __name__ == '__main__':
    unittest.main()
