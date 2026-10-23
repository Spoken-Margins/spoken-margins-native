"""scripts/sm_status.py (#1597): the one-call snapshot of open PRs, and the flags a status reply must not hide.

Nothing here touches the network. The PR bundles in scripts/fixtures/sm_status/ were recorded from the live repo on
2026-10-14 (scripts/fixtures/sm_status/record.py): #1585 (T3 FAIL, an INCONCLUSIVE automerge run, a conflict),
#1595 (a PASS on an older head, lane and .github changes), #1590 (PASS on the head, clean audit), #1596 (T3 PASS,
no audit yet) and #1568. The other cases are those bundles, or small hand-built ones, changed one fact at a time.
"""
import os
os.environ.pop('SM_TRUNK', None)  # fixtures are written for the default trunk; the lane and the Mac export SM_TRUNK (#1492)
import contextlib
import copy
import datetime as dt
import io
import json
import re
import sys
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
import sm_status as status  # noqa: E402

FIXTURES = SCRIPTS / 'fixtures' / 'sm_status'
NOW = dt.datetime(2026, 10, 14, 20, 0, tzinfo=dt.timezone.utc)
HEAD = 'a' * 40
OLD = 'b' * 40


def fixture(number):
    return json.loads((FIXTURES / f'pr-{number}.json').read_text())


def codes(row):
    return sorted(f['code'] for f in row['flags'])


def comment(body, login='uncomposed', at='2026-10-14T18:00:00Z', n=[0], association=None):
    n[0] += 1
    association = association or ('NONE' if login.endswith('[bot]') else 'OWNER')  # as GitHub reports them
    return {'id': n[0], 'user': {'login': login}, 'author_association': association, 'created_at': at,
            'html_url': f'https://example.test/c{n[0]}',
            'issue_url': 'https://api.github.com/repos/x/y/issues/1', 'body': body}


def report(verdict, commit=HEAD, tier='auto', rid='pr1-r1', at='2026-10-14T18:30:00Z'):
    marker = json.dumps({'commit': commit, 'tier': tier, 'tests': []}, sort_keys=True)
    return comment(f'Lane report {rid} — {verdict}\ncommit {commit[:7]} (tested merged with next at 1234567) · tier {tier}\n'
                   f'ran: x\n<!-- lane-request: {marker} -->\n', login=status.LANE_BOT, at=at)


def request(tier='T3', commit=HEAD[:7], at='2026-10-14T18:10:00Z'):
    return comment(f'/lane {tier}\ncommit: {commit}\nchanged: something\ntests: SomeTests\n', at=at)


def audit(verdict='No blocking findings.', sha=HEAD[:7], who='Claude', at='2026-10-14T18:40:00Z'):
    heading = f'**Claude audit on `{sha}`**' if who == 'Claude' else f'**Codex audit (Astra) on `{sha}`**'
    return comment(f'{heading}\n\n{verdict}\n', at=at)


def bundle(comments=(), labels=('automerge',), files=('docs/x.md',), checks=(), events=None, mergeable=True,
           state='clean', head=HEAD, body='Closes #7', draft=False):
    return {'pull': {'number': 1, 'title': 'A change', 'html_url': 'https://example.test/pull/1', 'state': 'open',
                     'draft': draft, 'mergeable': mergeable, 'mergeable_state': state, 'body': body,
                     'labels': [{'name': l} for l in labels], 'head': {'sha': head, 'ref': 'ws/7-a-change'}},
            'comments': list(comments), 'files': [{'filename': f} for f in files], 'check_runs': list(checks),
            'events': events if events is not None else ([{'event': 'labeled', 'created_at': '2026-10-14T18:00:00Z',
                                                           'label': {'name': 'automerge'}}] if 'automerge' in labels else []),
            'errors': {}}


APP_FILE = 'App/SpokenMarginsApp/Sources/SpokenMarginsApp/Gate1AppModel.swift'


class FakeAPI:
    """Answers GitHub reads from a table of path -> response; an Exception value is raised."""
    repo = 'example/repo'

    def __init__(self, routes):
        self.routes, self.calls = routes, []

    def _answer(self, path):
        self.calls.append(path)
        value = self.routes[path]
        if isinstance(value, Exception):
            raise value
        return copy.deepcopy(value)

    get = pages = _answer


def routes_for(*bundles, tip=HEAD):
    routes = {'pulls?state=open&base=main&sort=created&direction=asc': [b['pull'] for b in bundles],
              'git/ref/heads/main': {'object': {'sha': tip}}}
    for b in bundles:
        n, sha = b['pull']['number'], b['pull']['head']['sha']
        routes.update({f'pulls/{n}': b['pull'], f'issues/{n}/comments': b['comments'],
                       f'issues/{n}/events': b['events'], f'pulls/{n}/files': b['files'],
                       f'commits/{sha}/check-runs': b['check_runs']})
    return routes


class RecordedPullRequests(unittest.TestCase):
    """What the status line says for real PRs as GitHub reported them."""

    def test_1585_is_red_three_ways_and_not_called_armed_and_waiting(self):
        row = status.analyse(fixture(1585))
        self.assertEqual(row['head7'], 'be77e06')
        self.assertEqual(row['lane']['verdict'], 'INCONCLUSIVE')
        self.assertEqual(row['t3']['verdict'], 'FAIL')
        self.assertEqual(row['mergeable'], 'conflict')
        self.assertIn('red-on-head', codes(row))
        self.assertIn('conflict', codes(row))
        self.assertIn('t3-held', codes(row))
        self.assertIn('inconclusive-on-head', codes(row))
        self.assertEqual(row['issue'], 322)
        self.assertIn('lane', row['checks']['failing'])

    def test_1595_shows_no_lane_verdict_for_its_head_because_the_pass_is_on_an_older_one(self):
        row = status.analyse(fixture(1595))
        self.assertEqual(row['head7'], '48b346e')
        self.assertIsNone(row['lane'])
        self.assertEqual(row['lane_elsewhere']['commit7'], '094206d')
        self.assertIn('older-head-only', codes(row))
        self.assertIn('owner-tap', codes(row))
        self.assertIn('audit-pending', codes(row))      # the audit on file names 094206d, not the head
        self.assertIn('none on head', status.line(row))
        self.assertNotIn('lane PASS', status.line(row))

    def test_1590_with_a_pass_and_a_clean_audit_on_its_head_has_no_flags(self):
        row = status.analyse(fixture(1590))
        self.assertEqual(row['flags'], [])
        self.assertEqual(row['lane']['verdict'], 'PASS')
        self.assertEqual(row['audit'], {'verdict': 'clean', 'who': 'Claude', 'at': row['audit']['at']})
        self.assertEqual(row['labels'], ['automerge'])

    def test_1596_has_a_t3_pass_but_audio_work_with_no_audit_on_its_head(self):
        row = status.analyse(fixture(1596))
        self.assertEqual(codes(row), ['audit-pending'])
        self.assertEqual(row['lane']['tier'], 'T3')

    def test_1568_is_the_lane_change_with_an_audit_the_head_has(self):
        row = status.analyse(fixture(1568))
        self.assertEqual(row['head7'], 'eccda27')
        self.assertEqual(row['lane']['verdict'], 'PASS')
        self.assertNotIn('red-on-head', codes(row))


class OlderHead(unittest.TestCase):
    """The case that sent the owner a wrong "armed": a report that is about another commit."""

    def test_a_pass_on_an_older_head_is_not_the_heads_verdict(self):
        row = status.analyse(bundle([report('PASS', commit=OLD)]))
        self.assertIsNone(row['lane'])
        self.assertEqual(codes(row), ['older-head-only'])
        self.assertIn('lane none on head (only PASS on bbbbbbb)', status.line(row))

    def test_a_fail_on_an_older_head_is_not_red_on_the_new_one(self):
        row = status.analyse(bundle([report('FAIL', commit=OLD, rid='pr1-r1'),
                                     report('PASS', commit=HEAD, rid='pr1-r2')]))
        self.assertNotIn('red-on-head', codes(row))
        self.assertEqual(row['lane']['verdict'], 'PASS')

    def test_the_older_head_check_follows_the_head_not_the_newest_report(self):
        # the PR moved from OLD to HEAD after the report; the same comments on the old head read quiet
        comments = [report('PASS', commit=OLD)]
        self.assertEqual(codes(status.analyse(bundle(comments, head=OLD))), [])
        self.assertEqual(codes(status.analyse(bundle(comments, head=HEAD))), ['older-head-only'])

    def test_no_reports_at_all_is_not_older_head_only(self):
        row = status.analyse(bundle([]))
        self.assertEqual(codes(row), [])
        self.assertIn('none on head', status.line(row))


class RedOnHead(unittest.TestCase):
    def test_a_fail_report_on_the_head_is_red(self):
        row = status.analyse(bundle([report('FAIL')]))
        self.assertEqual(codes(row), ['red-on-head'])
        self.assertIn('!!', status.line(row))

    def test_a_t3_fail_on_the_head_is_red_even_after_a_later_automerge_pass(self):
        row = status.analyse(bundle([request(), report('FAIL', tier='T3', rid='pr1-r1'),
                                     report('PASS', tier='auto', rid='pr1-r2', at='2026-10-14T18:50:00Z')]))
        self.assertIn('red-on-head', codes(row))
        self.assertIn('t3-held', codes(row))

    def test_a_failing_check_run_is_red_without_any_report(self):
        row = status.analyse(bundle(checks=[{'id': 5, 'name': 'sessionkit-core', 'status': 'completed',
                                             'conclusion': 'failure'}]))
        self.assertEqual(codes(row), ['red-on-head'])
        self.assertEqual(row['checks']['failing'], ['sessionkit-core'])

    def test_a_later_green_run_of_the_same_check_clears_it_but_a_skipped_one_does_not(self):
        failed = {'id': 5, 'name': 'lane', 'status': 'completed', 'conclusion': 'failure'}
        green = {'id': 9, 'name': 'lane', 'status': 'completed', 'conclusion': 'success'}
        skipped = {'id': 9, 'name': 'lane', 'status': 'completed', 'conclusion': 'skipped'}
        self.assertEqual(status.analyse(bundle(checks=[failed, green]))['checks']['failing'], [])
        self.assertEqual(status.analyse(bundle(checks=[failed, skipped]))['checks']['failing'], ['lane'])

    def test_a_running_check_is_listed_but_not_red(self):
        row = status.analyse(bundle(checks=[{'id': 5, 'name': 'automerge', 'status': 'in_progress', 'conclusion': None}]))
        self.assertEqual(row['checks']['running'], ['automerge'])
        self.assertEqual(row['flags'], [])

    def test_an_inconclusive_report_is_not_a_pass_and_is_flagged(self):
        row = status.analyse(bundle([report('INCONCLUSIVE')]))
        self.assertEqual(codes(row), ['inconclusive-on-head'])

    def test_only_the_runner_bot_can_post_a_lane_report(self):
        forged = report('PASS')
        forged['user']['login'] = 'uncomposed'
        row = status.analyse(bundle([forged]))
        self.assertIsNone(row['lane'])
        self.assertEqual(codes(row), [])


class Strangers(unittest.TestCase):
    """#1822: a stranger's look-alike of a lane report, a /lane request, an audit or a hand-off is data."""
    AUDIO = ['Packages/SessionKit/Sources/SessionKitAudio/Thing.swift']
    CLEAN_BODY = '**Claude audit on `%s`**\n\nNo blocking findings.\n' % HEAD[:7]

    def stranger(self, body, login='mallory', association='NONE', **kw):
        return comment(body, login=login, association=association, **kw)

    def test_a_stranger_cannot_clear_the_pending_audit(self):
        row = status.analyse(bundle([self.stranger(self.CLEAN_BODY)], files=self.AUDIO))
        self.assertEqual(codes(row), ['audit-pending'])
        self.assertIsNone(row['audit'])

    def test_a_stranger_cannot_clear_a_blocking_audit_with_a_later_clean_one(self):
        blocking = audit('Blocking: the wrong item is played.', at='2026-10-14T18:40:00Z')
        forged = self.stranger(self.CLEAN_BODY, association='CONTRIBUTOR', at='2026-10-14T18:50:00Z')
        row = status.analyse(bundle([blocking, forged], files=self.AUDIO))
        self.assertEqual(codes(row), ['audit-blocking'])
        self.assertEqual(row['audit']['verdict'], 'blocking')

    def test_a_stranger_cannot_post_a_request_that_holds_the_merge(self):
        row = status.analyse(bundle([self.stranger('/lane T3\ncommit: %s\nchanged: x\ntests: SomeTests\n' % HEAD[:7])],
                                    labels=('automerge', 'lane:queued')))
        self.assertEqual(codes(row), [])

    def test_a_stranger_cannot_fake_the_runner_by_name(self):
        for login in ('github-actions', 'github-actions[bot]x', 'mallory'):
            with self.subTest(login=login):
                forged = report('PASS')
                forged['user']['login'] = login
                forged['author_association'] = 'NONE'
                self.assertIsNone(status.analyse(bundle([forged]))['lane'])

    def test_a_stranger_cannot_post_the_mac_hand_off(self):
        later = comment('Pushed a fix', at='2026-10-14T19:30:00Z')
        hand = lambda **kw: comment('Handing to the Mac finisher: build fails', at='2026-10-14T19:00:00Z', **kw)
        labels = ('needs-mac',)
        real = status.analyse(bundle([hand(), later], labels=labels))['mac']
        self.assertEqual((real['since'], real['finisher_active_at']), ('2026-10-14T19:00:00Z', '2026-10-14T19:30:00Z'))
        forged = status.analyse(bundle([hand(login='mallory', association='NONE'), later], labels=labels))['mac']
        self.assertNotEqual(forged['since'], '2026-10-14T19:00:00Z')


class T3Gate(unittest.TestCase):
    QUEUED = ('automerge', 'lane:queued')

    def test_a_request_with_no_report_holds_the_merge(self):
        row = status.analyse(bundle([request()], labels=self.QUEUED))
        self.assertEqual(codes(row), ['t3-held'])

    def test_a_request_nothing_will_run_is_called_out(self):
        # lane.yml runs on the label event: no lane:queued / lane:running means the request sits forever
        self.assertEqual(codes(status.analyse(bundle([request()]))), ['t3-held', 't3-unqueued'])
        self.assertEqual(codes(status.analyse(bundle([request()], labels=('automerge', 'lane:running')))), ['t3-held'])

    def test_a_t3_pass_after_the_request_releases_it(self):
        row = status.analyse(bundle([request(), report('PASS', tier='T3')]))
        self.assertEqual(codes(row), [])
        self.assertEqual(codes(status.analyse(bundle([request(), report('PASS', tier='T3')], labels=self.QUEUED))), [])

    def test_a_t3_fail_on_an_earlier_commit_still_holds_a_new_head(self):
        row = status.analyse(bundle([request(commit=OLD[:7]), report('FAIL', commit=OLD, tier='T3')]))
        held = [f for f in row['flags'] if f['code'] == 't3-held']
        self.assertEqual(held[0]['severity'], status.RED)
        self.assertIn('not the head', held[0]['detail'])

    def test_a_new_request_after_the_fail_is_waiting_not_red(self):
        row = status.analyse(bundle([request(commit=OLD[:7]), report('FAIL', commit=OLD, tier='T3'),
                                     request(at='2026-10-14T19:00:00Z')], labels=self.QUEUED))
        held = [f for f in row['flags'] if f['code'] == 't3-held']
        self.assertEqual([f['severity'] for f in held], [status.LOOK])


class Conflict(unittest.TestCase):
    def test_dirty_and_mergeable_false_are_conflicts(self):
        self.assertEqual(codes(status.analyse(bundle(mergeable=False, state='dirty'))), ['conflict'])
        self.assertEqual(codes(status.analyse(bundle(mergeable=None, state='dirty'))), ['conflict'])

    def test_clean_behind_unstable_and_unknown_are_named_not_flagged(self):
        for state, word in (('clean', 'clean'), ('behind', 'behind'), ('unstable', 'unstable'), ('unknown', 'unknown')):
            with self.subTest(state=state):
                row = status.analyse(bundle(mergeable=None if state == 'unknown' else True, state=state))
                self.assertEqual(row['mergeable'], word)
                self.assertEqual(row['flags'], [])

    def test_a_draft_says_so_but_a_conflicting_draft_is_still_a_conflict(self):
        self.assertEqual(status.analyse(bundle(draft=True, state='draft'))['mergeable'], 'draft')
        self.assertEqual(codes(status.analyse(bundle(draft=True, mergeable=False, state='dirty'))), ['conflict'])


class HeldByTheRunner(unittest.TestCase):
    def held_report(self, line):
        marker = json.dumps({'commit': HEAD, 'tier': 'auto'})
        return comment(f'Lane report pr1-r9 — PASS\ncommit {HEAD[:7]} (tested merged with next at 1234567) · tier auto\n'
                       f'ran: x\n{line}\n<!-- lane-request: {marker} -->\n', login=status.LANE_BOT)

    def test_a_pass_that_did_not_merge_is_flagged_with_the_runners_reason(self):
        for line in ('not merged by the runner: it inherits a blocking audit finding on #1568',
                     'not merged: the PR moved on, lost the automerge label',
                     'not merged: next kept moving (3 attempts)'):
            with self.subTest(line=line):
                row = status.analyse(bundle([self.held_report(line)]))
                self.assertEqual(codes(row), ['held-by-runner'])
                self.assertIn(line.split(': ', 1)[1][:30], row['flags'][0]['detail'])

    def test_a_plain_pass_is_not_held(self):
        self.assertEqual(codes(status.analyse(bundle([report('PASS')]))), [])

    def test_a_hold_on_an_older_head_is_not_this_heads(self):
        old = self.held_report('not merged: next kept moving (3 attempts)')
        old['body'] = old['body'].replace(HEAD, OLD)
        self.assertEqual(codes(status.analyse(bundle([old]))), ['older-head-only'])


class ArmedWithoutARequest(unittest.TestCase):
    def test_an_armed_app_change_with_no_t3_request_is_flagged(self):
        row = status.analyse(bundle(files=[APP_FILE]))
        self.assertEqual(codes(row), ['armed-no-lane-request'])

    def test_a_request_or_a_t3_report_answers_it(self):
        self.assertEqual(codes(status.analyse(bundle([request()], files=[APP_FILE], labels=('automerge', 'lane:queued')))),
                         ['t3-held'])
        self.assertEqual(codes(status.analyse(bundle([request(), report('PASS', tier='T3')], files=[APP_FILE]))), [])

    def test_an_unarmed_pr_or_a_docs_change_is_not_flagged(self):
        self.assertEqual(codes(status.analyse(bundle(files=[APP_FILE], labels=()))), [])
        self.assertEqual(codes(status.analyse(bundle(files=['docs/journeys.md']))), [])

    def test_a_lane_request_for_t4_does_not_count_as_a_t3_request(self):
        self.assertEqual(codes(status.analyse(bundle([request('T4')], files=[APP_FILE]))), ['armed-no-lane-request'])

    def test_an_unknown_scope_says_so_instead_of_judging_what_it_cannot_know(self):
        def broken(paths):
            raise OSError('no checkout')
        row = status.analyse(bundle(files=[APP_FILE]), classify=broken)
        self.assertEqual(codes(row), ['scope-unknown'])


class Audits(unittest.TestCase):
    AUDIO = ['Packages/SessionKit/Sources/SessionKitAudio/Thing.swift']

    def test_a_clean_audit_of_the_head_clears_the_pending_flag(self):
        self.assertEqual(codes(status.analyse(bundle(files=self.AUDIO))), ['audit-pending'])
        self.assertEqual(codes(status.analyse(bundle([audit()], files=self.AUDIO))), [])
        self.assertEqual(codes(status.analyse(bundle([audit(who='Codex')], files=self.AUDIO))), [])

    def test_findings_on_the_head_are_red(self):
        row = status.analyse(bundle([audit('Blocking: the description has no Cost and catch.')], files=self.AUDIO))
        self.assertEqual(codes(row), ['audit-blocking'])
        self.assertEqual(row['audit']['verdict'], 'blocking')

    def test_findings_on_a_change_the_runner_does_not_audit_are_shown_but_not_red(self):
        row = status.analyse(bundle([audit('Blocking: x')], files=['docs/x.md']))
        self.assertEqual(codes(row), ['audit-blocking'])
        self.assertEqual(row['flags'][0]['severity'], status.LOOK)

    def test_a_clean_audit_of_an_older_head_does_not_clear_it(self):
        row = status.analyse(bundle([audit(sha=OLD[:7])], files=self.AUDIO))
        self.assertEqual(codes(row), ['audit-pending'])
        self.assertIn('bbbbbbb', row['flags'][0]['detail'])

    def test_the_newest_audit_of_the_head_decides(self):
        row = status.analyse(bundle([audit('Blocking: x', at='2026-10-14T18:00:00Z'),
                                     audit(at='2026-10-14T19:00:00Z')], files=self.AUDIO))
        self.assertEqual(codes(row), [])

    def test_a_finishers_reply_naming_an_audit_is_not_an_audit(self):
        reply = comment('**Codex audit on `aaaaaaa` (P2): fixed in `ccccccc`** and pushed.')
        self.assertEqual(status.audits([reply]), [])

    def test_changes_that_are_not_audited_kinds_want_no_audit(self):
        row = status.analyse(bundle(files=['docs/x.md']))
        self.assertEqual(row['audit_needed'], [])
        self.assertIn('audit not needed', status.line(row))


class LabelsAndIssue(unittest.TestCase):
    def test_only_the_labels_that_matter_are_shown(self):
        row = status.analyse(bundle(labels=('automerge', 'lane:done', 'needs-mac', 'lane:queued', 'merge-audit', 'x')))
        self.assertEqual(row['labels'], ['automerge', 'needs-mac', 'lane:queued', 'merge-audit'])

    def test_the_linked_issue_comes_from_closing_words_then_the_branch(self):
        self.assertEqual(status.linked_issue({'body': 'Closes #12 and more', 'head': {'ref': 'x'}}), 12)
        self.assertEqual(status.linked_issue({'body': 'fixes: #13', 'head': {'ref': 'x'}}), 13)
        self.assertEqual(status.linked_issue({'body': 'refs #14', 'head': {'ref': 'ws/15-slug'}}), 15)
        self.assertIsNone(status.linked_issue({'body': '', 'head': {'ref': 'claude/x'}}))

    def test_armed_since_is_the_latest_add_still_in_force(self):
        add = lambda at: {'event': 'labeled', 'created_at': at, 'label': {'name': 'automerge'}}
        remove = lambda at: {'event': 'unlabeled', 'created_at': at, 'label': {'name': 'automerge'}}
        self.assertEqual(status.armed_since([add('t1'), remove('t2'), add('t3')]), 't3')
        self.assertIsNone(status.armed_since([add('t1'), remove('t2')]))


class Snapshot(unittest.TestCase):
    def test_a_snapshot_reads_every_open_pr_and_counts_them(self):
        red = bundle([report('FAIL')])
        quiet = bundle([report('PASS')])
        quiet['pull'] = dict(quiet['pull'], number=2)
        api = FakeAPI(routes_for(red, quiet))
        snap = status.snapshot(api, NOW, sleep=lambda s: None)
        self.assertEqual(snap['counts'], {'open': 2, 'red': 1, 'look': 0, 'armed': 2})
        self.assertEqual(snap['base_tip'], 'aaaaaaa')
        self.assertEqual([r['number'] for r in snap['prs']], [1, 2])
        json.dumps(snap)   # every value is plain data

    def test_the_text_says_what_it_checked_and_lists_flags_under_the_lines(self):
        text = status.render(status.snapshot(FakeAPI(routes_for(bundle([report('FAIL')]))), NOW, sleep=lambda s: None))
        self.assertIn('1 open, 1 armed, 1 red, 0 to look at', text)
        self.assertRegex(text, r'!! #1 aaaaaaa \| lane FAIL \(auto\)')
        self.assertIn('#1 red-on-head (red)', text)
        self.assertIn('none on head', text.splitlines()[-1])

    def test_only_filters_by_number(self):
        a, b = bundle(), bundle()
        b['pull'] = dict(b['pull'], number=2)
        snap = status.snapshot(FakeAPI(routes_for(a, b)), NOW, only=[2], sleep=lambda s: None)
        self.assertEqual([r['number'] for r in snap['prs']], [2])

    def test_asking_for_a_pr_that_is_not_open_says_so_instead_of_saying_nothing_is_pending(self):
        snap = status.snapshot(FakeAPI(routes_for(bundle())), NOW, only=[99], sleep=lambda s: None)
        self.assertEqual(snap['missing'], [99])
        self.assertIn('#99 is not an open PR into main', status.render(snap))
        self.assertNotIn('(no open PRs)', status.render(snap))

    def test_running_and_failing_checks_show_in_the_line(self):
        run = {'id': 1, 'name': 'automerge', 'status': 'in_progress', 'conclusion': None}
        bad = {'id': 2, 'name': 'lane', 'status': 'completed', 'conclusion': 'failure'}
        self.assertIn('checks running automerge', status.line(status.analyse(bundle(checks=[run]))))
        self.assertIn('checks failing lane', status.line(status.analyse(bundle(checks=[bad]))))
        self.assertIn('checks ok', status.line(status.analyse(bundle())))

    def test_no_open_prs_says_so(self):
        text = status.render(status.snapshot(FakeAPI(routes_for()), NOW, sleep=lambda s: None))
        self.assertIn('(no open PRs)', text)

    def test_a_failed_read_for_one_pr_is_a_flag_not_a_quiet_pr(self):
        good = bundle([report('PASS')])
        routes = routes_for(good)
        routes['issues/1/comments'] = status.GitHubError('GET issues/1/comments: HTTP 502')
        row = status.snapshot(FakeAPI(routes), NOW, sleep=lambda s: None)['prs'][0]
        self.assertEqual(codes(row), ['unreadable'])
        self.assertEqual(row['flags'][0]['severity'], status.RED)

    def test_an_unreadable_pr_list_exits_2_and_prints_nothing_as_a_status(self):
        routes = {'pulls?state=open&base=main&sort=created&direction=asc': status.GitHubError('HTTP 401')}
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = status.main([], api=FakeAPI(routes), now=NOW)
        self.assertEqual((code, out.getvalue()), (2, ''))
        self.assertIn('ERROR', err.getvalue())

    def test_json_mode_prints_the_snapshot(self):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = status.main(['--json'], api=FakeAPI(routes_for(bundle([report('FAIL')]))), now=NOW)
        data = json.loads(out.getvalue())
        self.assertEqual(code, 0)
        self.assertEqual(data['prs'][0]['flags'][0]['code'], 'red-on-head')

    def test_mergeability_is_read_again_once_when_github_has_not_worked_it_out(self):
        first = bundle(mergeable=None, state='unknown')
        second = bundle(mergeable=True, state='clean')
        answers = [first['pull'], second['pull']]

        class Slow(FakeAPI):
            def _answer(self, path):
                if path == 'pulls/1':
                    self.calls.append(path)
                    return answers.pop(0)
                return super()._answer(path)
            get = pages = _answer

        waits = []
        api = Slow(routes_for(first))
        fetched = status.fetch_bundle(api, first['pull'], sleep=waits.append)
        self.assertEqual((fetched['pull']['mergeable_state'], waits), ('clean', [2]))


class Paging(unittest.TestCase):
    """The cloud proxy refuses the `repositories/<id>/…` URLs in the Link header, so pages are asked for by number."""

    class Client(status.GitHub):
        def __init__(self, total):
            super().__init__('x/y', token='t')
            self.total, self.asked = total, []

        def request(self, method, path, body=None):
            self.asked.append(path)
            page = int(re.search(r'[&?]page=(\d+)', path).group(1))
            start = (page - 1) * 100
            return list(range(start, min(start + 100, self.total))), {}

    def test_pages_are_read_by_number_until_a_short_page(self):
        client = self.Client(250)
        self.assertEqual(len(client.pages('issues/comments?since=x')), 250)
        self.assertEqual(len(client.asked), 3)
        self.assertTrue(all('per_page=100' in path and 'since=x' in path for path in client.asked))

    def test_an_exact_multiple_reads_one_more_page(self):
        client = self.Client(200)
        self.assertEqual(len(client.pages('pulls')), 200)
        self.assertEqual(len(client.asked), 3)

    def test_too_many_pages_is_an_error_unless_a_partial_read_is_wanted(self):
        with self.assertRaises(status.GitHubError):
            self.Client(1000).pages('x', limit=3)
        self.assertEqual(len(self.Client(1000).pages('x', limit=3, partial=True)), 300)


class LaneFormatsStayInStep(unittest.TestCase):
    """sm_status mirrors a few lane-runner.py constants. If the runner changes them, these fail first."""

    @classmethod
    def setUpClass(cls):
        cls.runner = (SCRIPTS / 'lane-runner.py').read_text()

    def test_the_owner_tap_paths_match_the_runners(self):
        self.assertIn("OWNER_TAP_FILES = {'scripts/lane-runner.py'}", self.runner)
        self.assertIn("OWNER_TAP_PREFIXES = ('.github/',)", self.runner)
        self.assertEqual(status.OWNER_TAP_FILES, {'scripts/lane-runner.py'})
        self.assertEqual(status.OWNER_TAP_PREFIXES, ('.github/',))

    def test_the_audited_kinds_match_the_runners(self):
        runner = re.search(r"AUDITED = \{(.*?)\}", self.runner).group(1)
        self.assertEqual(dict(re.findall(r"'(\w+)': '([^']+)'", runner)),
                         {'audio': 'the audio session', 'persistence': 'persistence', 'packet': 'packets'})
        self.assertEqual(set(status.AUDITED_CATEGORIES), {'audio', 'persistence', 'packet'})

    def test_the_report_request_and_note_formats_match_the_runner(self):
        self.assertIn("REPORT = re.compile(r'^Lane report \\S+ — (PASS|FAIL|INCONCLUSIVE)', re.M)", self.runner)
        self.assertIn("REQUEST = re.compile(r'^\\s*/lane\\s+(T\\d)\\b', re.M)", self.runner)
        self.assertIn("NOTE = '<!-- lane-note -->'", self.runner)
        self.assertIn("BOT = ('github-actions[bot]'", self.runner)


class RequestHeaders(unittest.TestCase):
    """The real urllib.request.Request, not a fake client (#2265): a body with no Content-Type is sent form-encoded
    and GitHub answers 415."""

    def sent(self, call):
        from unittest import mock

        class Response:
            headers = {}

            def __enter__(self):
                return self

            def __exit__(self, *exc):
                return False

            def read(self):
                return b'[]'

        with mock.patch.object(status.urllib.request, 'urlopen', return_value=Response()) as opened:
            call(status.GitHub(token='t'))
        return opened.call_args.args[0]

    def test_a_post_with_a_body_says_it_is_json(self):
        req = self.sent(lambda api: api.post('issues/1/labels', {'labels': ['ready']}))
        self.assertEqual(req.get_header('Content-type'), 'application/json')
        self.assertEqual(json.loads(req.data), {'labels': ['ready']})

    def test_a_get_and_a_delete_carry_no_content_type(self):
        self.assertIsNone(self.sent(lambda api: api.get('issues/1')).get_header('Content-type'))
        self.assertIsNone(self.sent(lambda api: api.delete('issues/1/labels/x')).get_header('Content-type'))


if __name__ == '__main__':
    unittest.main()
