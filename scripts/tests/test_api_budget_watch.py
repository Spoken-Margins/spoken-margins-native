"""#4990: the owner hears at 70% of the workflow token's API budget, once per window, for a few calls at most."""
import json
from pathlib import Path
import subprocess
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import api_budget_watch as watch  # noqa: E402

NOW = 1_795_360_000.0
RESET = int(NOW) + 25 * 60
BOT = {'login': watch.BOT}


def fake(used, limit=1000, issues=(), comments=(), runs=(), fail=()):
    """A GitHub whose `gh` answers from these; returns (github, posted bodies)."""
    posted = []

    def run(cmd, **kwargs):
        path = cmd[2]
        if any(word in path for word in fail):
            return subprocess.CompletedProcess(cmd, 1, '', 'HTTP 403')
        if '-X' in cmd:
            posted.append((path, [a for a in cmd if a.startswith(('title=', 'body='))]))
            answer = {'number': 77}
        elif path == 'rate_limit':
            answer = {'resources': {'core': {'used': used, 'limit': limit, 'reset': RESET}}}
        elif '/comments' in path:
            answer = list(comments)
        elif '/actions/runs' in path:
            answer = {'workflow_runs': list(runs)}
        else:
            answer = list(issues)
        return subprocess.CompletedProcess(cmd, 0, json.dumps(answer), '')
    return watch.GitHub('o/r', run=run), posted


STANDING = {'number': 50, 'user': BOT, 'body': watch.ISSUE_MARKER + ' text'}
RUNS = ([{'name': 'claude-audit', 'conclusion': 'success'}] * 3 + [{'name': 'merge-stall', 'conclusion': 'failure'}] * 2
        + [{'name': 'rerun-cancelled', 'conclusion': 'skipped'}] * 9)


class ThresholdTests(unittest.TestCase):
    def test_the_warning_starts_at_seventy_percent(self):
        table = {(699, 1000): False, (700, 1000): True, (1000, 1000): True, (0, 1000): False, (0, 0): False,
                 (10499, 15000): False, (10500, 15000): True}
        for (used, limit), expected in table.items():
            self.assertEqual(watch.should_warn(used, limit), expected, (used, limit))


class CallsTests(unittest.TestCase):
    """The job must not spend the budget it watches: these pin its calls per run."""

    def test_below_the_threshold_only_the_free_read_is_made(self):
        github, posted = fake(used=400)
        line = watch.watch(github, NOW)
        self.assertEqual(github.calls, ['rate_limit'])
        self.assertEqual(posted, [])
        self.assertEqual(line, 'API budget: 400 of 1000 calls used (40%), resets in 25 minutes.')

    def test_the_first_warning_of_a_window_is_four_counted_calls(self):
        github, posted = fake(used=750, issues=[STANDING], runs=RUNS)
        line = watch.watch(github, NOW)
        self.assertEqual(len(github.calls) - 1, 4, github.calls)  # issues, comments, runs, the post
        self.assertEqual(posted[0][0], 'repos/o/r/issues/50/comments')
        self.assertIn('Warned on #50', line)

    def test_a_later_run_in_the_window_is_two_counted_calls_and_posts_nothing(self):
        said = {'user': BOT, 'body': 'text\n' + watch.window_marker(RESET)}
        github, posted = fake(used=900, issues=[STANDING], comments=[said], runs=RUNS)
        line = watch.watch(github, NOW)
        self.assertEqual(len(github.calls) - 1, 2, github.calls)
        self.assertEqual(posted, [])
        self.assertIn('Already said on #50', line)

    def test_with_no_standing_issue_one_is_opened_still_four_counted_calls(self):
        github, posted = fake(used=750, runs=RUNS)
        watch.watch(github, NOW)
        self.assertEqual(len(github.calls) - 1, 4, github.calls)  # issues, runs, the new issue, the post
        self.assertEqual([p[0] for p in posted], ['repos/o/r/issues', 'repos/o/r/issues/77/comments'])
        self.assertIn(f'title={watch.ISSUE_TITLE}', posted[0][1])


class DedupeTests(unittest.TestCase):
    def test_one_comment_per_window(self):
        mine = {'user': BOT, 'body': watch.window_marker(RESET)}
        self.assertTrue(watch.already_warned([mine], RESET))
        self.assertFalse(watch.already_warned([mine], RESET + 3600))  # the next window warns again
        self.assertFalse(watch.already_warned([], RESET))

    def test_a_strangers_marker_does_not_silence_the_warning(self):
        theirs = {'user': {'login': 'stranger'}, 'body': watch.window_marker(RESET)}
        self.assertFalse(watch.already_warned([theirs], RESET))

    def test_only_the_bots_own_marked_issue_is_the_standing_one(self):
        others = [{'number': 1, 'user': {'login': 'stranger'}, 'body': watch.ISSUE_MARKER},
                  {'number': 2, 'user': BOT, 'body': 'Merging has stalled'},
                  {'number': 3, 'user': BOT, 'body': watch.ISSUE_MARKER, 'pull_request': {}}]
        self.assertIsNone(watch.find_issue(others))
        self.assertEqual(watch.find_issue(others + [STANDING]), 50)


class MessageTests(unittest.TestCase):
    def test_the_warning_mentions_the_owner_gives_the_numbers_and_ranks_the_workflows(self):
        body = watch.warning_body(750, 1000, RESET, NOW, RUNS, len(RUNS))
        self.assertTrue(body.startswith(f'@{watch.OWNER_LOGIN} '))
        self.assertIn('750 of 1000 calls used (75%), resets in 25 minutes.', body)
        self.assertIn('1. `claude-audit`: 3 runs\n2. `merge-stall`: 2 runs', body)
        self.assertNotIn('rerun-cancelled', body)  # skipped runs started no job
        self.assertIn('of the newest 14 runs', body)
        self.assertTrue(body.endswith(watch.window_marker(RESET)))

    def test_runs_that_could_not_be_read_do_not_stop_the_warning(self):
        github, posted = fake(used=750, issues=[STANDING], fail=('/actions/runs',))
        watch.watch(github, NOW)
        self.assertIn('The recent runs could not be read.', posted[0][1][0])

    def test_the_owner_login_matches_the_tap_alert(self):
        import owner_tap_alert
        self.assertEqual(watch.OWNER_LOGIN, owner_tap_alert.OWNER_LOGIN)


class JobTests(unittest.TestCase):
    def test_a_failure_never_fails_the_job(self):
        github, _ = fake(used=750, fail=('rate_limit',))
        self.assertEqual(watch.main(['--repo', 'o/r'], github=github), 0)

    def test_a_crash_inside_the_watch_never_fails_the_job_either(self):
        class Broken:
            repo = 'o/r'

            def api(self, *args):
                raise KeyError('resources')
        self.assertEqual(watch.main(['--repo', 'o/r'], github=Broken()), 0)

    def test_it_is_a_step_of_the_stall_job_before_the_stall_look(self):
        text = (Path(watch.__file__).resolve().parents[1] / '.github/workflows/merge-stall.yml').read_text()
        self.assertEqual(text.count('scripts/api_budget_watch.py'), 2)  # the sparse checkout and the step
        self.assertLess(text.index('- name: Read the API budget'), text.index('- name: Look for a stall'))


if __name__ == '__main__':
    unittest.main()
