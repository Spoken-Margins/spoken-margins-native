"""Host tests for the lane open ping: the decision, the matching of waiting jobs to idle runners,
the 10-minute limit and the quiet failures. No network.

Run: python3 -m unittest ops/lane/test_sm_lane_open.py
"""
import datetime as dt
import json
import sys
import tempfile
import unittest
import urllib.error
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import sm_lane_open as o  # noqa: E402

NOW = dt.datetime(2026, 10, 9, 18, 30, tzinfo=dt.timezone.utc)
MAIN = ['self-hosted', 'macOS', 'ARM64', 'sm-lane']
BUILD = ['self-hosted', 'macOS', 'ARM64', 'sm-lane-build']
PRIORITY = ['self-hosted', 'macOS', 'ARM64', 'sm-lane-priority']


def runner(name, labels, busy=False, status='online'):
    return {'name': name, 'status': status, 'busy': busy, 'labels': [{'name': label} for label in labels]}


def job(name, status, labels):
    return {'name': name, 'status': status, 'labels': labels}


class FakeApi:
    """Recorded-shape responses: the runner list, the lane.yml runs by status, and each run's jobs."""

    def __init__(self, runners, runs=None, fail=None):
        self.runners, self.runs, self.fail = runners, runs or {}, fail
        self.runner_reads = 0

    def get(self, path):
        if self.fail:
            raise o.Unreadable(self.fail)
        if path.startswith('actions/runners'):
            self.runner_reads += 1
            runners = self.runners[min(self.runner_reads, len(self.runners)) - 1] \
                if self.runners and isinstance(self.runners[0], list) else self.runners
            return {'total_count': len(runners), 'runners': runners}
        if path.startswith('actions/runs?status='):
            status = path.split('status=')[1].split('&')[0]
            ids = [i for i, (state, _) in self.runs.items() if state == status]
            return {'total_count': len(ids), 'workflow_runs': [{'id': i} for i in ids]}
        if path.startswith('actions/runs/'):
            run_id = int(path.split('/')[2])
            jobs = self.runs[run_id][1]
            return {'total_count': len(jobs), 'jobs': jobs}
        raise AssertionError(path)


class Matching(unittest.TestCase):
    def test_idle_runners_are_online_unbusy_lane_runners_only(self):
        runners = [runner('a', MAIN), runner('b', BUILD, busy=True), runner('c', PRIORITY, status='offline'),
                   runner('vps', ['self-hosted', 'Linux', 'sm-vps'])]
        self.assertEqual(len(o.idle_runners(runners)), 1)

    def test_a_queued_job_takes_an_idle_runner_with_its_labels(self):
        idle = o.idle_runners([runner('a', MAIN), runner('b', BUILD)])
        waiting = o.waiting_jobs([job('lane', 'queued', ['self-hosted', 'macOS', 'sm-lane'])])
        self.assertEqual(o.spare_runners(idle, waiting), 1)

    def test_a_job_for_a_busy_runner_does_not_use_up_an_idle_one_of_another_kind(self):
        idle = o.idle_runners([runner('b', BUILD)])
        waiting = o.waiting_jobs([job('lane', 'queued', ['self-hosted', 'macOS', 'sm-lane'])])
        self.assertEqual(o.spare_runners(idle, waiting), 1)

    def test_every_idle_runner_wanted_leaves_none_spare(self):
        idle = o.idle_runners([runner('a', MAIN), runner('b', BUILD)])
        waiting = o.waiting_jobs([job('lane', 'queued', ['self-hosted', 'macOS', 'sm-lane']),
                                  job('automerge', 'queued', ['self-hosted', 'macOS', 'sm-lane-build'])])
        self.assertEqual(o.spare_runners(idle, waiting), 0)

    def test_only_jobs_queued_for_a_lane_runner_count(self):
        labels = ['self-hosted', 'macOS', 'sm-lane']
        waiting = o.waiting_jobs([job('lane', 'in_progress', labels), job('lane', 'completed', labels),
                                  job('lane', 'pending', labels), job('route', 'queued', ['self-hosted', 'Linux', 'sm-vps']),
                                  job('lane-open-lane', 'queued', ['sm-vps']),
                                  job('automerge', 'queued', labels)])
        self.assertEqual(len(waiting), 1)

    def test_the_compat_check_waiting_for_the_main_runner_counts(self):
        # shipped-build-compat.yml's job asks for [self-hosted, macOS, sm-lane], the same runner as `lane`.
        idle = o.idle_runners([runner('a', MAIN)])
        waiting = o.waiting_jobs([job('compat', 'queued', ['self-hosted', 'macOS', 'sm-lane'])])
        self.assertEqual(o.spare_runners(idle, waiting), 0)

    def test_label_case_does_not_matter(self):
        idle = o.idle_runners([runner('a', ['Self-Hosted', 'macOS', 'sm-lane'])])
        waiting = o.waiting_jobs([job('lane', 'queued', ['self-hosted', 'MACOS', 'sm-lane'])])
        self.assertEqual(o.spare_runners(idle, waiting), 0)


class Decide(unittest.TestCase):
    def test_sends_when_a_runner_is_spare(self):
        self.assertEqual(o.decide(1, 2, 1, NOW, None), (True, '2 idle, 1 waiting'))

    def test_quiet_when_nothing_is_spare(self):
        send, why = o.decide(0, 1, 1, NOW, None)
        self.assertFalse(send)
        self.assertIn('they take the slots', why)

    def test_one_ping_per_ten_minutes(self):
        for minutes, expected in [(0, False), (3, False), (9, False), (10, True), (45, True)]:
            with self.subTest(minutes=minutes):
                self.assertEqual(o.decide(1, 1, 0, NOW, NOW - dt.timedelta(minutes=minutes))[0], expected)

    def test_text_format_matches_what_the_coordinator_reads(self):
        self.assertEqual(o.ping_text(NOW, 2, 0), 'Lane open-20261009T1830Z: 2 free, 0 queued')


class Run(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.state = Path(self.temporary.name) / 'sub' / 'state.json'
        self.sent = []
        self.naps = []

    def send(self, url, token, text):
        self.sent.append((url, token, text))

    def go(self, api, url='https://relay', token='t', now=NOW, send=None, dry_run=False):
        return o.run(api, now, self.state, url, token, dry_run=dry_run, send=send or self.send,
                     sleep=self.naps.append)

    def test_an_idle_runner_and_an_empty_queue_send_one_ping(self):
        line = self.go(FakeApi([runner('a', MAIN), runner('b', BUILD)]))
        self.assertEqual(self.sent, [('https://relay', 't', 'Lane open-20261009T1830Z: 2 free, 0 queued')])
        self.assertIn('sent', line)

    def test_a_burst_of_finishes_is_one_ping(self):
        api = FakeApi([runner('a', MAIN)])
        for minutes in (0, 2, 5):
            self.go(api, now=NOW + dt.timedelta(minutes=minutes))
        self.assertEqual(len(self.sent), 1)
        self.go(api, now=NOW + dt.timedelta(minutes=11))
        self.assertEqual(len(self.sent), 2)

    def test_a_busy_lane_sends_nothing_and_rereads_for_a_runner_that_is_about_to_free_up(self):
        api = FakeApi([[runner('a', MAIN, busy=True)], [runner('a', MAIN, busy=True)], [runner('a', MAIN)]])
        self.go(api)
        self.assertEqual(len(self.sent), 1)
        self.assertEqual(self.naps, [o.SETTLE_SECONDS] * 2)

    def test_a_runner_that_stays_busy_sends_nothing(self):
        line = self.go(FakeApi([runner('a', MAIN, busy=True)]))
        self.assertEqual(self.sent, [])
        self.assertIn('not sent', line)

    def test_a_queued_mac_job_that_will_take_the_slot_sends_nothing(self):
        labels = ['self-hosted', 'macOS', 'sm-lane']
        api = FakeApi([runner('a', MAIN)], runs={7: ('in_progress', [job('route', 'completed', ['sm-vps']),
                                                                       job('lane', 'queued', labels)])})
        self.go(api)
        self.assertEqual(self.sent, [])

    def test_a_queued_compat_job_in_another_workflow_will_take_the_slot(self):
        api = FakeApi([runner('a', MAIN)], runs={9: ('queued', [job('compat', 'queued', ['self-hosted', 'macOS', 'sm-lane'])])})
        self.go(api)
        self.assertEqual(self.sent, [])

    def test_a_finished_run_does_not_count_as_waiting(self):
        api = FakeApi([runner('a', MAIN)], runs={7: ('completed', [job('lane', 'queued', ['sm-lane'])])})
        self.go(api)
        self.assertEqual(len(self.sent), 1)

    def test_no_relay_secrets_means_nothing_is_sent_and_nothing_is_read(self):
        api = FakeApi([runner('a', MAIN)], fail='must not be called')
        for url, token in [('', 't'), ('https://relay', ''), ('', '')]:
            self.assertIn('no relay set up', self.go(api, url=url, token=token))
        self.assertEqual(self.sent, [])

    def test_an_unreadable_lane_sends_nothing(self):
        line = self.go(FakeApi([], fail='HTTP 403'))
        self.assertEqual(self.sent, [])
        self.assertIn('could not read the lane', line)

    def test_a_failed_relay_sends_nothing_and_does_not_start_the_ten_minute_clock(self):
        def boom(*_):
            raise urllib.error.URLError('down')
        line = self.go(FakeApi([runner('a', MAIN)]), send=boom)
        self.assertIn('the relay failed', line)
        self.assertFalse(self.state.exists())
        self.go(FakeApi([runner('a', MAIN)]))
        self.assertEqual(len(self.sent), 1)

    def test_a_dry_run_sends_and_writes_nothing(self):
        line = self.go(FakeApi([runner('a', MAIN)]), dry_run=True)
        self.assertEqual(self.sent, [])
        self.assertFalse(self.state.exists())
        self.assertIn('would send "Lane open-20261009T1830Z: 1 free, 0 queued"', line)

    def test_a_damaged_state_file_reads_as_never_pinged(self):
        self.state.parent.mkdir(parents=True)
        for text in ('', 'not json', '{"last_ping_at": 5}', '{"other": 1}'):
            self.state.write_text(text)
            self.assertIsNone(o.load_last(self.state))

    def test_the_state_file_holds_the_last_ping_time(self):
        self.go(FakeApi([runner('a', MAIN)]))
        self.assertEqual(json.loads(self.state.read_text()), {'last_ping_at': '2026-10-09T18:30:00Z'})

    def test_more_than_one_page_of_runners_or_runs_is_unreadable_not_guessed(self):
        class Paged(FakeApi):
            def get(self, path):
                if path.startswith('actions/runners'):
                    return {'total_count': 150, 'runners': [runner('a', MAIN)]}
                return super().get(path)
        self.assertIn('could not read the lane', self.go(Paged([])))
        self.assertEqual(self.sent, [])


class FakeBranchApi(FakeApi):
    """The contents and git endpoints the data branch uses, with GitHub's compare-and-swap on a file's sha."""

    def __init__(self, runners, branch_exists=False, file=None, fail_write=None):
        super().__init__(runners)
        self.branch_exists, self.file, self.fail_write = branch_exists, file, fail_write
        self.writes = []

    def get(self, path):
        if path.startswith('contents/'):
            if not (self.branch_exists and self.file):
                raise o.Missing('404')
            content, sha = self.file
            return {'content': content, 'sha': sha}
        return super().get(path)

    def send(self, method, path, body):
        if self.fail_write:
            raise o.Unreadable(self.fail_write)
        self.writes.append((method, path))
        if path == 'git/trees':
            assert body == {'tree': []}, 'the state branch must start empty'
            return {'sha': 'tree1'}
        if path == 'git/commits':
            return {'sha': 'commit1'}
        if path == 'git/refs':
            if self.branch_exists:
                raise o.Conflict('422 ref exists')
            self.branch_exists = True
            return {}
        if path == 'contents/state.json':
            if body.get('sha', None) != (self.file[1] if self.file else None):
                raise o.Conflict('409')
            self.file = (body['content'], 'sha%d' % (len(self.writes)))
            return {}
        raise AssertionError(path)


class BranchStateTests(unittest.TestCase):
    def go(self, api, now=NOW):
        sent = []
        line = o.run(api, now, o.BranchState(api, 'lane-open-state'), 'https://relay', 't',
                     send=lambda *a: sent.append(a), sleep=lambda _: None)
        return line, sent

    def stamp(self, when):
        import base64
        return base64.b64encode(json.dumps({'last_ping_at': when}).encode()).decode()

    def test_the_first_ping_creates_an_empty_branch_and_the_state_file(self):
        api = FakeBranchApi([runner('a', MAIN)])
        line, sent = self.go(api)
        self.assertEqual(len(sent), 1, line)
        self.assertEqual([w[1] for w in api.writes], ['git/trees', 'git/commits', 'git/refs', 'contents/state.json'])

    def test_a_ping_ten_minutes_ago_blocks_the_next_and_an_older_one_does_not(self):
        recent = FakeBranchApi([runner('a', MAIN)], True, (self.stamp('2026-10-09T18:25:00Z'), 's1'))
        line, sent = self.go(recent)
        self.assertEqual((sent, recent.writes), ([], []), line)
        old = FakeBranchApi([runner('a', MAIN)], True, (self.stamp('2026-10-09T18:10:00Z'), 's1'))
        line, sent = self.go(old)
        self.assertEqual(len(sent), 1, line)
        self.assertEqual(old.writes, [('PUT', 'contents/state.json')])

    def test_two_runs_that_read_the_same_state_send_one_ping(self):
        api = FakeBranchApi([runner('a', MAIN)], True, (self.stamp('2026-10-09T18:00:00Z'), 's1'))
        first, second = o.BranchState(api, 'b'), o.BranchState(api, 'b')
        first.load(), second.load()
        self.assertTrue(first.claim(NOW))
        self.assertFalse(second.claim(NOW))

    def test_a_lost_race_sends_nothing_and_says_so(self):
        class Racy(FakeBranchApi):
            def get(self, path):
                doc = super().get(path) if path.startswith('contents/') else None
                if doc is not None:
                    self.file = (self.stamp('2026-10-09T18:29:00Z'), 'newer')    # someone writes after our read
                    return doc
                return super().get(path)
            stamp = BranchStateTests.stamp
        api = Racy([runner('a', MAIN)], True, (self.stamp('2026-10-09T18:00:00Z'), 's1'))
        line, sent = self.go(api)
        self.assertEqual(sent, [])
        self.assertIn('another run pinged first', line)

    def test_a_branch_made_by_another_run_a_moment_ago_is_used(self):
        class Late(FakeBranchApi):
            def send(self, method, path, body):
                if path == 'git/trees':
                    self.branch_exists = True    # the other run won the branch race
                return super().send(method, path, body)
        api = Late([runner('a', MAIN)])
        line, sent = self.go(api)
        self.assertEqual(len(sent), 1, line)

    def test_a_refused_tree_or_commit_is_unreadable_not_a_lost_race(self):
        # Only the ref POST can mean "another run made the branch"; a 422 on the tree or commit is a refusal, and it
        # must read as "could not record", never as "another run pinged first" (which would hide it forever).
        for refused in ('git/trees', 'git/commits'):
            class Refuses(FakeBranchApi):
                def send(self, method, path, body, refused=refused):
                    if path == refused:
                        raise o.Conflict('422 refused')
                    return super().send(method, path, body)
            api = Refuses([runner('a', MAIN)])
            line, sent = self.go(api)
            self.assertEqual(sent, [], refused)
            self.assertIn('could not record the ping', line, refused)
            self.assertNotIn('another run', line, refused)

    def test_a_write_the_token_may_not_make_sends_nothing(self):
        api = FakeBranchApi([runner('a', MAIN)], fail_write='HTTP Error 403')
        line, sent = self.go(api)
        self.assertEqual(sent, [])
        self.assertIn('could not record the ping', line)

    def test_a_dry_run_writes_nothing(self):
        api = FakeBranchApi([runner('a', MAIN)])
        line = o.run(api, NOW, o.BranchState(api, 'lane-open-state'), 'https://relay', 't', dry_run=True,
                     sleep=lambda _: None)
        self.assertEqual(api.writes, [])
        self.assertIn('would send', line)

    def test_a_failed_relay_keeps_the_ten_minutes_rather_than_risking_a_double_ping(self):
        api = FakeBranchApi([runner('a', MAIN)])

        def boom(*_):
            raise urllib.error.URLError('down')
        line = o.run(api, NOW, o.BranchState(api, 'lane-open-state'), 'https://relay', 't', send=boom,
                     sleep=lambda _: None)
        self.assertIn('the relay failed', line)
        self.assertIsNotNone(api.file)


class Tokens(unittest.TestCase):
    def test_the_runner_list_uses_the_runners_token_and_the_rest_the_workflow_token(self):
        seen = {}

        class Response:
            def read(self):
                return b'{}'

            def __enter__(self):
                return self

            def __exit__(self, *_):
                return False

        def fake_open(req, timeout=0):
            seen[req.full_url.split('/repos/x/y/')[1]] = req.get_header('Authorization')
            return Response()

        real = o.urllib.request.urlopen
        o.urllib.request.urlopen = fake_open
        self.addCleanup(lambda: setattr(o.urllib.request, 'urlopen', real))
        api = o.GitHub('x/y', 'workflow', 'admin')
        for path in ('actions/runners?per_page=100', 'actions/workflows/lane.yml/runs?status=queued',
                     'actions/runs/1/jobs'):
            api.get(path)
        self.assertEqual(seen, {'actions/runners?per_page=100': 'Bearer admin',
                                'actions/workflows/lane.yml/runs?status=queued': 'Bearer workflow',
                                'actions/runs/1/jobs': 'Bearer workflow'})
        self.assertEqual(o.GitHub('x/y', 'only').runners_token, 'only')


class Main(unittest.TestCase):
    def test_main_never_fails_the_job(self):
        import os
        old = dict(os.environ)
        self.addCleanup(lambda: (os.environ.clear(), os.environ.update(old)))
        os.environ.pop('SM_LANE_OPEN_URL', None)
        os.environ.pop('SM_LANE_OPEN_TOKEN', None)
        self.assertEqual(o.main(['--dry-run']), 0)


if __name__ == '__main__':
    unittest.main()
