"""Host tests for the dispatch backstop (#4866). Run: python3 -m unittest ops/dispatch-backstop/test_sm_dispatch_backstop.py"""
import datetime as dt
import http.client
import io
import json
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


def at(day, hhmm):
    hour, minute = (int(x) for x in hhmm.split(':'))
    return dt.datetime(2026, 11, day, hour, minute, tzinfo=dt.timezone.utc)


def run_at(day, hhmm, event='schedule', status='completed'):
    return {'created_at': at(day, hhmm).strftime('%Y-%m-%dT%H:%M:%SZ'), 'event': event, 'status': status,
            'conclusion': 'success' if status == 'completed' else None}


PHONE = b.SLOTS['phone-build.yml']  # 12:00 and 21:30 UTC


class SlotTests(unittest.TestCase):
    """#5154: a fixed-slot workflow is dispatched once its newest slot is an hour past with no run since."""

    def test_table_around_a_slot(self):
        cases = [
            # The real 2026-11-23: the 21:30 slot of 11-22 ran at 01:55, and the 12:00 slot never ran.
            ('12:00 slot 65m past, last run 01:55', at(23, '13:05'), run_at(23, '01:55'), True),
            ('12:00 slot only 50m past: inside the grace', at(23, '12:50'), run_at(23, '01:55'), False),
            ('12:00 slot exactly an hour past', at(23, '13:00'), run_at(23, '01:55'), True),
            ('the 12:00 slot ran late but ran', at(23, '13:05'), run_at(23, '12:40'), False),
            ('a hand-started run 20m before the slot covers it', at(23, '13:05'), run_at(23, '11:40', 'workflow_dispatch'), False),
            ('a run 40m before the slot does not', at(23, '13:05'), run_at(23, '11:20', 'workflow_dispatch'), True),
            # 11-22: the 12:00 slot ran at 18:58, then the 21:30 slot was 4 hours late.
            ('21:30 slot 90m past, last run 18:58', at(22, '23:00'), run_at(22, '18:58'), True),
            ('past midnight, 21:30 slot of the day before', at(23, '00:10'), run_at(22, '18:58'), True),
            ('past midnight, 21:30 slot ran', at(23, '00:10'), run_at(22, '21:45'), False),
            ('never ran', at(23, '13:05'), None, True),
        ]
        for name, now, run, expected in cases:
            with self.subTest(name):
                self.assertEqual(b.decide_slots(now, PHONE, run)[0], expected)

    def test_a_run_still_going_is_not_dispatched_over(self):
        for status in ('queued', 'in_progress', 'waiting'):
            with self.subTest(status):
                go, why = b.decide_slots(at(23, '13:05'), PHONE, run_at(23, '01:55', status=status))
                self.assertFalse(go)
                self.assertIn(f'still {status}', why)

    def test_the_reason_names_the_slot_and_how_late(self):
        go, why = b.decide_slots(at(23, '13:05'), PHONE, run_at(23, '01:55'))
        self.assertTrue(go)
        self.assertIn('the 12:00 slot is 65m past with no run', why)

    def test_main_t3_dispatches_on_its_interval_or_its_slot(self):
        slots, interval = b.SLOTS['main-t3.yml'], b.WORKFLOWS['main-t3.yml']
        # Inside 3 hours, but the 13:30 pre-phone-build slot is 70m past with no run since 12:50.
        self.assertTrue(b.decide_both(at(23, '14:40'), interval, slots, run_at(23, '12:50'))[0])
        # A run at 13:10 covers the 13:30 slot and is inside the interval.
        self.assertFalse(b.decide_both(at(23, '14:40'), interval, slots, run_at(23, '13:10'))[0])
        # Slot covered, interval past.
        self.assertTrue(b.decide_both(at(23, '16:40'), interval, slots, run_at(23, '13:10'))[0])

    def test_tick_acts_only_on_the_missed_slot(self):
        runs = {name: {'created_at': (at(23, '13:05') - dt.timedelta(minutes=5)).strftime('%Y-%m-%dT%H:%M:%SZ'),
                       'event': 'schedule', 'status': 'completed', 'conclusion': 'success'} for name in b.watched()}
        runs['phone-build.yml'] = run_at(23, '01:55')
        github, out = FakeGitHub(runs), io.StringIO()
        self.assertEqual(b.tick('tok', at(23, '13:05'), out=out, get=github), 0)
        self.assertEqual(github.posts, [('phone-build.yml', {'ref': 'main'})])
        line = [l for l in out.getvalue().splitlines() if 'phone-build.yml' in l]
        self.assertEqual(len(line), 1)
        self.assertIn('dispatched', line[0])

    def test_tick_leaves_a_fresh_slot_alone(self):
        github, out = FakeGitHub({'phone-build.yml': run_at(23, '12:40')}), io.StringIO()
        b.tick('tok', at(23, '13:05'), out=out, get=github, workflows={}, slots={'phone-build.yml': PHONE})
        self.assertEqual(github.posts, [])
        self.assertIn('covers the 12:00 slot', out.getvalue())


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
        runs = {name: {'created_at': ago(5), 'event': 'schedule'} for name in b.watched()}  # every event counts for these
        runs['merge-stall.yml'] = {'created_at': ago(50), 'event': 'schedule'}
        github, lines, failures = self.run_tick(runs)
        self.assertEqual(github.posts, [('merge-stall.yml', {'ref': 'main'})])
        self.assertEqual(len(lines), len(b.watched()))
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
        self.assertEqual(sorted(w for w, _ in github.posts), sorted(set(b.watched()) - {'claude-audit.yml'}))
        self.assertIn('claude-audit.yml FAILED', lines[0])

    def test_a_malformed_answer_is_a_failure_not_a_crash(self):
        out = io.StringIO()
        failures = b.tick('tok', NOW, out=out, get=lambda *a, **k: {'unexpected': 1}, workflows={'merge-stall.yml': 15})
        self.assertEqual(failures, 1)
        self.assertIn('FAILED', out.getvalue())


def refused(code=403, message='Resource not accessible by personal access token'):
    return urllib.error.HTTPError('https://api.github.com/x', code, 'Forbidden', {},
                                  io.BytesIO(json.dumps({'message': message}).encode()))


class FailureTests(unittest.TestCase):
    """#4937: the backstop failed in ways nobody could see or that stopped the whole tick."""

    def test_a_refused_token_falls_back_to_the_next(self):
        posts = []

        def get(method, path, token, body=None):
            if token == 'read-only':
                raise refused()
            if method == 'POST':
                posts.append(token)
                return None
            return {'workflow_runs': []}
        out = io.StringIO()
        failures = b.tick(['read-only', 'dial'], NOW, out=out, get=get, workflows={'merge-stall.yml': 15})
        self.assertEqual((failures, posts), (0, ['dial']))
        self.assertIn('dispatched', out.getvalue())

    def test_a_refusal_with_no_other_token_says_what_the_token_needs(self):
        def get(method, path, token, body=None):
            if method == 'POST':
                raise refused()
            return {'workflow_runs': []}
        out = io.StringIO()
        self.assertEqual(b.tick(['only'], NOW, out=out, get=get, workflows={'merge-stall.yml': 15}), 1)
        line = out.getvalue()
        self.assertIn('HTTP 403 Resource not accessible by personal access token', line)
        self.assertIn('actions: write', line)

    def test_other_http_errors_are_not_retried_with_another_token(self):
        seen = []

        def get(method, path, token, body=None):
            seen.append(token)
            raise refused(422, 'Workflow does not have workflow_dispatch trigger')
        out = io.StringIO()
        self.assertEqual(b.tick(['a', 'b'], NOW, out=out, get=get, workflows={'merge-stall.yml': 15}), 1)
        self.assertEqual(seen, ['a'])
        self.assertIn('HTTP 422 Workflow does not have workflow_dispatch trigger', out.getvalue())
        self.assertNotIn('actions: write', out.getvalue())

    def test_a_dropped_connection_is_a_failure_and_the_other_workflows_still_run(self):
        calls = []

        def get(method, path, token, body=None):
            calls.append(path)
            if 'claude-audit' in path:
                raise http.client.RemoteDisconnected('Remote end closed connection without response')
            if 'merge-stall' in path:
                raise http.client.IncompleteRead(b'')
            return None if method == 'POST' else {'workflow_runs': []}
        out = io.StringIO()
        self.assertEqual(b.tick('tok', NOW, out=out, get=get), 2)
        self.assertEqual(sum('/dispatches' in c for c in calls), len(b.watched()) - 2)

    def test_a_run_still_going_is_not_dispatched_over(self):
        for status in ('queued', 'in_progress', 'waiting'):
            with self.subTest(status):
                run = {'created_at': ago(40), 'event': 'schedule', 'status': status, 'conclusion': None}
                go, why = b.decide(NOW, 15, run)
                self.assertFalse(go)
                self.assertIn(f'still {status}', why)
        done = {'created_at': ago(40), 'event': 'schedule', 'status': 'completed', 'conclusion': 'success'}
        self.assertTrue(b.decide(NOW, 15, done)[0])

    def test_every_distinct_token_is_read_in_order(self):
        import os
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            first, second = Path(tmp) / 'a', Path(tmp) / 'b'
            first.write_text('dispatch\n')
            second.write_text('dial\n')
            saved = b.TOKEN_FILES, os.environ.pop('SM_DISPATCH_GITHUB_TOKEN', None)
            try:
                b.TOKEN_FILES = (first, second, Path(tmp) / 'missing')
                self.assertEqual(b.read_tokens(), ['dispatch', 'dial'])
                second.write_text('dispatch')
                self.assertEqual(b.read_tokens(), ['dispatch'])
                os.environ['SM_DISPATCH_GITHUB_TOKEN'] = 'env'
                self.assertEqual(b.read_tokens(), ['env', 'dispatch'])
                b.TOKEN_FILES = (Path(tmp) / 'missing',)
                os.environ.pop('SM_DISPATCH_GITHUB_TOKEN')
                with self.assertRaises(SystemExit):
                    b.read_tokens()
            finally:
                b.TOKEN_FILES = saved[0]
                os.environ.pop('SM_DISPATCH_GITHUB_TOKEN', None)
                if saved[1] is not None:
                    os.environ['SM_DISPATCH_GITHUB_TOKEN'] = saved[1]


if __name__ == '__main__':
    unittest.main()
