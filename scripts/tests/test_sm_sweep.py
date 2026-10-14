"""Wake sweep fixtures: six findings, conservative release, live collection and apply boundary."""
import contextlib
import copy
import datetime as dt
import importlib.util
import io
import json
from pathlib import Path
import re
import unittest
from unittest.mock import patch

SCRIPTS = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('sm_sweep', SCRIPTS / 'sm_sweep.py')
sweep = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sweep)
NOW = dt.datetime(2026, 10, 14, 18, tzinfo=dt.timezone.utc)
OLD = '2026-10-14T10:00:00Z'
RECENT = '2026-10-14T17:30:00Z'


def labels(*names):
    return [{'name': n} for n in names]


def comment(number, body, at=OLD, cid=1):
    return dict(id=cid, body=body, created_at=at, updated_at=at,
                issue_url=f'https://api.github.com/repos/{sweep.REPO}/issues/{number}',
                html_url=f'https://github.com/{sweep.REPO}/issues/{number}#issuecomment-{cid}')


def issue(number=1, at=OLD):
    return dict(number=number, state='open', created_at=OLD, updated_at=at,
                labels=labels('in-progress'), comments=[], timeline=[], commit_times=[], evidence_complete=True)


def pr(number=10, *names):
    return dict(number=number, state='open', title='Fix', body='', created_at=OLD, updated_at=OLD,
                labels=labels(*names), head={'sha': 'abcdef0123456789', 'ref': 'ws/99-fix'},
                base={'ref': 'next'}, comments=[], timeline=[], commit_times=[])


def snapshot():
    return dict(dial_body='**Mode**\n- [x] Cloud max\n**Threads**\n- [x] 3\n',
                issues=[], pulls=[], comments=[], events=[],
                runtime={'observed_at': RECENT, 'mac_idle': True, 'test_desk_running': False})


class RuleTests(unittest.TestCase):
    def rules(self, data):
        return [a['rule'] for a in sweep.sweep(data, NOW)['actions']]

    def test_all_six_findings_from_review_fixture(self):
        data = snapshot()
        mac = issue(2)
        mac['labels'] = labels('ready', 'where:mac')
        data['issues'] = [issue(), mac]
        red = pr(1575, 'automerge')
        red['checks'] = [{'id': 5, 'name': 'host', 'conclusion': 'failure'}]
        data['pulls'] = [red, pr(1551), pr(1550, 'needs-mac')]
        data['comments'] = [comment(1551, '/lane T4\ncommit: abcdef0', cid=2),
                            comment(2, 'Claimed by project thread "Codex worker 1"', RECENT, 3)]
        self.assertEqual(set(self.rules(data)),
                         {'free-slots', 'mac-idle', 'stale-claim', 'red-head', 't4-wait', 'needs-mac'})
        report = sweep.sweep(data, NOW)
        self.assertEqual(report['provider_active'], {'claude': 0, 'codex': 1})
        self.assertIn('Fill 3 Claude slots', report['actions'][0]['message'])

    def test_recent_claim_not_released_six_hour_regression(self):
        for at in (RECENT, '2026-10-14T12:00:00Z', '2026-10-14T12:00:01Z'):
            with self.subTest(at=at):
                self.assertFalse(sweep.stale(issue(at=at), [], [], NOW))
        self.assertTrue(sweep.stale(issue(at='2026-10-14T11:59:59Z'), [], [], NOW))

    def test_any_recent_comment_commit_or_push_preserves_claim(self):
        variants = [dict(comments=[comment(1, 'Working', RECENT)]),
                    dict(comments=[dict(comment(1, 'Edited'), updated_at=RECENT)]),
                    dict(commit_times=[RECENT]),
                    dict(timeline=[{'event': 'referenced', 'created_at': RECENT}])]
        for fields in variants:
            item = dict(issue(), **fields)
            self.assertFalse(sweep.stale(item, [], [], NOW), fields)
        event = {'type': 'PushEvent', 'created_at': RECENT,
                 'payload': {'ref': 'refs/heads/ws/1-fix'}}
        self.assertFalse(sweep.stale(issue(), [], [event], NOW))
        event['payload']['ref'] = 'refs/heads/ws/10-other'
        self.assertTrue(sweep.stale(issue(), [], [event], NOW))

    def test_open_pr_always_protects_claim_including_non_closing_reference(self):
        for fields in ({'body': 'Related to #1'}, {'head': {'ref': 'ws/1-fix'}},
                       {'title': 'Fix https://github.com/x/y/issues/1'}):
            pull = dict(pr(), **fields)
            self.assertFalse(sweep.stale(issue(), [pull], [], NOW))
        self.assertFalse(sweep.stale(dict(issue(), open_pr=True), [], [], NOW))
        self.assertTrue(sweep.stale(issue(), [dict(pr(), body='#10')], [], NOW))
        self.assertFalse(sweep.stale(issue(), [dict(pr(), body='#1', state='closed', updated_at=RECENT)], [], NOW))

    def test_incomplete_invalid_or_missing_activity_holds_claim(self):
        for fields in (dict(evidence_complete=False), dict(updated_at=None),
                       dict(commit_times=['bad']), dict(comments=[{'body': 'working'}]),
                       dict(state='closed'), dict(labels=labels('ready'))):
            self.assertFalse(sweep.stale(dict(issue(), **fields), [], [], NOW), fields)

    def test_provider_halt_off_and_full_slots(self):
        data = snapshot()
        data['comments'] = [comment(337, '**HALT (usage breaker: Codex)**', RECENT)]
        self.assertIn('free-slots', self.rules(data))
        data['comments'][0]['body'] = '**HALT (usage breaker: Claude)**'
        self.assertNotIn('free-slots', self.rules(data))
        data['comments'] = [comment(1, f'Claimed by project thread "Thread {n}"', RECENT, n)
                            for n in range(3)]
        self.assertNotIn('free-slots', self.rules(data))
        data['dial_body'] = '**Mode**\n- [x] Off\n**Threads**\n- [x] 3'
        data['comments'] = []
        self.assertNotIn('free-slots', self.rules(data))

    def test_busy_unknown_and_old_machine_observations(self):
        data = snapshot()
        data['issues'] = [dict(issue(), labels=labels('ready', 'where:mac'))]
        data['runtime']['mac_idle'] = False
        self.assertNotIn('mac-idle', self.rules(data))
        data['runtime']['observed_at'] = OLD
        self.assertIn('check-mac', self.rules(data))
        self.assertNotIn('mac-idle', self.rules(data))
        data['comments'] = [comment(337, '**12:30 (Mac tick)**\n- runner: 0 running, 0 queued, 0 pending\n'
                                  '- simulator slot: free', RECENT)]
        self.assertIn('mac-idle', self.rules(data))
        data['comments'][0]['body'] = data['comments'][0]['body'].replace('0 queued', '1 queued')
        self.assertNotIn('mac-idle', self.rules(data))

    def test_current_head_failures_and_reruns(self):
        pull = pr(10, 'automerge')
        pull['comments'] = [comment(10, 'Lane report pr10-r1 — FAIL\ncommit deadbee')]
        self.assertFalse(sweep.red_head(pull))
        pull['comments'] = [comment(10, 'Lane report pr10-r1 — FAIL\ncommit abcdef0999999999')]
        self.assertFalse(sweep.red_head(pull))
        pull['comments'].append(comment(10, 'Lane report pr10-r2 — FAIL\ncommit `abcdef0`', RECENT, 2))
        self.assertTrue(sweep.red_head(pull))
        pull['comments'].append(comment(10, 'Lane report pr10-r3 — PASS\ncommit abcdef0', '2026-10-14T17:40:00Z', 3))
        self.assertFalse(sweep.red_head(pull))
        pull['checks'] = [{'id': 1, 'name': 'host', 'conclusion': 'failure'},
                          {'id': 2, 'name': 'host', 'conclusion': 'success'}]
        self.assertFalse(sweep.red_head(pull))
        pull['status'] = {'state': 'error'}
        self.assertTrue(sweep.red_head(pull))

    def test_t4_running_answered_recent_and_round_two(self):
        data = snapshot()
        data['pulls'] = [dict(pr(1551), state='closed', merged_at=RECENT)]
        data['comments'] = [comment(1551, '/lane T4', cid=1)]
        self.assertIn('t4-wait', self.rules(data))
        data['runtime']['test_desk_running'] = True
        self.assertNotIn('t4-wait', self.rules(data))
        data['runtime']['test_desk_running'] = False
        data['comments'].append(comment(1551, 'Lane report (T4): PASS', RECENT, 2))
        self.assertNotIn('t4-wait', self.rules(data))
        data['comments'].append(comment(1551, '/lane T4', '2026-10-14T17:00:00Z', 3))
        self.assertNotIn('t4-wait', self.rules(data))
        data['comments'][2]['created_at'] = '2026-10-14T16:59:59Z'
        # report was after the request; a round two needs a report before its request
        data['comments'][1]['created_at'] = '2026-10-14T16:00:00Z'
        self.assertIn('t4-wait', self.rules(data))

    def test_finisher_label_age_notes_and_commits_not_pr_parity(self):
        data = snapshot()
        data['pulls'] = [pr(1550, 'needs-mac'), pr(1551, 'needs-mac')]
        actions = sweep.sweep(data, NOW)['actions']
        self.assertEqual([a['numbers'][0] for a in actions if a['rule'] == 'needs-mac'], [1550, 1551])
        for fields in (dict(timeline=[{'event': 'labeled', 'created_at': RECENT,
                                     'label': {'name': 'needs-mac'}}]),
                       dict(comments=[comment(1550, 'Mac finisher taking this PR.', RECENT)]),
                       dict(commit_times=[RECENT])):
            data['pulls'] = [dict(pr(1550, 'needs-mac'), **fields)]
            self.assertNotIn('needs-mac', self.rules(data))


class FakeGitHub:
    repo = sweep.REPO

    def __init__(self):
        self.item = issue()
        self.pulls = []
        self.events = []
        self.writes = []

    def pages(self, path, key=None):
        if path.startswith('pulls?'):
            return copy.deepcopy(self.pulls)
        if path == 'events':
            return self.events
        if path == 'branches':
            return []
        if path == 'issues/1/comments':
            return self.item['comments']
        if path == 'issues/1/timeline':
            return self.item['timeline']
        raise AssertionError(path)

    def request(self, path, method='GET', payload=None):
        if method != 'GET':
            self.writes.append((path, method, payload))
            return None
        if path == 'issues/1':
            return copy.deepcopy(self.item)
        raise AssertionError(path)


class BoundaryTests(unittest.TestCase):
    def setUp(self):
        self.original_local = sweep.local_commit_times
        self.local = patch.object(sweep, 'local_commit_times', return_value=[])
        self.local.start()
        self.addCleanup(self.local.stop)

    def report(self):
        data = snapshot()
        data['issues'] = [issue()]
        return sweep.sweep(data, NOW)

    def test_apply_only_releases_claim_and_preserves_other_labels(self):
        api = FakeGitHub()
        report = self.report()
        api.item['labels'].append({'name': 'where:mac'})
        sweep.apply_claims(api, report, NOW)
        self.assertEqual(report['released'], [1])
        self.assertEqual([(p, m) for p, m, _ in api.writes],
                         [('issues/1/comments', 'POST'), ('issues/1/labels', 'POST'),
                          ('issues/1/labels/in-progress', 'DELETE')])
        self.assertEqual(api.writes[1][2], {'labels': ['ready']})

    def test_fresh_comment_commit_pr_or_label_removal_prevents_apply(self):
        for fields, pulls in (({'comments': [comment(1, 'Working', RECENT)]}, []),
                              ({'updated_at': RECENT}, []),
                              ({}, [dict(pr(), body='#1')]),
                              ({'labels': labels('ready')}, [])):
            api = FakeGitHub()
            api.item.update(fields)
            api.pulls = pulls
            sweep.apply_claims(api, self.report(), NOW)
            self.assertEqual(api.writes, [])

    def test_referenced_commit_date_and_open_cross_reference_are_collected(self):
        api = FakeGitHub()
        api.item['timeline'] = [{'event': 'referenced', 'commit_id': 'abc', 'created_at': OLD},
                                {'event': 'cross-referenced', 'created_at': OLD, 'source': {'issue': {
                                    'pull_request': {'url': f'https://api.github.com/repos/{api.repo}/pulls/10'}}}}]
        original = api.request

        def request(path, *args):
            if path == 'commits/abc':
                return {'commit': {'committer': {'date': RECENT}}}
            if path == 'pulls/10':
                return {'state': 'open', 'updated_at': OLD}
            return original(path, *args)

        api.request = request
        item = sweep.activity(api, api.item)
        self.assertEqual(item['commit_times'], [RECENT, OLD])
        self.assertTrue(item['open_pr'])
        self.assertFalse(sweep.stale(item, [], [], NOW))

    def test_unpushed_local_commit_prevents_release(self):
        api = FakeGitHub()
        sweep.local_commit_times.return_value = [RECENT]
        sweep.apply_claims(api, self.report(), NOW)
        self.assertEqual(api.writes, [])

    def test_recent_remote_commit_without_issue_reference_or_push_event_holds_claim(self):
        api = FakeGitHub()
        original_pages, original_request = api.pages, api.request

        def pages(path, key=None):
            if path == 'branches':
                return [{'name': 'ws/1-fix', 'commit': {'sha': 'abc'}}]
            return original_pages(path, key)

        def request(path, *args):
            if path == 'commits/abc':
                return {'commit': {'committer': {'date': RECENT}}}
            return original_request(path, *args)

        api.pages, api.request = pages, request
        sweep.apply_claims(api, self.report(), NOW)
        self.assertEqual(api.writes, [])

    def test_local_branch_matching_is_exact_and_read_only(self):
        result = type('Result', (), {'returncode': 0, 'stdout':
                      f'refs/heads/ws/1-fix {RECENT}\nrefs/heads/ws/10-other {RECENT}\n'
                      f'refs/remotes/origin/ws/1-fix {OLD}\n'})()
        with patch.object(sweep.subprocess, 'run', return_value=result) as run:
            self.assertEqual(self.original_local(1), [RECENT, OLD])
        self.assertEqual(run.call_args[0][0][1], 'for-each-ref')

    def test_pagination_does_not_drop_second_page(self):
        api = sweep.GitHub()
        with patch.object(api, 'request', side_effect=[list(range(100)), [100]]) as request:
            self.assertEqual(api.pages('issues?state=open'), list(range(101)))
        self.assertIn('&per_page=100&page=2', request.call_args[0][0])

    def test_event_cap_holds_claim_when_six_hour_push_window_is_incomplete(self):
        events = [{'created_at': RECENT, 'type': 'PushEvent', 'payload': {'ref': 'refs/heads/other'}}] * 300
        self.assertFalse(sweep.events_cover_window(events, NOW))
        api = FakeGitHub()
        api.events = events
        sweep.apply_claims(api, self.report(), NOW)
        self.assertEqual(api.writes, [])
        self.assertTrue(sweep.events_cover_window(events[:299], NOW))
        events = events + [{'created_at': OLD}]
        self.assertTrue(sweep.events_cover_window(events, NOW))
        api = sweep.GitHub()
        with patch.object(api, 'request', return_value=events[:100]) as request:
            self.assertEqual(len(api.pages('events')), 300)
            self.assertEqual(request.call_count, 3)

    def test_default_read_only_json_and_api_failure(self):
        api = FakeGitHub()
        with patch.object(sweep, 'collect', return_value=snapshot()), contextlib.redirect_stdout(io.StringIO()) as out:
            self.assertEqual(sweep.main(['--json'], api, NOW), 0)
        self.assertIn('actions', json.loads(out.getvalue()))
        self.assertEqual(api.writes, [])
        with patch.object(sweep, 'collect', side_effect=RuntimeError('offline')), \
                contextlib.redirect_stderr(io.StringIO()) as err:
            self.assertEqual(sweep.main(['--apply'], api, NOW), 2)
        self.assertIn('Do not treat this as an empty queue', err.getvalue())
        self.assertEqual(api.writes, [])

    def test_collector_queries_head_and_keeps_old_open_and_queued_merged_t4(self):
        class Inventory(FakeGitHub):
            def __init__(self):
                super().__init__()
                self.paths = []
                self.pulls = [pr(10, 'automerge'), pr(11, 'needs-mac')]

            def request(self, path, *args):
                self.paths.append(path)
                if path == 'issues/589':
                    return {'body': snapshot()['dial_body']}
                if path == 'pulls/12':
                    return dict(pr(12), state='closed', merged_at=OLD)
                if path == 'commits/abcdef0123456789/status':
                    return {'state': 'failure'}
                return super().request(path, *args)

            def pages(self, path, key=None):
                self.paths.append(path)
                if path.startswith('issues/comments?'):
                    return []
                if path == 'issues?state=open':
                    return [issue(at=RECENT)]  # fresh claims avoid expensive histories
                if path == 'issues?state=closed&labels=lane:queued':
                    return [{'number': 12, 'pull_request': {}}]
                if path == 'commits/abcdef0123456789/check-runs?filter=latest':
                    return [{'id': 1, 'name': 'host', 'conclusion': 'failure'}]
                if re_match := re.match(r'issues/(10|11|12)/comments$', path):
                    n = int(re_match.group(1))
                    return [comment(n, '/lane T4', '2026-09-01T10:00:00Z', n)]
                if path == 'issues/11/timeline':
                    return []
                if path == 'pulls/11/commits':
                    return [{'commit': {'committer': {'date': OLD}}}]
                return super().pages(path, key)

        api = Inventory()
        data = sweep.collect(api, NOW, snapshot()['runtime'])
        report = sweep.sweep(data, NOW)
        self.assertEqual([a['numbers'][0] for a in report['actions'] if a['rule'] == 't4-wait'], [10, 11, 12])
        self.assertIn('red-head', [a['rule'] for a in report['actions']])
        self.assertNotIn('issues/1/timeline', api.paths)


if __name__ == '__main__':
    unittest.main()
