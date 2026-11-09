"""scripts/sm_sweep.py (#1598): the wake sweep's six rules, and the one write it may make.

GitHub is replaced by a router that answers reads from rules and records writes. The Dial issue body and the Mac tick
are the live texts of 2026-10-14 (scripts/fixtures/sm_sweep/). Times are fixed around NOW.
"""
import contextlib
import datetime as dt
import io
import json
import re
import sys
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
import sm_status  # noqa: E402
import sm_sweep as sweep  # noqa: E402

FIXTURES = SCRIPTS / 'fixtures' / 'sm_sweep'
DIAL_BODY = (FIXTURES / 'dial-issue-body.md').read_text()
TICK_BODY = (FIXTURES / 'mac-tick.md').read_text()
NOW = dt.datetime(2026, 10, 14, 20, 0, tzinfo=dt.timezone.utc)


def at(**delta):
    """An ISO time this long before NOW."""
    return (NOW - dt.timedelta(**delta)).strftime('%Y-%m-%dT%H:%M:%SZ')


def note(issue, body, when, n=[0]):
    n[0] += 1
    return {'id': n[0], 'issue_url': f'https://api.github.com/repos/x/y/issues/{issue}', 'body': body,
            'created_at': when, 'user': {'login': 'uncomposed'}, 'author_association': 'OWNER', 'html_url': f'https://example.test/{n[0]}'}


def claim(issue, title, when):
    return note(issue, f'Claimed by project thread "{title}"', when)


def stop(issue, title, when):
    return note(issue, f'Thread "{title}" stopping: nothing armed · test', when)


def issue(number, labels=(), created='2026-10-01T00:00:00Z', title=None):
    return {'number': number, 'title': title or f'Issue {number}', 'created_at': created,
            'labels': [{'name': name} for name in labels], 'milestone': None, 'state': 'open'}


class Router:
    """A GitHub stand-in: reads answer from the first rule whose pattern matches the path; writes are recorded."""
    repo = 'example/repo'

    def __init__(self):
        self.rules, self.reads, self.writes = [], [], []
        self.gql = {}

    def on(self, pattern, value):
        self.rules.insert(0, (re.compile(pattern), value))
        return self

    def _answer(self, path, **kwargs):
        self.reads.append(path)
        for pattern, value in self.rules:
            if pattern.search(path):
                if isinstance(value, Exception):
                    raise value
                return value(path) if callable(value) else value
        raise sm_status.GitHubError(f'no rule for {path}')

    get = pages = _answer

    def graphql(self, query, variables=None):
        """GraphQL reads: the open-issue scan (`issues`) or a PR lookup by number (`lookup`), from self.gql."""
        kind = 'issues' if 'issues(states' in query else 'lookup'
        self.reads.append(f'graphql:{kind}')
        value = self.gql.get(kind)
        if isinstance(value, Exception):
            raise value
        return value(query, variables) if callable(value) else value

    def post(self, path, body):
        self.writes.append(('POST', path, body))
        return {}

    def patch(self, path, body):
        self.writes.append(('PATCH', path, body))
        return {}

    def delete(self, path):
        self.writes.append(('DELETE', path, None))
        return {}


def snapshot(rows=()):
    return {'as_of': at(minutes=0), 'prs': list(rows), 'counts': {}, 'base': 'next', 'missing': []}


def pr(number, issue_number=None, armed=True, red=False, t4=None, mac=None):
    flags = [{'code': 'red-on-head', 'severity': 'red', 'detail': 'the newest lane report is FAIL'}] if red else []
    return {'number': number, 'head7': 'abcdef0', 'issue': issue_number, 'armed': armed, 'flags': flags,
            't4_waiting': t4, 'mac': mac}


def gql_issue(number, title=None, labels=(), comments=(), reopened=None, milestone=None, body='', created='', bot=False):
    """One open issue as the sweep's GraphQL scan returns it."""
    return {'number': number, 'title': title or f'Issue {number}', 'labels': {'nodes': [{'name': n} for n in labels]},
            'body': body, 'createdAt': created, 'author': {'__typename': 'Bot' if bot else 'User'},
            'milestone': {'title': milestone} if milestone else None,
            'timelineItems': {'nodes': [{'createdAt': reopened}] if reopened else []}, 'comments': {'nodes': list(comments)}}


def gql_comment(body, when, association='MEMBER', login='uncomposed'):
    return {'createdAt': when, 'body': body, 'authorAssociation': association,
            'author': {'__typename': 'User', 'login': login}}


def gql_pull(number, merged_at, base='main', title=None, body='', head=''):
    return {'number': number, 'mergedAt': merged_at, 'baseRefName': base, 'title': title or f'PR {number}',
            'body': body, 'headRefName': head}


def world(comments=(), ready=(), in_progress=(), events=None, refs=None, tick=TICK_BODY, tick_at=None, dial=DIAL_BODY,
          status_comment=None, comments_error=None, untriaged=(), open_issues=(), lookup=None):
    """A router for one sweep: the Dial issue, the Mac tick, repo comments, the two label lists, claim evidence."""
    router = Router()
    router.on(r'^issues/589$', {'body': dial})
    router.on(r'^issues/589/comments', [status_comment] if status_comment else [])
    ticks = [{'id': 1, 'created_at': tick_at or at(minutes=44), 'body': tick, 'user': {'login': 'uncomposed'}, 'author_association': 'OWNER'}] if tick else []
    router.on(r'^issues/337/comments', ticks)
    router.on(r'^issues/comments\?since', comments_error or list(comments))
    router.on(r'^events', [])
    router.on(r'^pulls\?state=open', [])
    router.on(r'^pulls\?state=closed', [])
    router.gql['issues'] = {'repository': {'issues': {'pageInfo': {'hasNextPage': False, 'endCursor': None},
                                                      'nodes': list(open_issues)}}}
    router.gql['lookup'] = lambda query, variables: {'repository': {
        f'n{n}': (lookup or {}).get(int(n)) for n in re.findall(r'n(\d+): issueOrPullRequest', query)}}
    router.on(r'^git/ref/heads/next', {'object': {'sha': 'a' * 40}})
    router.on(r'^issues\?state=open&milestone=none', list(untriaged))
    router.on(r'^issues\?state=open&labels=ready', list(ready))
    router.on(r'^issues\?state=open&labels=in-progress', list(in_progress))
    router.on(r'^issues/(\d+)/events', lambda path: (events or {}).get(int(re.search(r'issues/(\d+)', path).group(1)), []))
    router.on(r'^git/matching-refs/heads/ws/(\d+)-',
              lambda path: (refs or {}).get(int(re.search(r'ws/(\d+)-', path).group(1)), []))
    router.on(r'^commits/(\w+)$', lambda path: {'commit': {'committer': {'date': (refs or {}).get('dates', {}).get(
        re.search(r'commits/(\w+)', path).group(1))}}})
    return router


def label_event(when, name='in-progress'):
    return {'event': 'labeled', 'created_at': when, 'label': {'name': name}}


def facts_of(router, rows=(), now=NOW):
    return sweep.collect(router, now, snapshot(rows))


def rules(actions):
    return [a['rule'] for a in actions]


class ClaimState(unittest.TestCase):
    """The 6-hour rule. A test here fails if the window is ignored or widened."""

    def state(self, **evidence):
        base = {'last_comment_at': None, 'label_since': None, 'branch_commit_at': None, 'open_pr': None,
                'thread_active': None, 'unknown': []}
        return sweep.claim_state(dict(base, **evidence), NOW)[0]

    def test_a_comment_inside_six_hours_keeps_the_claim(self):
        self.assertEqual(self.state(last_comment_at=at(hours=5, minutes=59)), 'active')

    def test_six_hours_of_silence_releases_it(self):
        self.assertEqual(self.state(last_comment_at=at(hours=6)), 'stale')
        self.assertEqual(self.state(last_comment_at=at(hours=7)), 'stale')

    def test_the_newest_sign_of_life_counts_whichever_kind_it_is(self):
        old = at(hours=30)
        self.assertEqual(self.state(last_comment_at=old, branch_commit_at=at(hours=2)), 'active')
        self.assertEqual(self.state(last_comment_at=old, label_since=at(hours=1)), 'active')

    def test_an_open_pr_or_an_active_thread_keeps_it_however_old_the_rest(self):
        old = at(days=3)
        self.assertEqual(self.state(last_comment_at=old, open_pr=5), 'active')
        self.assertEqual(self.state(last_comment_at=old, thread_active='Ready queue A'), 'active')

    def test_an_unreadable_fact_never_releases(self):
        self.assertEqual(self.state(last_comment_at=at(days=2), unknown=['branches unreadable']), 'unknown')

    def test_a_sign_of_life_beats_an_unreadable_fact(self):
        self.assertEqual(self.state(last_comment_at=at(hours=1), unknown=['branches unreadable']), 'active')


class GatheringEvidence(unittest.TestCase):
    def ctx(self, **over):
        base = {'last_comment': {}, 'comments_complete': True, 'pr_for_issue': {}, 'thread_for_issue': {}}
        return dict(base, **over)

    def test_a_recent_comment_stops_the_search_before_any_extra_call(self):
        router = world()
        evidence = sweep.gather_claim(router, 7, NOW, self.ctx(last_comment={7: at(hours=1)}))
        self.assertEqual(sweep.claim_state(evidence, NOW)[0], 'active')
        self.assertEqual(router.reads, [])

    def test_a_label_added_an_hour_ago_with_no_note_is_a_fresh_claim(self):
        router = world(events={7: [label_event(at(hours=1))]})
        evidence = sweep.gather_claim(router, 7, NOW, self.ctx())
        self.assertEqual(sweep.claim_state(evidence, NOW)[0], 'active')

    def test_a_branch_commit_inside_the_window_keeps_it(self):
        router = world(events={7: [label_event(at(days=2))]},
                       refs={7: [{'ref': 'refs/heads/ws/7-x', 'object': {'sha': 'abc123'}}],
                             'dates': {'abc123': at(hours=3)}})
        evidence = sweep.gather_claim(router, 7, NOW, self.ctx())
        self.assertEqual(sweep.claim_state(evidence, NOW)[0], 'active')

    def test_an_old_label_and_an_old_branch_are_stale(self):
        router = world(events={7: [label_event(at(days=2))]},
                       refs={7: [{'ref': 'refs/heads/ws/7-x', 'object': {'sha': 'abc123'}}],
                             'dates': {'abc123': at(hours=9)}})
        evidence = sweep.gather_claim(router, 7, NOW, self.ctx())
        self.assertEqual(sweep.claim_state(evidence, NOW)[0], 'stale')

    def test_an_incomplete_comment_read_blocks_every_release(self):
        router = world(events={7: [label_event(at(days=2))]})
        evidence = sweep.gather_claim(router, 7, NOW, self.ctx(comments_complete=False))
        self.assertEqual(sweep.claim_state(evidence, NOW)[0], 'unknown')

    def test_unreadable_events_or_branches_are_unknown_not_stale(self):
        router = world(refs={})
        router.on(r'^issues/7/events', sm_status.GitHubError('HTTP 502'))
        self.assertEqual(sweep.claim_state(sweep.gather_claim(router, 7, NOW, self.ctx()), NOW)[0], 'unknown')
        router = world(events={7: [label_event(at(days=2))]})
        router.on(r'^git/matching-refs', sm_status.GitHubError('HTTP 502'))
        self.assertEqual(sweep.claim_state(sweep.gather_claim(router, 7, NOW, self.ctx()), NOW)[0], 'unknown')

    def test_an_issue_with_no_label_event_on_record_is_unknown(self):
        self.assertEqual(sweep.claim_state(sweep.gather_claim(world(), 7, NOW, self.ctx()), NOW)[0], 'unknown')


class ReadingTheDialAndTheTick(unittest.TestCase):
    def test_the_live_dial_reads_paced_two_claude_threads_three_codex(self):
        self.assertEqual(sweep.codex_slots(DIAL_BODY), 3)
        facts = facts_of(world())
        self.assertEqual((facts['dial']['mode'], facts['dial']['threads'], facts['dial']['codex_threads']), ('paced', 2, 3))

    def test_codex_takes_the_cautious_tick_and_a_missing_box_is_zero(self):
        self.assertEqual(sweep.codex_slots('**Codex workers** (x)\n- [x] 2\n- [x] 1\n'), 1)
        self.assertEqual(sweep.codex_slots('**Threads**\n- [x] 2\n'), 0)

    def test_the_tick_line_gives_desk_finisher_and_runner(self):
        tick = sweep.latest_tick([{'created_at': at(minutes=5), 'body': TICK_BODY}])
        self.assertEqual((tick['runner_running'], tick['runner_queued'], tick['finisher_idle_minutes']), (2, 3, 25))
        self.assertIsNone(tick['test_desk'])
        go = sweep.latest_tick([{'created_at': at(minutes=5), 'body': TICK_BODY + '\n- Test Desk: GO (3 checks)'}])
        self.assertEqual(go['test_desk'], 'GO')

    def test_other_comments_are_not_ticks(self):
        self.assertIsNone(sweep.latest_tick([{'created_at': at(minutes=5), 'body': 'SM integration run skipped'}]))

    def test_the_gate_status_comment_gives_its_now_line(self):
        body = '<!-- dial-gate-status -->\n**Dial gate**\n- Ready issues: 5.\n- Now: Holding: usage 95%.'
        self.assertEqual(sweep.dial_now([{'body': body}]), 'Holding: usage 95%.')
        self.assertIsNone(sweep.dial_now([{'body': 'other'}]))


class FreeSlots(unittest.TestCase):
    def test_two_slots_free_start_the_top_ready_issues_in_the_coordinators_order(self):
        router = world(ready=[issue(10, ['ready'], '2026-10-02T00:00:00Z'),
                              issue(11, ['ready', 'priority'], '2026-10-05T00:00:00Z'),
                              issue(12, ['ready', 'regression'], '2026-10-06T00:00:00Z'),
                              issue(13, ['ready'], '2026-10-01T00:00:00Z')])
        facts = facts_of(router)
        actions, slot = sweep.decide(facts)
        self.assertEqual((slot['claude_allowed'], slot['claude_active'], slot['claude_free']), (2, 0, 2))
        free = next(a for a in actions if a['rule'] == 'free-slots')
        self.assertEqual(free['issues'], [11, 12])      # priority, then regression; never more than the free slots

    def test_active_claude_threads_use_slots_and_codex_workers_do_not(self):
        comments = [claim(20, 'Ready queue A', at(minutes=30)), claim(21, 'Codex worker 1', at(minutes=20)),
                    claim(22, 'Codex worker 2', at(minutes=10))]
        facts = facts_of(world(comments=comments, ready=[issue(10, ['ready']), issue(11, ['ready'])]))
        _, slot = sweep.decide(facts)
        self.assertEqual((slot['claude_active'], slot['claude_free'], slot['codex_active']), (1, 1, 2))

    def test_a_thread_with_a_stop_note_frees_its_slot(self):
        comments = [claim(20, 'Ready queue A', at(hours=2)), stop(20, 'Ready queue A', at(minutes=30))]
        _, slot = sweep.decide(facts_of(world(comments=comments, ready=[issue(10, ['ready'])])))
        self.assertEqual(slot['claude_active'], 0)

    def test_a_full_dial_starts_nothing(self):
        comments = [claim(20, 'A', at(minutes=30)), claim(21, 'B', at(minutes=20))]
        actions, slot = sweep.decide(facts_of(world(comments=comments, ready=[issue(10, ['ready'])])))
        self.assertEqual(slot['claude_free'], 0)
        self.assertNotIn('free-slots', rules(actions))

    def test_off_halt_and_a_holding_gate_start_nothing(self):
        ready = [issue(10, ['ready'])]
        off = DIAL_BODY.replace('- [ ] Off: nothing', '- [x] Off: nothing')
        for name, router, held in (
                ('off', world(ready=ready, dial=off), 'Off'),
                ('halt', world(ready=ready, tick=TICK_BODY.replace('(Mac tick)', '(Mac tick, HALT (usage breaker))')
                               .replace('**14:15 CDT (Mac tick)**', '**14:15 CDT (Mac tick)** HALT (usage breaker)'), ),
                 'HALT'),
                ('holding', world(ready=ready, status_comment={'body': '<!-- dial-gate-status -->\n- Now: Holding: usage 95%.', 'author_association': 'OWNER'}),
                 'Holding')):
            with self.subTest(name=name):
                actions, slot = sweep.decide(facts_of(router))
                self.assertEqual(slot['claude_free'], 0)
                self.assertIn(held, slot['held'])
                self.assertNotIn('free-slots', rules(actions))

    def test_halt_is_the_first_thing_said(self):
        tick = TICK_BODY.replace('**14:15 CDT (Mac tick)**', '**14:15 CDT (Mac tick)** HALT (usage breaker: Claude)')
        actions, _ = sweep.decide(facts_of(world(tick=tick)))
        self.assertEqual(actions[0]['rule'], 'halt')

    def test_cloud_threads_skip_mac_only_and_skip_labels_and_a_second_hot_file(self):
        ready = [issue(10, ['ready', 'where:mac']), issue(11, ['ready', 'blocked']), issue(12, ['ready', 'hot-file']),
                 issue(13, ['ready'])]
        busy = [issue(30, ['in-progress', 'hot-file'])]
        actions, _ = sweep.decide(facts_of(world(ready=ready, in_progress=busy, comments=[note(30, 'x', at(hours=1))])))
        free = next(a for a in actions if a['rule'] == 'free-slots')
        self.assertEqual(free['issues'], [13])


class MacIdle(unittest.TestCase):
    MAC = [issue(40, ['ready', 'where:mac']), issue(41, ['ready', 'where:mac'])]
    QUIET_FINISHER = TICK_BODY.replace('Mac finisher last active 25 min ago', 'Mac finisher last active 95 min ago')

    def test_the_fixture_tick_has_a_finisher_active_25_minutes_ago(self):
        self.assertIn('Mac finisher last active 25 min ago', TICK_BODY)

    def test_a_finisher_active_in_the_last_half_hour_means_the_mac_is_working(self):
        actions, _ = sweep.decide(facts_of(world(ready=self.MAC)))     # the live tick: finisher active 25 min ago
        self.assertNotIn('mac-idle', rules(actions))

    def test_mac_only_ready_issues_with_nothing_in_progress_there_is_idle(self):
        actions, _ = sweep.decide(facts_of(world(ready=self.MAC, tick=self.QUIET_FINISHER)))
        idle = next(a for a in actions if a['rule'] == 'mac-idle')
        self.assertEqual(idle['issues'], [40, 41])

    def test_a_live_mac_claim_means_the_mac_is_working(self):
        busy = [issue(42, ['in-progress', 'where:mac'])]
        actions, _ = sweep.decide(facts_of(world(ready=self.MAC, in_progress=busy, tick=self.QUIET_FINISHER,
                                                 comments=[note(42, 'on it', at(hours=1))])))
        self.assertNotIn('mac-idle', rules(actions))

    def test_a_stale_mac_claim_does_not_count_as_work(self):
        stale = [issue(42, ['in-progress', 'where:mac'])]
        router = world(ready=self.MAC, in_progress=stale, events={42: [label_event(at(days=2))]}, tick=self.QUIET_FINISHER)
        actions, _ = sweep.decide(facts_of(router))
        self.assertIn('mac-idle', rules(actions))
        self.assertIn('stale-claim', rules(actions))

    def test_no_mac_only_ready_issues_is_not_idle(self):
        actions, _ = sweep.decide(facts_of(world(ready=[issue(10, ['ready'])], tick=self.QUIET_FINISHER)))
        self.assertNotIn('mac-idle', rules(actions))

    def test_an_old_or_missing_tick_is_reported(self):
        self.assertIn('mac-tick-stale', rules(sweep.decide(facts_of(world(tick_at=at(hours=4))))[0]))
        self.assertIn('mac-tick-stale', rules(sweep.decide(facts_of(world(tick=None)))[0]))
        self.assertNotIn('mac-tick-stale', rules(sweep.decide(facts_of(world()))[0]))


class ArmedRed(unittest.TestCase):
    def test_an_armed_pr_red_on_its_head_is_listed_with_why(self):
        actions, _ = sweep.decide(facts_of(world(), [pr(1575, red=True)]))
        red = next(a for a in actions if a['rule'] == 'armed-red')
        self.assertEqual(red['prs'], [1575])
        self.assertIn('red-on-head', red['detail'])

    def test_a_red_pr_that_is_not_armed_or_an_armed_quiet_one_is_not(self):
        rows = [pr(1, armed=False, red=True), pr(2, red=False)]
        self.assertNotIn('armed-red', rules(sweep.decide(facts_of(world(), rows))[0]))


class TestDeskWaiting(unittest.TestCase):
    def test_a_t4_request_waiting_over_an_hour_with_no_desk_starts_one(self):
        rows = [pr(7, t4={'at': at(hours=2), 'commit7': 'abc1234'})]
        actions, _ = sweep.decide(facts_of(world(), rows))
        start = next(a for a in actions if a['rule'] == 'start-desk')
        self.assertEqual(start['prs'], [7])

    def test_under_an_hour_is_not_yet(self):
        rows = [pr(7, t4={'at': at(minutes=59), 'commit7': 'abc1234'})]
        self.assertNotIn('start-desk', rules(sweep.decide(facts_of(world(), rows))[0]))

    def test_a_desk_report_or_a_comment_on_184_inside_the_hour_means_a_desk_is_running(self):
        rows = [pr(7, t4={'at': at(hours=2), 'commit7': 'abc1234'})]
        for evidence in (note(9, 'Lane report t4-j1 — PASS\ncommit abc1234', at(minutes=20)),
                         note(184, 'Test Desk: starting the integration run on de750f8', at(minutes=20))):
            with self.subTest(body=evidence['body'][:20]):
                actions, _ = sweep.decide(facts_of(world(comments=[evidence]), rows))
                self.assertNotIn('start-desk', rules(actions))

    def test_the_runners_own_reports_are_not_the_desk(self):
        rows = [pr(7, t4={'at': at(hours=2), 'commit7': 'abc1234'})]
        runner = note(9, 'Lane report pr9-r1 — PASS\ncommit abc1234', at(minutes=20))
        self.assertIn('start-desk', rules(sweep.decide(facts_of(world(comments=[runner]), rows))[0]))

    def test_an_old_desk_report_does_not_count(self):
        rows = [pr(7, t4={'at': at(hours=5), 'commit7': 'abc1234'})]
        old = note(9, 'Lane report t4-j1 — PASS\ncommit abc1234', at(hours=3))
        self.assertIn('start-desk', rules(sweep.decide(facts_of(world(comments=[old]), rows))[0]))

    def test_a_go_line_in_the_tick_starts_a_desk_even_with_no_open_t4_request(self):
        tick = TICK_BODY + '\n- Test Desk: GO'
        self.assertIn('start-desk', rules(sweep.decide(facts_of(world(tick=tick)))[0]))

    def test_a_go_the_desk_has_already_answered_is_not_acted_on_twice(self):
        tick = TICK_BODY + '\n- Test Desk: GO'
        reported = note(9, 'Lane report t4-j1 — PASS\ncommit abc1234', at(minutes=80))   # after the tick, 80 min ago
        router = world(tick=tick, tick_at=at(hours=2), comments=[reported])
        self.assertNotIn('start-desk', rules(sweep.decide(facts_of(router))[0]))


class NeedsMacStuck(unittest.TestCase):
    def test_no_finisher_activity_an_hour_after_the_hand_off_is_stuck(self):
        rows = [pr(9, armed=False, mac={'since': at(hours=2), 'finisher_active_at': None})]
        actions, _ = sweep.decide(facts_of(world(), rows))
        self.assertEqual(next(a for a in actions if a['rule'] == 'needs-mac-stuck')['prs'], [9])

    def test_activity_after_the_hand_off_or_less_than_an_hour_is_fine(self):
        for mac in ({'since': at(hours=2), 'finisher_active_at': at(minutes=30)},
                    {'since': at(minutes=59), 'finisher_active_at': None},
                    {'since': None, 'finisher_active_at': None}):
            with self.subTest(mac=mac):
                self.assertNotIn('needs-mac-stuck', rules(sweep.decide(facts_of(world(), [pr(9, mac=mac)]))[0]))


class HandOffReading(unittest.TestCase):
    """sm_status reads the finisher's activity from the PR's comments and the head commit."""

    def mac(self, comments, committed=None, events=()):
        pull = {'labels': [{'name': 'needs-mac'}]}
        return sm_status.mac_handoff(pull, comments, list(events), committed)

    def test_a_pr_without_the_label_has_no_hand_off(self):
        self.assertIsNone(sm_status.mac_handoff({'labels': []}, [], [], None))

    def test_the_hand_off_comment_starts_the_clock_and_a_later_comment_is_activity(self):
        hand = {'created_at': '2026-10-14T10:00:00Z', 'body': 'Handing to the Mac finisher: build fails', 'user': {'login': 'u'}, 'author_association': 'OWNER'}
        later = {'created_at': '2026-10-14T10:30:00Z', 'body': 'Fixed the build', 'user': {'login': 'u'}, 'author_association': 'OWNER'}
        self.assertEqual(self.mac([hand]), {'since': hand['created_at'], 'finisher_active_at': None})
        self.assertEqual(self.mac([hand, later])['finisher_active_at'], later['created_at'])

    def test_the_runners_comments_and_a_second_hand_off_are_not_activity(self):
        hand = {'created_at': '2026-10-14T10:00:00Z', 'body': 'Handing to the Mac finisher: x', 'user': {'login': 'u'}, 'author_association': 'OWNER'}
        bot = {'created_at': '2026-10-14T10:10:00Z', 'body': 'Lane report pr1-r1 — FAIL', 'user': {'login': 'github-actions[bot]'}}
        again = {'created_at': '2026-10-14T10:20:00Z', 'body': 'Handing to the Mac finisher: again', 'user': {'login': 'u'}, 'author_association': 'OWNER'}
        self.assertIsNone(self.mac([hand, bot])['finisher_active_at'])
        self.assertEqual(self.mac([hand, bot, again])['since'], again['created_at'])

    def test_a_commit_after_the_hand_off_is_activity_and_an_earlier_one_is_not(self):
        hand = {'created_at': '2026-10-14T10:00:00Z', 'body': 'Handing to the Mac finisher: x', 'user': {'login': 'u'}, 'author_association': 'OWNER'}
        self.assertEqual(self.mac([hand], committed='2026-10-14T10:40:00Z')['finisher_active_at'], '2026-10-14T10:40:00Z')
        self.assertIsNone(self.mac([hand], committed='2026-10-14T09:00:00Z')['finisher_active_at'])

    def test_with_no_hand_off_comment_the_label_time_is_used(self):
        events = [{'event': 'labeled', 'created_at': '2026-10-14T08:00:00Z', 'label': {'name': 'needs-mac'}}]
        self.assertEqual(self.mac([], events=events)['since'], '2026-10-14T08:00:00Z')

    def test_a_t4_request_is_waiting_until_a_desk_report_follows_it(self):
        ask = {'created_at': '2026-10-14T10:00:00Z', 'body': '/lane T4\ncommit: abc1234\nrun: J1', 'user': {'login': 'u'}, 'author_association': 'OWNER'}
        runner = {'created_at': '2026-10-14T10:05:00Z', 'body': 'Lane report pr1-r1 — PASS\ncommit abc1234',
                  'user': {'login': 'github-actions[bot]'}}
        desk = {'created_at': '2026-10-14T11:00:00Z', 'body': 'Lane report t4-j1 — PASS\ncommit abc1234', 'user': {'login': 'u'}, 'author_association': 'OWNER'}
        self.assertEqual(sm_status.waiting_t4([ask, runner])['commit7'], 'abc1234')
        self.assertIsNone(sm_status.waiting_t4([ask, runner, desk]))
        self.assertIsNone(sm_status.waiting_t4([desk]))


class OpenPrProtection(unittest.TestCase):
    def pull(self, title, body, ref):
        return {'title': title, 'body': body, 'head': {'ref': ref}}

    def test_every_issue_a_pr_visibly_works_on_is_linked(self):
        cases = [(self.pull('x', 'Part of #15. Fixes #99', 'ws/15-a'), [99, 15]),
                 (self.pull('x', 'Closes #12 and closes #13', 'claude/x'), [12, 13]),
                 (self.pull('AGENTS.md: calls (#1556)', 'refs #14', 'claude/x'), [1556, 14]),
                 (self.pull('x', 'Handles it (for #77)', 'claude/x'), [77]),
                 (self.pull('x', 'nothing here', 'claude/x'), [])]
        for pull, expected in cases:
            with self.subTest(body=pull['body']):
                self.assertEqual(sorted(sm_status.linked_issues(pull)), sorted(expected))

    def test_a_claim_with_any_linked_open_pr_is_never_released(self):
        row = pr(60, issue_number=99)
        row['issues'] = [99, 15]
        router = world(in_progress=[issue(15, ['in-progress'])], events={15: [label_event(at(days=2))]})
        actions, _ = sweep.decide(facts_of(router, [row]))
        self.assertNotIn('stale-claim', rules(actions))


class ReleasingClaims(unittest.TestCase):
    """--apply: the only write, and only for claims the 6-hour rule calls stale."""

    def setUp(self):
        self.router = world(
            in_progress=[issue(50, ['in-progress'], title='Stale one'), issue(51, ['in-progress'], title='Fresh one'),
                         issue(52, ['in-progress', 'blocked'], title='Stale but blocked')],
            comments=[note(51, 'working', at(hours=2))],
            events={50: [label_event(at(days=2))], 52: [label_event(at(days=2))]})
        self.router.on(r'^issues/50/comments\?since', [])
        self.router.on(r'^issues/52/comments\?since', [])
        self.router.on(r'^issues/50$', {'number': 50, 'state': 'open', 'labels': [{'name': 'in-progress'}]})
        self.router.on(r'^issues/52$', {'number': 52, 'state': 'open', 'labels': [{'name': 'in-progress'}, {'name': 'blocked'}]})

    def run_main(self, *args):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = sweep.main(list(args), api=self.router, now=NOW)
        return code, out.getvalue()

    def test_without_apply_nothing_is_written(self):
        code, text = self.run_main()
        self.assertEqual(code, 0)
        self.assertEqual(self.router.writes, [])
        self.assertIn('STALE-CLAIM', text)
        self.assertIn('#50', text)
        self.assertNotIn('#51 Fresh', text)

    def test_apply_releases_only_the_stale_claims(self):
        code, text = self.run_main('--apply')
        self.assertEqual(code, 0)
        touched = {path.split('/')[1] for _, path, _ in self.router.writes}
        self.assertEqual(touched, {'50', '52'})                       # never the fresh claim #51
        self.assertIn(('DELETE', 'issues/50/labels/in-progress', None), self.router.writes)
        self.assertIn(('POST', 'issues/50/labels', {'labels': ['ready']}), self.router.writes)
        comment = next(body for method, path, body in self.router.writes if path == 'issues/50/comments')
        self.assertIn('no commit, open PR or comment for 6 hours', comment['body'])
        self.assertIn('[released]', text)

    def test_in_progress_comes_off_last_so_a_failed_step_leaves_the_claim_in_place(self):
        self.run_main('--apply')
        writes = [w for w in self.router.writes if w[1].startswith('issues/50')]
        self.assertEqual([w[0] + ' ' + w[1] for w in writes],
                         ['POST issues/50/labels', 'POST issues/50/comments', 'DELETE issues/50/labels/in-progress'])

        class FailingComment(Router):
            def post(self, path, body):
                if path.endswith('/comments'):
                    raise sm_status.GitHubError('HTTP 502')
                return super().post(path, body)
        failing = FailingComment()
        failing.rules = self.router.rules
        with contextlib.redirect_stdout(io.StringIO()):
            sweep.main(['--apply'], api=failing, now=NOW)
        self.assertNotIn('DELETE', [w[0] for w in failing.writes if w[1].startswith('issues/50')])

    def test_a_blocked_issue_loses_in_progress_but_is_not_made_ready(self):
        self.run_main('--apply')
        writes = [w for w in self.router.writes if w[1].startswith('issues/52')]
        self.assertIn(('DELETE', 'issues/52/labels/in-progress', None), writes)
        self.assertNotIn(('POST', 'issues/52/labels', {'labels': ['ready']}), writes)
        comment = next(w[2]['body'] for w in writes if w[1].endswith('/comments'))
        self.assertIn('Not set back to `ready`', comment)

    def test_a_validation_hold_label_also_keeps_a_released_claim_off_ready(self):
        for hold in ('validate-by-use', 'agent-verify', 'status: needs-human-validation'):
            with self.subTest(hold=hold):
                router = Router()
                router.on(r'^issues/60/comments\?since', [])
                router.on(r'^issues/60$', {'number': 60, 'state': 'open',
                                           'labels': [{'name': 'in-progress'}, {'name': hold}]})
                self.assertEqual(sweep.release(router, issue(60, ['in-progress', hold]), 'test', NOW), 'released')
                self.assertNotIn(('POST', 'issues/60/labels', {'labels': ['ready']}), router.writes)
                self.assertIn(('DELETE', 'issues/60/labels/in-progress', None), router.writes)

    def test_a_comment_that_arrives_before_the_write_stops_the_release(self):
        self.router.on(r'^issues/50/comments\?since', [note(50, 'back at it', at(minutes=1))])
        _, text = self.run_main('--apply')
        self.assertFalse([w for w in self.router.writes if w[1].startswith('issues/50')])
        self.assertIn('skipped: a comment arrived', text)

    def test_an_issue_that_changed_while_the_sweep_ran_is_left_alone(self):
        self.router.on(r'^issues/50$', {'number': 50, 'state': 'closed', 'labels': []})
        self.run_main('--apply')
        self.assertFalse([w for w in self.router.writes if w[1].startswith('issues/50')])

    def test_a_failed_write_is_reported_not_raised(self):
        class Failing(Router):
            def delete(self, path):
                raise sm_status.GitHubError('HTTP 403')
        failing = Failing()
        failing.rules = self.router.rules
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = sweep.main(['--apply'], api=failing, now=NOW)
        self.assertEqual(code, 0)
        self.assertIn('error: ', out.getvalue())

    def test_nothing_is_released_when_the_comment_read_was_incomplete(self):
        self.router.on(r'^issues/comments\?since', sm_status.GitHubError('HTTP 502'))
        _, text = self.run_main('--apply')
        self.assertEqual(self.router.writes, [])
        self.assertIn('no claim was judged stale', text)


def merged_pull(number, body, merged_at=None):
    return {'number': number, 'title': f'PR {number}', 'body': body, 'merged_at': merged_at}


class MergedFixStillReady(unittest.TestCase):
    """Rule 8: a ready issue whose `Closes #N` PR merged is closed by --apply, keeping its validation labels."""
    MERGED = '2026-10-14T12:00:00Z'

    def build(self, labels=('ready', 'found-on-phone'), pulls=(), open_pr=None, comments=()):
        router = world(ready=[issue(70, labels, title='Phone bug')], comments=list(comments))
        router.on(r'^pulls\?state=closed', list(pulls))
        router.on(r'^issues/70/comments\?since', [])
        router.on(r'^issues/70$', {'number': 70, 'state': 'open', 'labels': [{'name': n} for n in labels]})
        rows = [dict(pr(900, None, armed=False), issues=[70], issue=70)] if open_pr else []
        return router, rows

    def apply(self, router, rows):
        original = sm_status.snapshot
        sm_status.snapshot = lambda api, now: snapshot(rows)
        try:
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                sweep.main(['--apply'], api=router, now=NOW)
            return out.getvalue()
        finally:
            sm_status.snapshot = original

    def test_a_merged_closes_pr_closes_the_issue_and_keeps_its_labels(self):
        router, rows = self.build(labels=('ready', 'in-progress', 'found-on-phone', 'priority', 'agent-verify'),
                                  pulls=[merged_pull(800, 'Closes #70', self.MERGED)])
        text = self.apply(router, rows)
        self.assertIn('FIX-MERGED', text)
        self.assertIn('[closed]', text)
        self.assertIn(('PATCH', 'issues/70', {'state': 'closed', 'state_reason': 'completed'}), router.writes)
        comment = next(b['body'] for m, p, b in router.writes if p == 'issues/70/comments')
        self.assertEqual(comment, 'Closed by scripts/sm_sweep.py: fix merged in #800 on 2026-10-14. Validation labels '
                                  'stay on; a failed check reopens it (2026-10-22 call).')
        removed = [p for m, p, b in router.writes if m == 'DELETE']
        self.assertEqual(removed, ['issues/70/labels/in-progress', 'issues/70/labels/ready'])  # nothing else comes off
        self.assertEqual([p for m, p, b in router.writes if m == 'POST'], ['issues/70/comments'])  # no label added
        self.assertNotIn('milestone', json.dumps(router.writes))

    def test_without_apply_it_only_reports(self):
        router, rows = self.build(pulls=[merged_pull(800, 'Fixes #70', self.MERGED)])
        facts = sweep.collect(router, NOW, snapshot(rows))
        actions, _ = sweep.decide(facts)
        self.assertEqual([a['rule'] for a in actions if a['rule'] == 'fix-merged'], ['fix-merged'])
        self.assertEqual(router.writes, [])

    def test_part_of_or_refs_only_is_skipped(self):
        for body in ('Part of #70', 'Refs #70', 'See #70'):
            with self.subTest(body=body):
                router, rows = self.build(pulls=[merged_pull(800, body, self.MERGED)])
                self.apply(router, rows)
                self.assertEqual(router.writes, [])

    def test_an_unmerged_closed_pr_is_not_a_fix(self):
        router, rows = self.build(pulls=[merged_pull(800, 'Closes #70', None)])
        self.apply(router, rows)
        self.assertEqual(router.writes, [])

    def test_a_merged_fix_with_an_open_follow_up_pr_is_skipped(self):
        router, rows = self.build(pulls=[merged_pull(800, 'Closes #70', self.MERGED)], open_pr=True)
        self.apply(router, rows)
        self.assertEqual(router.writes, [])

    def test_a_recent_claim_or_comment_is_skipped(self):
        router, rows = self.build(pulls=[merged_pull(800, 'Closes #70', self.MERGED)],
                                  comments=[claim(70, 'Fix thread', at(minutes=30))])
        self.apply(router, rows)
        self.assertEqual(router.writes, [])
        router, rows = self.build(pulls=[merged_pull(800, 'Closes #70', self.MERGED)],
                                  comments=[note(70, 'looking at it', at(hours=1))])
        self.apply(router, rows)
        self.assertEqual(router.writes, [])

    def test_fixes_and_resolves_also_close_and_an_unreadable_pr_list_writes_nothing(self):
        for body in ('Fixes #70', 'Resolves #70'):
            router, rows = self.build(pulls=[merged_pull(800, body, self.MERGED)])
            self.apply(router, rows)
            self.assertIn(('PATCH', 'issues/70', {'state': 'closed', 'state_reason': 'completed'}), router.writes)
        router, rows = self.build()
        router.on(r'^pulls\?state=closed', sm_status.GitHubError('HTTP 502'))
        self.apply(router, rows)
        self.assertEqual(router.writes, [])
        self.assertIsNone(sweep.collect(router, NOW, snapshot(rows))['merged_fixes'])

    def test_the_closed_pr_read_is_one_batched_call_not_one_per_issue(self):
        router, rows = self.build(pulls=[merged_pull(800, 'Closes #70', self.MERGED)])
        sweep.collect(router, NOW, snapshot(rows))
        closed = [r for r in router.reads if r.startswith('pulls?state=closed')]
        self.assertEqual(len([r for r in closed if '&base=main&' in r]), 1)   # rule 8 and rules 9-10 share it
        self.assertEqual(len(closed), 2)                                      # plus one page of the frozen `next`


class Output(unittest.TestCase):
    def test_a_quiet_world_says_nothing_to_do(self):
        comments = [claim(20, 'A', at(minutes=30)), claim(21, 'B', at(minutes=20))]
        facts = facts_of(world(comments=comments, ready=[issue(10, ['ready'])]))
        actions, slot = sweep.decide(facts)
        self.assertEqual(actions, [])
        self.assertIn('Nothing to do.', sweep.render(facts, actions, slot))
        self.assertIn('Claude 2 of 2 active', sweep.render(facts, actions, slot))

    def test_json_mode_and_a_saved_status_file(self):
        saved = FIXTURES.parent / 'sm_sweep' / 'status.json'
        saved.write_text(json.dumps(snapshot([pr(1575, red=True)])))
        try:
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                code = sweep.main(['--json', '--status-json', str(saved)], api=world(), now=NOW)
        finally:
            saved.unlink()
        data = json.loads(out.getvalue())
        self.assertEqual(code, 0)
        self.assertIn('armed-red', [a['rule'] for a in data['actions']])
        self.assertEqual(data['slots']['claude_allowed'], 2)

    def test_apply_refuses_a_stale_saved_snapshot_but_takes_a_fresh_one(self):
        saved = FIXTURES / 'status-stale.json'
        try:
            for age, expected in ((dict(minutes=30), 2), (dict(minutes=2), 0)):
                saved.write_text(json.dumps(dict(snapshot(), as_of=at(**age))))
                router = world()
                out, err = io.StringIO(), io.StringIO()
                with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                    code = sweep.main(['--apply', '--status-json', str(saved)], api=router, now=NOW)
                self.assertEqual(code, expected, age)
                if expected == 2:
                    self.assertEqual(router.writes, [])
                    self.assertIn('snapshot taken in the last 10 minutes', err.getvalue())
        finally:
            saved.unlink()

    def test_the_usage_breaker_is_read_as_far_back_as_the_dial_gate_reads_it(self):
        router = world()
        facts_of(router)
        since = next(path for path in router.reads if path.startswith('issues/337/comments'))
        self.assertIn(f'since={at(hours=12)}', since)
        self.assertEqual(sweep.USAGE_WINDOW, dt.timedelta(hours=12))

    def test_an_edited_comment_is_a_sign_of_life(self):
        edited = note(7, 'status', at(days=3))
        edited['updated_at'] = at(hours=1)
        router = world(in_progress=[issue(7, ['in-progress'])], comments=[edited])
        actions, _ = sweep.decide(facts_of(router))
        self.assertNotIn('stale-claim', rules(actions))

    def test_an_unreadable_dial_exits_2_and_prints_no_action_list(self):
        router = world()
        router.on(r'^issues/589$', sm_status.GitHubError('HTTP 401'))
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = sweep.main([], api=router, now=NOW)
        self.assertEqual((code, out.getvalue()), (2, ''))
        self.assertIn('ERROR', err.getvalue())


if __name__ == '__main__':
    unittest.main()


class Untriaged(unittest.TestCase):
    def test_issues_with_no_milestone_are_listed_however_old(self):
        old = issue(1256, created='2026-10-10T00:00:00Z')
        actions, _ = sweep.decide(facts_of(world(untriaged=[issue(1500, created='2026-10-14T00:00:00Z'), old])))
        found = [a for a in actions if a['rule'] == 'untriaged']
        self.assertEqual(len(found), 1)
        self.assertIn('2 open issue(s) have no milestone (oldest #1256, filed 2026-10-10)', found[0]['detail'])

    def test_nothing_untriaged_says_nothing(self):
        actions, _ = sweep.decide(facts_of(world()))
        self.assertNotIn('untriaged', rules(actions))

    def test_an_unreadable_listing_is_not_reported_as_a_backlog(self):
        router = world().on(r'^issues\?state=open&milestone=none', sm_status.GitHubError('boom'))
        actions, _ = sweep.decide(facts_of(router))
        self.assertNotIn('untriaged', rules(actions))


class UncheckedCards(unittest.TestCase):
    """#3872: a card for the owner names where its facts came from."""
    NEW = '2026-11-10T09:00:00Z'

    def found(self, *nodes):
        actions, _ = sweep.decide(facts_of(world(open_issues=nodes)))
        return [a for a in actions if a['rule'] == 'unchecked-card']

    def card(self, **kw):
        return gql_issue(9, **dict(dict(labels=['needs-owner'], created=self.NEW), **kw))

    def test_a_new_card_with_no_source_is_named(self):
        found = self.found(self.card(body='Please test share links on your phone.'))
        self.assertEqual(found[0]['issues'], [9])

    def test_these_are_not_flagged(self):
        rows = [('line in body', self.card(body='Ask\n**Checked:** sm_live, Build 36')),
                ('plain line', self.card(body='checked: docs/decisions.md')),
                ('list item', self.card(body='- Checked: the site')),
                ('in a comment', self.card(comments=[gql_comment('**Checked:** the tag', self.NEW)])),
                ('older card', self.card(created='2026-11-09T23:59:59Z')),
                ('a script\'s notice', self.card(bot=True)),
                ('not for the owner', self.card(labels=['ready']))]
        for name, node in rows:
            with self.subTest(name):
                self.assertEqual(self.found(node), [])

    def test_the_word_inside_a_sentence_is_not_a_source_line(self):
        self.assertEqual(len(self.found(self.card(body='I checked: nothing really, but also unchecked: x'))), 1)


class Unlabelled(unittest.TestCase):
    """#3521: a milestone and no state label left #3391 unseen for 39 hours, because rule 7 reads only no-milestone."""

    def found(self, *nodes):
        actions, _ = sweep.decide(facts_of(world(open_issues=nodes)))
        return [a for a in actions if a['rule'] == 'unlabelled']

    def test_the_issue_that_sat_for_39_hours_is_named(self):
        found = self.found(gql_issue(3391, milestone='Showcase', labels=['enhancement', 'found-on-phone']))
        self.assertEqual(len(found), 1)
        self.assertIn('1 open issue(s)', found[0]['detail'])
        self.assertEqual(found[0]['issues'], [3391])

    def test_labels_that_say_nothing_about_state_do_not_count(self):
        for label in ('bug', 'enhancement', 'priority', 'found-on-phone', 'found-by-audit', 'where:mac', 'hot-file'):
            with self.subTest(label=label):
                self.assertEqual(len(self.found(gql_issue(1, milestone='Showcase', labels=[label]))), 1)

    def test_every_state_label_counts_as_a_state(self):
        for label in sorted(sweep.STATE_LABELS):
            with self.subTest(label=label):
                self.assertEqual(self.found(gql_issue(1, milestone='Showcase', labels=['bug', label])), [])

    def test_the_states_threads_and_triage_rely_on_are_all_there(self):
        self.assertLessEqual({'ready', 'in-progress', 'needs-owner', 'deferred', 'blocked', 'parked', 'tracker',
                              'validate-by-use', 'agent-verify', 'needs-human-validation',
                              'status: needs-human-validation', 'type: research', 'needs-triage-review'},
                             sweep.STATE_LABELS)

    def test_later_is_a_state_of_its_own(self):
        self.assertEqual(self.found(gql_issue(1, milestone=sweep.PARKED_MILESTONE, labels=['bug'])), [])

    def test_no_milestone_is_rule_7s_not_this_one(self):
        self.assertEqual(self.found(gql_issue(1, labels=['bug'])), [])

    def test_a_similar_milestone_name_is_not_later(self):
        self.assertEqual(len(self.found(gql_issue(1, milestone='Later this week'))), 1)

    def test_many_are_one_line_with_a_count_and_the_oldest_first(self):
        found = self.found(*[gql_issue(n, milestone='Showcase') for n in range(100, 115)])
        self.assertEqual(len(found), 1)
        self.assertIn('15 open issue(s)', found[0]['detail'])
        self.assertIn('oldest #100', found[0]['detail'])
        self.assertEqual(found[0]['issues'], list(range(100, 110)))

    def test_nothing_to_report_says_nothing(self):
        self.assertEqual(self.found(gql_issue(1, milestone='Showcase', labels=['ready'])), [])

    def test_an_unreadable_scan_is_unreadable_not_clean(self):
        router = world()
        router.gql['issues'] = sm_status.GitHubError('boom')
        actions, _ = sweep.decide(facts_of(router))
        self.assertNotIn('unlabelled', rules(actions))
        self.assertIn('drift-unreadable', rules(actions))


class OutsideIssues(unittest.TestCase):
    def test_issues_awaiting_review_are_not_a_triage_backlog(self):
        held = issue(1900, labels=['needs-triage-review'])
        actions, _ = sweep.decide(facts_of(world(untriaged=[held, issue(1901)])))
        untriaged = [a for a in actions if a['rule'] == 'untriaged']
        self.assertEqual(untriaged[0]['issues'], [1901])
        outside = [a for a in actions if a['rule'] == 'outside-issues']
        self.assertEqual(outside[0]['issues'], [1900])

    def test_only_outside_issues_leave_no_triage_backlog(self):
        actions, _ = sweep.decide(facts_of(world(untriaged=[issue(1900, labels=['needs-triage-review'])])))
        self.assertNotIn('untriaged', rules(actions))
        self.assertIn('outside-issues', rules(actions))


class Strangers(unittest.TestCase):
    """#1822: nothing a stranger writes keeps a dead claim alive, halts the project or fakes the Dial gate."""

    def stranger(self, issue_number, body, when):
        return dict(note(issue_number, body, when), user={'login': 'mallory'}, author_association='NONE')

    def claims(self, comments):
        router = world(in_progress=[issue(50, ['in-progress'], title='Quiet one')], comments=comments,
                       events={50: [label_event(at(days=2))]})
        return {c['number']: c for c in facts_of(router)['in_progress']}

    def test_a_strangers_comment_is_no_sign_of_life_for_a_claim(self):
        self.assertEqual(self.claims([self.stranger(50, 'still working on it', at(minutes=5))])[50]['state'], 'stale')
        self.assertEqual(self.claims([note(50, 'still working on it', at(minutes=5))])[50]['state'], 'active')

    def test_a_strangers_claim_note_does_not_make_a_thread(self):
        forged = self.stranger(60, 'Claimed by project thread "Fake thread"', at(minutes=5))
        self.assertEqual(facts_of(world(comments=[forged]))['claude_active'], [])
        self.assertEqual(facts_of(world(comments=[claim(60, 'Real thread', at(minutes=5))]))['claude_active'],
                         ['Real thread'])

    def test_a_strangers_halt_on_the_tick_issue_halts_nothing(self):
        halt = dict(note(337, '**HALT (usage breaker: Claude)** (Mac tick)', at(minutes=1)), user={'login': 'mallory'},
                    author_association='NONE')
        router = world()
        router.on(r'^issues/337/comments', [halt])
        facts = facts_of(router)
        self.assertFalse(facts['usage']['halted'])
        self.assertIsNone(facts['tick'])

    def test_a_strangers_dial_status_comment_is_not_the_dial_gates(self):
        forged = {'body': '<!-- dial-gate-status -->\n- Now: Fire 9 threads.', 'user': {'login': 'mallory'},
                  'author_association': 'NONE'}
        self.assertIsNone(facts_of(world(status_comment=forged))['dial_now'])


# ---- Drift between GitHub and the code (rules 9 to 11, #3350). Each class starts from its real 2026-11-04 case. ----

def drift_actions(router, now, rows=()):
    actions, _ = sweep.decide(sweep.collect(router, now, snapshot(rows)))
    return [a for a in actions if a['rule'] in ('merged-still-open', 'revert-unnoted', 'revert-unchecked',
                                                'hold-lifted', 'drift-unreadable')]


def pull_on(base, number, title, body, merged_at, head=''):
    return {'number': number, 'title': title, 'body': body, 'merged_at': merged_at, 'head': {'ref': head},
            'base': {'ref': base}}


class MergedStillOpen(unittest.TestCase):
    """Rule 9. #3315 (`Closes #3218`) merged into main at 2026-11-04T02:02:41Z, GitHub left #3218 open and
    `in-progress`, and rule 8 looks only at `ready` issues; the daily triage closed it by hand at 02:38:33Z."""
    NOW = dt.datetime(2026, 11, 4, 2, 30, tzinfo=dt.timezone.utc)
    PR_3315 = pull_on('main', 3315, 'Shipped builds must play a shared HE-AAC Margin, not only import it (#3218)',
                      'Closes #3218\n\n## What this does', '2026-11-04T02:02:41Z', 'ws/3218-smaller-share-packets')

    def router(self, pulls, issues, next_pulls=()):
        router = world(open_issues=issues)
        router.on(r'^pulls\?state=closed&base=main', list(pulls))
        router.on(r'^pulls\?state=closed&base=next', list(next_pulls))
        return router

    def test_the_3218_case_is_reported(self):
        issue = gql_issue(3218, 'Smaller share packets', ('in-progress', 'priority', 'where:mac'))
        found = drift_actions(self.router([self.PR_3315], [issue]), self.NOW)
        self.assertEqual([(a['rule'], a['issues'], a['prs']) for a in found],
                         [('merged-still-open', [3218], [3315])])
        self.assertIn('merged into `main` on 2026-11-04', found[0]['detail'])

    def test_a_closing_pr_merged_into_next_counts_too(self):
        # #2207 (`Closes #138`) merged into next on 2026-10-20; a PR into a non-default branch never closes its issue
        pull = pull_on('next', 2207, 'PDF citations', 'Closes #138', '2026-10-20T04:00:00Z')
        found = drift_actions(self.router([], [gql_issue(138)], [pull]), self.NOW)
        self.assertEqual([(a['issues'], a['prs']) for a in found], [([138], [2207])])
        self.assertIn('`next`', found[0]['detail'])

    def test_reopened_after_the_merge_part_of_or_reverted_are_not_drift(self):
        reopened = gql_issue(3218, reopened='2026-11-04T02:20:00Z')
        self.assertEqual(drift_actions(self.router([self.PR_3315], [reopened]), self.NOW), [])
        part = dict(self.PR_3315, body='Part of #3218')
        self.assertEqual(drift_actions(self.router([part], [gql_issue(3218)]), self.NOW), [])
        revert = pull_on('main', 3316, 'Revert #3315: lane FAIL', 'Reverts #3315', '2026-11-04T02:10:00Z')
        router = self.router([self.PR_3315, revert], [gql_issue(3218)])
        router.on(r'^issues/3218/comments', [note(3218, 'Reverted by #3316; the fix is off main.', '2026-11-04T02:12:00Z')])
        self.assertEqual(drift_actions(router, self.NOW), [])

    def test_an_issue_reopened_before_the_merge_is_still_drift(self):
        issue = gql_issue(3218, reopened='2026-11-01T00:00:00Z')
        self.assertEqual(len(drift_actions(self.router([self.PR_3315], [issue]), self.NOW)), 1)

    def test_a_ready_issue_rule_8_reports_is_not_reported_twice(self):
        router = self.router([self.PR_3315], [gql_issue(3218, labels=('ready',))])
        router.on(r'^issues\?state=open&labels=ready', [issue(3218, ('ready',))])
        actions, _ = sweep.decide(sweep.collect(router, self.NOW, snapshot()))
        self.assertEqual([a['rule'] for a in actions if 3218 in a['issues'] and a['rule'] != 'free-slots'], ['fix-merged'])


class RevertUnnoted(unittest.TestCase):
    """Rule 10. #3310 (`Part of #460`, branch ws/460-skim-stops) merged 2026-11-03T22:26:23Z, #3320 reverted it at
    2026-11-04T03:25:38Z and #3323 re-landed it at 04:07:07Z; #460 said nothing of either until 17:18Z."""
    NOW = dt.datetime(2026, 11, 4, 12, 0, tzinfo=dt.timezone.utc)
    PR_3310 = pull_on('main', 3310, 'Skim goes to the next chapter or Margin; a second press plays the Margin (#460)',
                      'Part of #460', '2026-11-03T22:26:23Z', 'ws/460-skim-stops')
    PR_3320 = pull_on('main', 3320, 'Revert #3310: Tested as this exact commit and merged by the lane runner. '
                      '(integration-e1a99ad FAIL)', 'Reverts #3310 because the integration run on next at `e1a99ad` '
                      'failed.', '2026-11-04T03:25:38Z', 'revert/pr3310')
    PR_3323 = pull_on('main', 3323, 'Re-land #3310: Skim goes to the next chapter or Margin (#460)',
                      'Closes #3321. Part of #460.', '2026-11-04T04:07:07Z', 'ws/3321-reland-skim-next-margin')

    def router(self, pulls, comments_since=()):
        router = world()
        router.on(r'^pulls\?state=closed&base=main', list(pulls))
        router.on(r'^issues/460/comments\?since=', list(comments_since))
        return router

    def test_the_460_case_is_reported(self):
        router = self.router([self.PR_3323, self.PR_3320, self.PR_3310])
        found = drift_actions(router, self.NOW)
        self.assertEqual([(a['rule'], a['issues'], a['prs']) for a in found], [('revert-unnoted', [460], [3320, 3310])])
        self.assertIn('issues/460/comments?since=2026-11-04T03:25:38Z', router.reads)

    def test_a_note_naming_the_revert_clears_it_and_a_strangers_does_not(self):
        noted = note(460, '**Record correction.** #3310 was reverted by #3320 and re-landed by #3323.',
                     '2026-11-04T17:18:01Z')
        self.assertEqual(drift_actions(self.router([self.PR_3320, self.PR_3310], [noted]), self.NOW), [])
        stranger = dict(noted, author_association='NONE', user={'login': 'someone'})
        self.assertEqual(len(drift_actions(self.router([self.PR_3320, self.PR_3310], [stranger]), self.NOW)), 1)

    def test_a_revert_older_than_14_days_is_left_alone(self):
        later = dt.datetime(2026, 11, 19, 12, 0, tzinfo=dt.timezone.utc)
        self.assertEqual(drift_actions(self.router([self.PR_3320, self.PR_3310]), later), [])

    def test_a_reverted_pr_outside_the_list_is_looked_up_in_one_graphql_read(self):
        router = self.router([self.PR_3320])
        router.gql['lookup'] = lambda q, v: {'repository': {'n3310': gql_pull(
            3310, '2026-11-03T22:26:23Z', title=self.PR_3310['title'], body='Part of #460', head='ws/460-skim-stops')}}
        self.assertEqual([a['issues'] for a in drift_actions(router, self.NOW)], [[460]])
        self.assertEqual(router.reads.count('graphql:lookup'), 1)

    def test_the_comment_reads_are_capped_and_the_rest_is_named_unchecked(self):
        pulls = []
        for n in range(sweep.DRIFT_READ_CAP + 2):
            pulls.append(pull_on('main', 1000 + n, f'Fix (#{2000 + n})', f'Part of #{2000 + n}', '2026-11-03T20:00:00Z'))
            pulls.append(pull_on('main', 3000 + n, f'Revert #{1000 + n}', f'Reverts #{1000 + n}', '2026-11-04T03:00:00Z'))
        router = self.router(pulls)
        router.on(r'^issues/\d+/comments\?since=', [])
        found = drift_actions(router, self.NOW)
        self.assertEqual(len([r for r in router.reads if '/comments?since=2026-11-04T03' in r]), sweep.DRIFT_READ_CAP)
        self.assertEqual([a['rule'] for a in found].count('revert-unnoted'), sweep.DRIFT_READ_CAP)
        self.assertEqual([a['rule'] for a in found].count('revert-unchecked'), 1)


class HoldLifted(unittest.TestCase):
    """Rule 11. #1612's newest note (2026-10-18) held it on PR #1154, which merged into `next` on
    2026-10-20T04:27:34Z (merge a6a838a) with no closing ref; the issue sat open until 2026-11-04T17:17Z."""
    NOW = dt.datetime(2026, 11, 4, 12, 0, tzinfo=dt.timezone.utc)
    NOTE_1015 = gql_comment('Blocked behind PR #1154, which the owner is holding until Solid Ground ships; taking '
                            'this off ready so dispatch stops suggesting it.', '2026-10-15T12:26:30Z')
    NOTE_1018 = gql_comment("**Housekeeping (owner's 2026-10-14 standing call)**\n\nRemoved `blocked`. It was only the "
                            "owner's hold on PR #1154, which carries this issue's fix, until Solid Ground ships.",
                            '2026-10-18T04:35:51Z')
    PR_1154 = gql_pull(1154, '2026-10-20T04:27:34Z', base='next')

    def router(self, comments, lookup=None):
        return world(open_issues=[gql_issue(1612, 'Review new Margins loses the place', ('bug', 'priority'), comments)],
                     lookup=lookup if lookup is not None else {1154: self.PR_1154})

    def test_the_1612_case_is_reported(self):
        router = self.router([self.NOTE_1015, self.NOTE_1018])
        found = drift_actions(router, self.NOW)
        self.assertEqual([(a['rule'], a['issues'], a['prs']) for a in found], [('hold-lifted', [1612], [1154])])
        self.assertIn('merged into `next` on 2026-10-20', found[0]['detail'])

    def test_a_pr_merged_before_the_note_is_no_hold(self):
        after = gql_comment('PR #1154 merged; holding this open until the owner hears it on the phone.',
                            '2026-10-21T00:00:00Z')
        self.assertEqual(drift_actions(self.router([self.NOTE_1018, after]), self.NOW), [])

    def test_a_pr_named_beside_a_wait_on_someone_else_is_no_hold(self):
        # #2842's real stop note: the wait is on the owner, not on #3306
        stop_note = gql_comment('Thread "Fix consent and privacy wording" stopping: #3306 armed (`automerge`, Part of '
                                "#2842) · waiting on the owner's three wording answers above", '2026-11-03T18:37:46Z')
        router = self.router([stop_note], lookup={3306: gql_pull(3306, '2026-11-03T20:00:00Z')})
        self.assertEqual(drift_actions(router, self.NOW), [])

    def test_an_unmerged_or_issue_number_is_no_hold(self):
        self.assertEqual(drift_actions(self.router([self.NOTE_1018], lookup={1154: gql_pull(1154, None)}), self.NOW), [])
        self.assertEqual(drift_actions(self.router([self.NOTE_1018], lookup={}), self.NOW), [])

    def test_only_the_newest_trusted_note_counts(self):
        stranger = gql_comment('still broken for me', '2026-10-25T00:00:00Z', association='NONE', login='someone')
        self.assertEqual(len(drift_actions(self.router([self.NOTE_1018, stranger]), self.NOW)), 1)
        newer = gql_comment('Waiting on the owner\'s phone check.', '2026-10-25T00:00:00Z')
        self.assertEqual(drift_actions(self.router([self.NOTE_1018, newer]), self.NOW), [])

    def test_a_wait_on_the_frozen_next_is_reported(self):
        waits = gql_comment('This issue stays open until the fix reaches `next`.', '2026-10-15T23:00:26Z')
        found = drift_actions(self.router([waits], lookup={}), self.NOW)
        self.assertEqual([(a['issues'], a['prs']) for a in found], [([1612], [])])
        self.assertIn('waits on `next`', found[0]['detail'])
        plain = gql_comment('Next step: the Next Margin button waits for the owner.', '2026-10-15T23:00:26Z')
        self.assertEqual(drift_actions(self.router([plain], lookup={}), self.NOW), [])


class DriftReadBudget(unittest.TestCase):
    NOW = dt.datetime(2026, 11, 4, 12, 0, tzinfo=dt.timezone.utc)

    def test_a_failed_scan_is_reported_unreadable_never_clean(self):
        router = world()
        router.gql['issues'] = sm_status.GitHubError('GraphQL: rate limited')
        found = drift_actions(router, self.NOW)
        self.assertEqual([a['rule'] for a in found], ['drift-unreadable'])
        self.assertIn('rate limited', found[0]['detail'])

    def test_the_scan_pages_through_open_issues_without_per_issue_reads(self):
        pages = iter([
            {'repository': {'issues': {'pageInfo': {'hasNextPage': True, 'endCursor': 'c1'},
                                       'nodes': [gql_issue(n) for n in range(1, 101)]}}},
            {'repository': {'issues': {'pageInfo': {'hasNextPage': False, 'endCursor': None},
                                       'nodes': [gql_issue(n) for n in range(101, 171)]}}}])
        router = world()
        router.gql['issues'] = lambda q, v: next(pages)
        drift_actions(router, self.NOW)
        self.assertEqual(router.reads.count('graphql:issues'), 2)
        self.assertEqual([r for r in router.reads if re.match(r'issues/(?!589/|337/)\d+/comments', r)], [])

    def test_more_open_issues_than_the_page_cap_is_unreadable(self):
        router = world()
        router.gql['issues'] = {'repository': {'issues': {'pageInfo': {'hasNextPage': True, 'endCursor': 'c'},
                                                          'nodes': []}}}
        self.assertEqual([a['rule'] for a in drift_actions(router, self.NOW)], ['drift-unreadable'])
        self.assertEqual(router.reads.count('graphql:issues'), sweep.OPEN_ISSUE_PAGES)

    def test_graphql_errors_answered_with_http_200_are_raised(self):
        class Answers(sm_status.GitHub):
            def __init__(self, answer):
                super().__init__('example/repo', token='t')
                self.answer = answer

            def request(self, method, path, body=None):
                self.sent = (method, path, body)
                return self.answer, {}
        api = Answers({'errors': [{'message': 'Something went wrong'}], 'data': None})
        with self.assertRaises(sm_status.GitHubError):
            api.graphql('query { viewer { login } }')
        self.assertEqual(api.sent[:2], ('POST', 'https://api.github.com/graphql'))
        self.assertEqual(Answers({'data': {'ok': 1}}).graphql('query { x }'), {'ok': 1})
