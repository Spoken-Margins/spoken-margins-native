"""Host tests for the dispatch backstop (#4866). Run: python3 -m unittest ops/dispatch-backstop/test_sm_dispatch_backstop.py"""
import datetime as dt
import io
import sys
import unittest
import urllib.error
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import sm_dispatch_backstop as b  # noqa: E402

NOW = dt.datetime(2026, 11, 21, 12, 0, 0, tzinfo=dt.timezone.utc)


def ago(minutes):
    return (NOW - dt.timedelta(minutes=minutes)).strftime('%Y-%m-%dT%H:%M:%SZ')


class FakeGitHub:
    """Answers the runs list from a table and records dispatches. A workflow named in `broken` raises."""

    def __init__(self, runs, broken=()):
        self.runs, self.broken, self.posts = runs, set(broken), []

    def __call__(self, method, path, token, body=None):
        workflow = path.split('/workflows/')[1].split('/')[0].split('?')[0]
        if workflow in self.broken:
            raise urllib.error.URLError('boom')
        if method == 'POST':
            assert path.endswith('/dispatches'), path
            self.posts.append((workflow, body))
            return None
        found = self.runs.get(workflow)
        return {'workflow_runs': [found] if found else []}


class DecideTests(unittest.TestCase):
    def test_table_around_the_interval(self):
        cases = [
            ('never ran', 15, None, True),
            ('just ran', 15, {'created_at': ago(0), 'event': 'push'}, False),
            ('well inside', 15, {'created_at': ago(10), 'event': 'workflow_run'}, False),
            ('just inside the jitter margin', 15, {'created_at': ago(12), 'event': 'workflow_run'}, False),
            ('at the margin, so the next tick is not skipped for timer jitter', 15, {'created_at': ago(13), 'event': 'schedule'}, True),
            ('exactly the interval', 15, {'created_at': ago(15), 'event': 'schedule'}, True),
            ('long past', 15, {'created_at': ago(600), 'event': 'schedule'}, True),
            ('hourly job ran 40m ago', 60, {'created_at': ago(40), 'event': 'pull_request'}, False),
            ('hourly job ran 59m ago', 60, {'created_at': ago(59), 'event': 'pull_request'}, True),
            ('hourly job ran 61m ago', 60, {'created_at': ago(61), 'event': 'pull_request'}, True),
            ('3-hourly job ran 2h ago', 180, {'created_at': ago(120), 'event': 'push'}, False),
            ('3-hourly job ran 3h10 ago', 180, {'created_at': ago(190), 'event': 'schedule'}, True),
        ]
        for name, interval, run, expected in cases:
            with self.subTest(name):
                self.assertEqual(b.decide(NOW, interval, run)[0], expected)

    def test_any_event_counts_as_a_run(self):
        for event in ('push', 'schedule', 'workflow_dispatch', 'workflow_run', 'pull_request', None):
            with self.subTest(event):
                run = {'created_at': ago(3), 'event': event, 'conclusion': 'success'}
                self.assertFalse(b.decide(NOW, 15, run)[0])


class NewestRunTests(unittest.TestCase):
    def pick(self, runs):
        return b.newest_run('merge-stall.yml', 'tok', lambda *a, **k: {'workflow_runs': runs})

    def test_skipped_runs_do_not_hold_the_backstop_off(self):
        # A busy merge queue creates a skipped run every few minutes; counting them would starve the backstop.
        skipped = [{'created_at': ago(m), 'event': 'workflow_run', 'conclusion': 'skipped'} for m in (1, 4, 7)]
        worked = {'created_at': ago(40), 'event': 'schedule', 'conclusion': 'success'}
        self.assertEqual(self.pick(skipped + [worked]), worked)
        self.assertIsNone(self.pick(skipped))
        self.assertTrue(b.decide(NOW, 15, self.pick(skipped + [worked]))[0])

    def test_the_bridge_counts_only_sweeping_events(self):
        # One-PR runs (pull_request_target) must not hold the sweep off: a PR armed with a token-made label starts no
        # event and waits for the sweep, and recent one-PR runs on other PRs are what a busy queue makes.
        def runs_for(workflow, runs):
            return b.newest_run(workflow, 'tok', lambda *a, **k: {'workflow_runs': runs})
        one_pr = [{'created_at': ago(m), 'event': 'pull_request_target', 'conclusion': 'success'} for m in (3, 14, 25, 36)]
        sweep = {'created_at': ago(40), 'event': 'schedule', 'conclusion': 'success'}
        found = runs_for('merge-queue-label-bridge.yml', one_pr + [sweep])
        self.assertEqual(found, sweep)
        self.assertTrue(b.decide(NOW, 15, found)[0])  # dispatched despite four recent one-PR runs
        self.assertIsNone(runs_for('merge-queue-label-bridge.yml', one_pr))
        manual = {'created_at': ago(5), 'event': 'workflow_dispatch', 'conclusion': 'success'}
        self.assertEqual(runs_for('merge-queue-label-bridge.yml', one_pr + [manual]), manual)
        # Every other workflow counts every event.
        for name in ('claude-audit.yml', 'merge-stall.yml', 'lane-conflicts.yml', 'main-t3.yml'):
            self.assertEqual(runs_for(name, one_pr + [sweep]), one_pr[0], name)

    def test_a_queued_or_running_run_counts(self):
        running = {'created_at': ago(2), 'event': 'workflow_run', 'conclusion': None, 'status': 'in_progress'}
        self.assertEqual(self.pick([running]), running)
        self.assertFalse(b.decide(NOW, 15, running)[0])

    def test_failed_and_cancelled_runs_count(self):
        for conclusion in ('failure', 'cancelled', 'success', 'timed_out'):
            run = {'created_at': ago(2), 'event': 'push', 'conclusion': conclusion}
            self.assertEqual(self.pick([run]), run, conclusion)


class TickTests(unittest.TestCase):
    def run_tick(self, runs, **kwargs):
        github, out = FakeGitHub(runs, kwargs.pop('broken', ())), io.StringIO()
        failures = b.tick('tok', NOW, out=out, get=github, **kwargs)
        return github, out.getvalue().splitlines(), failures

    def test_only_overdue_workflows_dispatch_and_each_gets_one_line(self):
        runs = {name: {'created_at': ago(5), 'event': 'schedule'} for name in b.WORKFLOWS}  # every event counts for these
        runs['merge-stall.yml'] = {'created_at': ago(50), 'event': 'schedule'}
        github, lines, failures = self.run_tick(runs)
        self.assertEqual(github.posts, [('merge-stall.yml', {'ref': 'main'})])
        self.assertEqual(len(lines), len(b.WORKFLOWS))
        self.assertEqual(failures, 0)
        self.assertEqual([l for l in lines if ' dispatched: ' in l], [lines[1]])
        self.assertIn('merge-stall.yml dispatched: last run 50m ago (schedule), past 15m', lines[1])
        self.assertTrue(all(' skipped: ' in l for i, l in enumerate(lines) if i != 1))

    def test_a_workflow_that_never_ran_dispatches(self):
        github, lines, _ = self.run_tick({}, workflows={'lane-conflicts.yml': 60})
        self.assertEqual(github.posts, [('lane-conflicts.yml', {'ref': 'main'})])
        self.assertIn('dispatched: no worked run yet', lines[0])

    def test_dry_run_dispatches_nothing_and_says_so(self):
        github, lines, _ = self.run_tick({}, dry_run=True)
        self.assertEqual(github.posts, [])
        self.assertTrue(all(' would dispatch: ' in l for l in lines))

    def test_one_failure_does_not_stop_the_others_and_is_counted(self):
        github, lines, failures = self.run_tick({}, broken=['claude-audit.yml'])
        self.assertEqual(failures, 1)
        self.assertEqual(sorted(w for w, _ in github.posts), sorted(set(b.WORKFLOWS) - {'claude-audit.yml'}))
        self.assertIn('claude-audit.yml FAILED', lines[0])

    def test_a_malformed_answer_is_a_failure_not_a_crash(self):
        out = io.StringIO()
        failures = b.tick('tok', NOW, out=out, get=lambda *a, **k: {'unexpected': 1}, workflows={'merge-stall.yml': 15})
        self.assertEqual(failures, 1)
        self.assertIn('FAILED', out.getvalue())


if __name__ == '__main__':
    unittest.main()
