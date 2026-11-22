"""scripts/real_use_proof.py: what counts as real-use proof, and which issues need it (#4979).

The tables are the neighbouring inputs of a parsing rule: case, bullets and bold, empty and placeholder values, a FAIL,
a fixture-only input, a stranger's look-alike, a later record that overrides an earlier one.
"""
from __future__ import annotations

import datetime as dt
import json
import re
import sys
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
import pr_issue_link  # noqa: E402
import real_use_proof as proof  # noqa: E402

GOOD = '''**Real-use proof**
Real input: an Apple Podcasts share link copied from the Podcasts app on a real phone
Path: Share sheet -> Spoken Margins -> Library -> Play from the shared moment
Steps:
1. Opened the link in Safari
2. Tapped Open in Spoken Margins
Result: PASS - the episode opened at 12:41 and played
Commit: aaaaaaa0
'''


def entries_verdict(text):
    return proof.judge(proof.parse(text))


class ParseTests(unittest.TestCase):
    def test_a_complete_record_counts(self):
        verdict = entries_verdict(GOOD)
        self.assertEqual(verdict.status, 'proved')
        self.assertEqual(verdict.commit, 'aaaaaaa0')

    def test_neighbouring_spellings_of_a_good_record_all_count(self):
        variants = {
            'heading with hashes': GOOD.replace('**Real-use proof**', '## Real-use proof'),
            'lower case': GOOD.replace('**Real-use proof**', '**real-use proof**').replace('Real input', 'real input'),
            'no hyphen': GOOD.replace('Real-use proof', 'Real use proof'),
            'bulleted fields': re.sub(r'^(Real input|Path|Result|Commit)', r'- **\1**', GOOD, flags=re.M).replace('**:', ':'),
            'trailing colon on the heading': GOOD.replace('**Real-use proof**', '**Real-use proof:**'),
            'preceded by other text': 'Some intro.\n\n' + GOOD,
            'indented': GOOD.replace('\nReal input', '\n  Real input'),
            'CRLF': GOOD.replace('\n', '\r\n'),
        }
        for name, text in variants.items():
            with self.subTest(name):
                self.assertEqual(entries_verdict(text).status, 'proved', name)

    def test_a_record_that_fails_its_own_rules_does_not_count(self):
        cases = {
            'no record': ('Looks good to me', 'none', ''),
            'missing steps': (GOOD.replace('Steps:\n1. Opened the link in Safari\n2. Tapped Open in Spoken Margins\n', ''), 'invalid', 'Steps'),
            'missing commit': (GOOD.replace('Commit: aaaaaaa0\n', ''), 'invalid', 'Commit'),
            'empty real input': (GOOD.replace('Real input: an Apple Podcasts share link copied from the Podcasts app on a real phone', 'Real input:'), 'invalid', 'Real input'),
            'placeholder path': (re.sub(r'Path: .*', 'Path: TBD', GOOD), 'invalid', 'Path'),
            'angle placeholder': (re.sub(r'Path: .*', 'Path: <fill in>', GOOD), 'invalid', 'Path'),
            'fixture input': (re.sub(r'Real input: .*', 'Real input: a fixture copy of the page', GOOD), 'invalid', 'fixture'),
            'mock input': (re.sub(r'Real input: .*', 'Real input: Mock episode', GOOD), 'invalid', 'fixture'),
            'FAIL result': (re.sub(r'Result: .*', 'Result: FAIL - it opened the wrong episode', GOOD), 'invalid', 'FAIL'),
            'vague result': (re.sub(r'Result: .*', 'Result: looks fine', GOOD), 'invalid', 'PASS or FAIL'),
            'commit without a hash': (re.sub(r'Commit: .*', 'Commit: latest', GOOD), 'invalid', 'hash'),
            'short hash': (re.sub(r'Commit: .*', 'Commit: abc12', GOOD), 'invalid', 'hash'),
            'heading only': ('**Real-use proof**\n', 'invalid', 'no `'),
        }
        for name, (text, status, mention) in cases.items():
            with self.subTest(name):
                verdict = entries_verdict(text)
                self.assertEqual(verdict.status, status, (name, verdict.problems))
                if mention:
                    self.assertTrue(any(mention in p for p in verdict.problems), (name, verdict.problems))

    def test_fixture_as_part_of_a_real_description_is_not_a_fixture_input(self):
        text = re.sub(r'Real input: .*', 'Real input: my own link, not a fixture, from the Podcasts app', GOOD)
        self.assertEqual(entries_verdict(text).status, 'proved')

    def test_the_newest_record_decides(self):
        fail = GOOD.replace('PASS - the episode opened at 12:41 and played', 'FAIL - opened nothing')
        waiver = 'Real-use proof waived: internal tooling with no listener surface'
        self.assertEqual(entries_verdict(GOOD + '\n' + fail).status, 'invalid')
        self.assertEqual(entries_verdict(fail + '\n' + GOOD).status, 'proved')
        self.assertEqual(entries_verdict(fail + '\n' + waiver).status, 'waived')
        self.assertEqual(entries_verdict(waiver + '\n' + fail).status, 'invalid')

    def test_waivers_need_a_reason(self):
        good = ('Real-use proof waived: docs only change, nothing a listener sees',
                '**Real-use proof waived**: a docs-only change, no listener sees it',
                'real-use proof not needed - build script, no listener surface',
                'real use proof waived - test harness only change')
        for text in good:
            with self.subTest(text):
                self.assertEqual(entries_verdict(text).status, 'waived', text)
        for text in ('Real-use proof waived', 'Real-use proof waived:', 'Real-use proof waived: n/a', 'Real-use proof waived: skip it',
                     'I have not Real-use proof waived: because', 'Real-use proof waived: n/a n/a n/a',
                     '> Real-use proof waived: test harness only change', 'Real-use proof waived: ok ok ok ok ok'):
            with self.subTest(text):
                self.assertFalse(entries_verdict(text).ok, text)

    def test_the_unchanged_template_and_cheap_wording_do_not_count(self):
        template = GOOD
        for field, value in (('Real input', '<the real link, file or screen>'), ('Path', '<every hop>'),
                             ('Steps', '<what you did>'), ('Result', 'PASS - <what you observed>')):
            template = re.sub(rf'^{field}:.*$', f'{field}: {value}', template, flags=re.M)
        self.assertEqual(entries_verdict(template).status, 'invalid')
        cases = {
            'fixtures path': re.sub(r'Real input: .*', 'Real input: tests/fixtures/x.html', GOOD),
            'hand-written': re.sub(r'Real input: .*', 'Real input: hand-written HTML of the page', GOOD),
            'a recorded fixture': re.sub(r'Real input: .*', 'Real input: a recorded fixture', GOOD),
            'sample link': re.sub(r'Real input: .*', 'Real input: sample link', GOOD),
            'bullet fixture': re.sub(r'Real input: .*', 'Real input: - fixture', GOOD),
            'pass but': re.sub(r'Result: .*', 'Result: PASS but the link still fails', GOOD),
            'pass-through': re.sub(r'Result: .*', 'Result: pass-through failed', GOOD),
            'hash second': re.sub(r'Commit: .*', 'Commit: ran on aaaaaaa0', GOOD),
        }
        for name, text in cases.items():
            with self.subTest(name):
                self.assertFalse(entries_verdict(text).ok, name)
        negated = re.sub(r'Real input: .*', 'Real input: my own link, not a sample or a fixture, from the Podcasts app', GOOD)
        self.assertEqual(entries_verdict(negated).status, 'proved')
        self.assertEqual(entries_verdict(re.sub(r'Commit: .*', 'Commit: main aaaaaaa0', GOOD)).status, 'proved')

    def test_records_in_code_fences_quotes_and_html_comments_are_not_claims(self):
        for name, text in (('fence', '```\n' + GOOD + '```\n'), ('tilde fence', '~~~\n' + GOOD + '~~~\n'),
                           ('quote', ''.join('> ' + line + '\n' for line in GOOD.splitlines())),
                           ('comment', '<!--\n' + GOOD + '-->\n')):
            with self.subTest(name):
                self.assertEqual(entries_verdict(text).status, 'none', name)
        quoted_pass_after_fail = re.sub(r'PASS - .*', 'FAIL - broke', GOOD) + '\n' + ''.join('> ' + l + '\n' for l in GOOD.splitlines())
        self.assertEqual(entries_verdict(quoted_pass_after_fail).status, 'invalid')

    def test_prose_after_a_record_does_not_leak_into_it(self):
        cases = {
            'bold pseudo-heading': GOOD + '\n**How you checked it**\nResult: FAIL in the old build\nCommit: nothing\n',
            'paragraph after a blank line': GOOD + '\nThe run was fine, but the old build fails.\nIssue: 99 times\n',
        }
        for name, text in cases.items():
            with self.subTest(name):
                verdict = entries_verdict(text)
                self.assertEqual(verdict.status, 'proved', (name, verdict.problems))
        self.assertNotIn('but the old build', proof.parse(cases['paragraph after a blank line'])[0].fields['result'])
        listed = GOOD.replace('2. Tapped Open in Spoken Margins\n', '\n2. Tapped Open in Spoken Margins\n')
        self.assertIn('Tapped Open', proof.parse(listed)[0].fields['steps'])   # a numbered list may have blank lines

    def test_a_repeated_field_in_one_record_is_held(self):
        # A PASS then a later FAIL line under one header: which one counts is unclear, so it does not pass.
        for text in (GOOD + 'Result: FAIL - regressed on aaaaaaa0\n', GOOD + 'Commit: bbbbbbb0\n'):
            verdict = entries_verdict(text)
            self.assertEqual(verdict.status, 'invalid')
            self.assertTrue(any('appears twice' in p for p in verdict.problems), verdict.problems)
        # A new header starts a new record: the later record decides.
        self.assertEqual(entries_verdict(GOOD + '\n**Real-use proof**\n' + GOOD.split('\n', 1)[1]).status, 'proved')

    def test_the_owner_pass_comment_from_the_phone_plan_is_a_proof(self):
        pass_comment = 'Owner PASS on phone pass 2026-11-23, build abc1234.\nThe link opened at the right moment.'
        self.assertEqual(entries_verdict(pass_comment).status, 'proved')
        fail = GOOD.replace('PASS - the episode opened at 12:41 and played', 'FAIL - broke again')
        self.assertEqual(entries_verdict(pass_comment + '\n' + fail).status, 'invalid')
        self.assertEqual(entries_verdict(fail + '\n' + pass_comment).status, 'proved')
        self.assertEqual(entries_verdict('Owner PASS on a pass of mine').status, 'none')

    def test_a_record_ends_at_the_next_heading(self):
        text = GOOD + '\n## Notes\nPath: somewhere else\nResult: FAIL\n'
        self.assertEqual(entries_verdict(text).status, 'proved')


class IssueRuleTests(unittest.TestCase):
    def test_which_issues_are_listener_facing(self):
        table = [
            (['area: pass it on'], True), (['area: get it in', 'bug'], True), (['area: hear it well'], True),
            (['area: answer it'], True), (['area: housekeeping'], True), (['bug'], True),
            # No area label: a person's report is a listener's, a script's pipeline alarm is not.
            ([], False), (['regression'], False), (['bug', 'regression'], True), (['found-on-phone'], True),
            (['owner-asked'], True), (['priority'], True), (['ready'], False),
            (['area: groundwork'], False), (['Area: Groundwork', 'bug'], False),
            (['area: groundwork', 'area: pass it on'], True),
        ]
        for labels, expected in table:
            with self.subTest(labels=labels):
                self.assertIs(proof.listener_facing([{'name': n} for n in labels]), expected)
                self.assertIs(proof.listener_facing(labels), expected)

    def test_closing_keywords_match_pr_issue_link_and_other_repositories_do_not_count(self):
        # The same keyword list as pr_issue_link.CLOSING, so the two readings of a PR body cannot drift.
        keywords = re.match(r'\\b\(\?:(.*?)\)\[ \\t\]', pr_issue_link.CLOSING.pattern).group(1)
        self.assertEqual(keywords, 'close[sd]?|fix(?:e[sd])?|resolve[sd]?')
        repo = 'Spoken-Margins/spoken-margins-native'
        table = [
            ('Closes #12', [12]), ('closes #12', [12]), ('Fixes: #12', [12]), ('resolved #12', [12]), ('Closes  #12', [12]),
            ('Part of #12', []), ('Closes nothing', []), ('closest #12', []), ('Closes #9', []),
            ('Closes https://github.com/Spoken-Margins/spoken-margins-native/issues/14', [14]),
            ('Closes https://github.com/other/repo/issues/14', []),
            ('Closes Spoken-Margins/spoken-margins-native#15', [15]), ('Closes other/repo#15', []),
            ('Closes #12\nFixes #13\nCloses #12', [12, 13]), ('', []), (None, []),
            ('`Closes #12`', []), ('```\nCloses #12\n```', []), ('> Closes #12', []), ('<!-- Closes #12 -->', []),
            ('Closes #12 and `Closes #13`', [12]), ('Closes #12\r\nCloses #13', [12, 13]),
        ]
        for body, expected in table:
            with self.subTest(body=body):
                self.assertEqual(proof.closing_issues(body, 9, repo), expected)

    def test_exempt_paths_are_notes_and_tests_only(self):
        for path in ('README.md', 'docs/x.png', 'ops/notes.md', 'App/SpokenMarginsAppTests/N.md', 'Packages/SessionKit/Tests/SessionKitTests/A.swift', 'scripts/tests/t.py',
                     'App/SpokenMarginsAppUITests/J.swift'):
            self.assertTrue(proof.exempt_path(path), path)
        for path in ('App/SpokenMarginsApp/Resources/ValidationChecklist.md', 'Contracts/docs/recovery-mvp.md', 'latests/x.py',
                     'App/SpokenMarginsApp/Sources/A.swift', 'web/share.js', 'scripts/tool.py', 'testsupport.swift',
                     'Packages/SessionKit/Sources/SessionKitSharing/A.swift'):
            self.assertFalse(proof.exempt_path(path), path)

    def test_staleness(self):
        own = ['a' * 40, 'b' * 40]
        after = lambda commit: ['docs/x.md', 'scripts/tests/t.py']   # noqa: E731
        self.assertIsNone(proof.stale_after('aaaaaaa', own, after))
        self.assertIn('not one of this PR', proof.stale_after('ccccccc', own, after))
        code = lambda commit: ['web/share.js', 'docs/x.md']          # noqa: E731
        self.assertIn('`web/share.js`', proof.stale_after('AAAAAAA', own, code))


class FakeApi:
    repo = 'o/r'

    def __init__(self, issues, comments=None):
        self._issues, self._comments = issues, comments or {}

    def issue(self, number):
        return self._issues[number]

    def issue_comments(self, number):
        return self._comments.get(number, [])


def comment(body, when='2026-11-22T10:00:00Z', association='OWNER'):
    return {'body': body, 'created_at': when, 'author_association': association, 'user': {'login': 'x'}}


def pull(body, association='OWNER'):
    return {'body': body, 'created_at': '2026-11-22T09:00:00Z', 'author_association': association, 'user': {'login': 'x'}}


class PrBlockerTests(unittest.TestCase):
    def blockers(self, body, issues, comments=(), issue_comments=None, association='OWNER', own=('aaaaaaa0' + 'b' * 32,), after=()):
        api = FakeApi(issues, issue_comments)
        return proof.pr_blockers(api, 9, pull(body, association), list(comments), lambda: list(own), lambda c: list(after))

    LISTENER = {4783: {'labels': [{'name': 'area: pass it on'}]}}

    def test_closing_a_listener_issue_without_proof_is_held_with_the_way_out(self):
        reasons = self.blockers('Closes #4783', self.LISTENER)
        self.assertEqual(len(reasons), 1)
        for text in ('`Closes #4783`', 'area: pass it on', 'none is recorded', '`Part of #4783`', 'Real-use proof waived'):
            self.assertIn(text, reasons[0])

    def test_proof_in_the_pr_body_a_pr_comment_or_the_issue_each_lifts_the_hold(self):
        self.assertEqual(self.blockers('Closes #4783\n\n' + GOOD, self.LISTENER), [])
        self.assertEqual(self.blockers('Closes #4783', self.LISTENER, comments=[comment(GOOD)]), [])
        self.assertEqual(self.blockers('Closes #4783', self.LISTENER, issue_comments={4783: [comment(GOOD)]}), [])

    def test_a_waiver_lifts_it_and_a_later_fail_on_the_issue_puts_it_back(self):
        waiver = 'Real-use proof waived: build tooling with no listener surface'
        self.assertEqual(self.blockers('Closes #4783\n\n' + waiver, self.LISTENER), [])
        fail = comment(GOOD.replace('PASS - the episode opened at 12:41 and played', 'FAIL - nothing played'), '2026-11-22T12:00:00Z')
        reasons = self.blockers('Closes #4783\n\n' + GOOD, self.LISTENER, issue_comments={4783: [fail]})
        self.assertEqual(len(reasons), 1)
        self.assertIn('Result is FAIL', reasons[0])

    def test_part_of_groundwork_and_a_strangers_text_are_handled(self):
        self.assertEqual(self.blockers('Part of #4783', self.LISTENER), [])
        groundwork = {4979: {'labels': [{'name': 'area: groundwork'}, {'name': 'bug'}]}}
        self.assertEqual(self.blockers('Closes #4979', groundwork), [])
        # The "Main T3 failed" alarm (label `regression`, no area) and "Merging has stalled" (no labels): a test-fix PR may close them.
        alarms = {7: {'labels': [{'name': 'regression'}]}, 8: {'labels': []}}
        self.assertEqual(self.blockers('Closes #7\nCloses #8', alarms), [])
        # A stranger's PR body and the comments the lane does not trust (filtered before they get here) carry no weight.
        self.assertEqual(len(self.blockers('Closes #4783\n\n' + GOOD, self.LISTENER, association='CONTRIBUTOR')), 1)
        self.assertEqual(self.blockers('Closes #4783\n\n' + GOOD, self.LISTENER, association='COLLABORATOR'), [])

    def test_a_pr_named_as_the_target_is_skipped_and_two_issues_are_judged_separately(self):
        issues = {**self.LISTENER, 4784: {'labels': [{'name': 'area: get it in'}]}, 5: {'labels': [], 'pull_request': {}}}
        both = GOOD + 'Issue: #4783 #4784\n'
        self.assertEqual(self.blockers('Closes #4783\nCloses #4784\nCloses #5\n\n' + both, issues), [])
        # One run on the PR can't stand in for two issues unless it says it covers both; an Issue line names which.
        self.assertEqual(len(self.blockers('Closes #4783\nCloses #4784\n\n' + GOOD, issues)), 2)
        one = self.blockers('Closes #4783\nCloses #4784\n\n' + GOOD + 'Issue: #4783\n', issues)
        self.assertEqual(len(one), 1)
        self.assertIn('#4784', one[0])
        self.assertEqual(len(self.blockers('Closes #4783\n\n' + GOOD + 'Issue: #4999\n', issues)), 1)
        reasons = self.blockers('Closes #4783\nCloses #4784', issues, issue_comments={4783: [comment(GOOD)]})
        self.assertEqual(len(reasons), 1)
        self.assertIn('#4784', reasons[0])

    def test_proof_goes_stale_when_the_pr_changes_listener_code_after_it(self):
        reasons = self.blockers('Closes #4783\n\n' + GOOD, self.LISTENER,
                                after=['App/SpokenMarginsApp/Sources/A.swift'])
        self.assertEqual(len(reasons), 1)
        self.assertIn('run it again on the head', reasons[0])
        self.assertEqual(self.blockers('Closes #4783\n\n' + GOOD, self.LISTENER,
                                       after=['docs/a.md']), [])


class ParkedTests(unittest.TestCase):
    def test_a_repro_attempt_or_an_owner_check_counts_and_other_comments_do_not(self):
        good = '**Repro attempt**\nTried: opened a real share link in Chrome and the simulator\nResult: not reproduced; the link needs his phone\n'
        table = [
            ([], False), ([comment('needs his phone')], False), ([comment(good)], True),
            ([comment(good, association='NONE')], False),
            ([comment('**Owner check**\nOpen the build and tap Play')], True),
            ([comment('Owner check: none. Leave this off the owner\'s plans.')], False),
            ([comment('Owner check not needed')], False),
            ([comment('**Repro attempt**\nTried:\nResult: n/a')], False),
            ([comment('**Repro attempt**\nTried: opened it\n')], False),
        ]
        for comments, expected in table:
            with self.subTest(comments=comments):
                self.assertIs(proof.repro_attempted(comments), expected)


class SweepTests(unittest.TestCase):
    class Gh:
        repo = 'o/r'

        def __init__(self, issues, comments, timeline=None, pulls=None):
            self.issues, self.comments, self.timeline, self.pulls, self.writes = issues, comments, timeline or {}, pulls or {}, []

        def api(self, path, paginate=False, method='GET', fields=None):
            if method != 'GET':
                self.writes.append((method, path, fields))
                return {}
            if path.startswith('issues?state=closed'):
                return self.issues
            m = re.match(r'issues/(\d+)/timeline', path)
            if m:
                return self.timeline.get(int(m.group(1)), [])
            m = re.match(r'commits/(\w+)$', path)
            if m:
                return getattr(self, 'commits', {}).get(m.group(1), {})
            m = re.match(r'pulls/(\d+)$', path)
            if m:
                return getattr(self, 'pull_by_number', {}).get(int(m.group(1)), {})
            m = re.match(r'commits/(\w+)/pulls', path)
            if m:
                return self.pulls.get(m.group(1), [])
            m = re.match(r'issues/(\d+)/comments', path)
            return self.comments.get(int(m.group(1)), [])

        def issue_comments(self, number):
            return [c for c in self.comments.get(number, []) if c['author_association'] == 'OWNER']

    def closed(self, number, labels=('area: pass it on',), reason='completed', when='2026-11-23T12:00:00Z', **extra):
        return {'number': number, 'title': f'issue {number}', 'state_reason': reason, 'closed_at': when,
                'labels': [{'name': n} for n in labels], **extra}

    def run_sweep(self, gh, apply=False):
        now = dt.datetime(2026, 12, 1, tzinfo=dt.timezone.utc)
        return proof.sweep(gh, dt.datetime(2026, 11, 1, tzinfo=dt.timezone.utc), apply, now=now)

    def test_a_listener_issue_closed_without_proof_is_reopened_once_with_a_comment(self):
        gh = self.Gh([self.closed(1)], {})
        report = self.run_sweep(gh, apply=True)
        self.assertEqual(report['reopened'], [1])
        methods = [(m, p) for m, p, _ in gh.writes]
        self.assertEqual(methods, [('PATCH', 'issues/1'), ('POST', 'issues/1/comments')])
        self.assertIn(proof.MARKER, gh.writes[1][2]['body'])
        self.assertEqual(self.run_sweep(self.Gh([self.closed(1)], {}))['flagged'][0]['issue'], 1)   # dry run writes nothing

    def test_what_the_sweep_leaves_alone(self):
        issues = [
            self.closed(2, labels=('area: groundwork',)),
            self.closed(3, reason='not_planned'), self.closed(4, reason='duplicate'),
            self.closed(5, when='2026-11-22T12:00:00Z'),           # closed before the owner's call
            self.closed(6, pull_request={}),                       # a PR
            self.closed(7),                                        # proof on the issue
            self.closed(8),                                        # waived on the issue
        ]
        comments = {7: [comment(GOOD)], 8: [comment('Real-use proof waived: build script with no listener surface')]}
        gh = self.Gh(issues, comments)
        report = self.run_sweep(gh, apply=True)
        self.assertEqual((report['proved'], report['waived'], report['flagged'], gh.writes), (1, 1, [], []))

    def test_proof_in_the_closing_prs_body_counts(self):
        gh = self.Gh([self.closed(9)], {}, timeline={9: [{'event': 'closed', 'commit_id': 'deadbee'}]},
                     pulls={'deadbee': [{'number': 30, 'body': 'Closes #9\n\n' + GOOD, 'created_at': '2026-11-22T09:00:00Z',
                                         'author_association': 'OWNER', 'user': {'login': 'x'}}]})
        report = self.run_sweep(gh, apply=True)
        self.assertEqual((report['proved'], report['flagged'], gh.writes), (1, [], []))

    def test_grace_period_a_pr_that_names_another_issue_and_a_second_closure(self):
        recent = '2026-11-30T23:50:00Z'   # ten minutes before the test's "now": the proof may be a minute behind
        gh = self.Gh([self.closed(11, when=recent)], {})
        self.assertEqual(self.run_sweep(gh, apply=True)['flagged'], [])
        # The PR of the closing commit has a proof whose Issue line names another issue: it is not this issue's.
        gh = self.Gh([self.closed(12)], {}, timeline={12: [{'event': 'closed', 'commit_id': 'deadbee'}]},
                     pulls={'deadbee': [{'number': 31, 'body': 'Closes #99\n\n' + GOOD + 'Issue: #99\n', 'created_at': '2026-11-22T09:00:00Z',
                                         'author_association': 'OWNER', 'user': {'login': 'x'}}]})
        self.assertEqual(len(self.run_sweep(gh)['flagged']), 1)
        # Reopened once already (the sweep's marker is on the issue) and closed again by hand: left closed.
        gh = self.Gh([self.closed(13)], {13: [comment(proof.MARKER + '\nReopened')]})
        report = self.run_sweep(gh, apply=True)
        self.assertEqual((report['again'], report['reopened'], gh.writes), ([13], [], []))

    def test_the_phone_plans_owner_pass_close_comment_is_not_reopened(self):
        gh = self.Gh([self.closed(16)], {16: [comment('Owner PASS on phone pass 2026-11-23, build abc1234.\nPlayed fine.')]})
        report = self.run_sweep(gh, apply=True)
        self.assertEqual((report['proved'], report['flagged'], gh.writes), (1, [], []))

    def test_a_hand_close_with_proof_on_a_part_of_pr_passes_the_gate_and_the_sweep_alike(self):
        part_of = {'number': 34, 'merged_at': '2026-11-22T10:00:00Z', 'body': 'Part of #17', 'created_at': '2026-11-22T09:00:00Z',
                   'author_association': 'OWNER', 'user': {'login': 'x'}}
        proof_comment = comment(GOOD, '2026-11-22T11:00:00Z')
        gh = self.Gh([self.closed(17)], {34: [proof_comment]}, timeline={17: [
            {'event': 'closed', 'commit_id': None},
            {'event': 'cross-referenced', 'source': {'issue': {'number': 34, 'pull_request': {}, 'repository': {'full_name': 'o/r'}}}}]})
        gh.pull_by_number = {34: part_of}
        report = self.run_sweep(gh, apply=True)
        self.assertEqual((report['proved'], report['flagged'], gh.writes), (1, [], []))
        # The same two sources, read the way `--issue 17 --pr 34` reads them, agree.
        items = proof.issue_items([]) + proof.timed_items(part_of, [proof_comment])
        self.assertTrue(proof.judge(proof.entries_for(items, 17)).ok)

    def test_a_cross_reference_from_another_repository_or_a_non_pr_is_skipped_not_an_error(self):
        gh = self.Gh([self.closed(18)], {}, timeline={18: [
            {'event': 'closed', 'commit_id': None},
            {'event': 'cross-referenced', 'source': {'issue': {'number': 5, 'pull_request': {}, 'repository': {'full_name': 'o/ops-private'}}}},
            {'event': 'cross-referenced', 'source': {'issue': {'number': 6, 'pull_request': {}, 'repository': {'full_name': 'o/r'}}}}]})
        orig = gh.api
        def api(path, paginate=False, method='GET', fields=None):
            if path == 'pulls/6':
                raise RuntimeError('404')
            return orig(path, paginate, method, fields)
        gh.api = api
        report = self.run_sweep(gh)
        self.assertEqual((len(report['flagged']), report['unknown']), (1, []))

    def merged_pr(self, number, body, comments=()):
        return {'number': number, 'merged_at': '2026-11-22T10:00:00Z', 'body': body, 'created_at': '2026-11-22T09:00:00Z',
                'author_association': 'OWNER', 'user': {'login': 'x'}}

    def xref(self, number):
        return {'event': 'cross-referenced', 'source': {'issue': {'number': number, 'pull_request': {}, 'repository': {'full_name': 'o/r'}}}}

    def test_a_pr_that_only_mentions_the_issue_speaks_for_nothing(self):
        # Scenario A: a Part-of PR's waiver (a fixture harness) must not excuse a hand close.
        waiver = 'Real-use proof waived: fixture harness only, no listener surface'
        for body in ('Part of #19\n\n' + waiver, 'See #19 for context.\n\n' + waiver, 'Follow-up to #19\n\n' + GOOD):
            with self.subTest(body=body[:30]):
                gh = self.Gh([self.closed(19)], {}, timeline={19: [{'event': 'closed', 'commit_id': None}, self.xref(35)]})
                gh.pull_by_number = {35: self.merged_pr(35, body)}
                self.assertEqual(len(self.run_sweep(gh)['flagged']), 1, body)
        # Scenario B: a proof for another issue, in a PR that closes that other issue and mentions this one.
        gh = self.Gh([self.closed(19)], {}, timeline={19: [{'event': 'closed', 'commit_id': None}, self.xref(36)]})
        gh.pull_by_number = {36: self.merged_pr(36, 'Closes #4790, follow-up to #19\n\n' + GOOD + 'Issue: #4790\n')}
        self.assertEqual(len(self.run_sweep(gh)['flagged']), 1)
        # A Part-of PR's proof does count; its waiver does not; a closing PR's waiver does.
        gh = self.Gh([self.closed(19)], {}, timeline={19: [{'event': 'closed', 'commit_id': None}, self.xref(37)]})
        gh.pull_by_number = {37: self.merged_pr(37, 'Part of #19\n\n' + GOOD)}
        self.assertEqual(self.run_sweep(gh)['proved'], 1)
        gh = self.Gh([self.closed(19)], {}, timeline={19: [{'event': 'closed', 'commit_id': None}, self.xref(38)]})
        gh.pull_by_number = {38: self.merged_pr(38, 'Closes #19\n\nReal-use proof waived: tooling only, no listener surface')}
        self.assertEqual(self.run_sweep(gh)['waived'], 1)

    def test_an_owner_pass_before_the_issue_was_reopened_proves_nothing_now(self):
        old_pass = comment('Owner PASS on phone pass 2026-11-23, build abc1234.', '2026-11-23T08:00:00Z')
        reopened = {'event': 'reopened', 'created_at': '2026-11-24T08:00:00Z'}
        gh = self.Gh([self.closed(20, when='2026-11-25T12:00:00Z')], {20: [old_pass]}, timeline={20: [reopened, {'event': 'closed', 'commit_id': None}]})
        self.assertEqual(len(self.run_sweep(gh)['flagged']), 1)
        fresh = comment('Owner PASS on phone pass 2026-11-25, build def5678.', '2026-11-25T09:00:00Z')
        gh = self.Gh([self.closed(20, when='2026-11-25T12:00:00Z')], {20: [old_pass, fresh]}, timeline={20: [reopened]})
        self.assertEqual(self.run_sweep(gh)['proved'], 1)
        # Never reopened: the pass stands.
        gh = self.Gh([self.closed(21)], {21: [old_pass]})
        self.assertEqual(self.run_sweep(gh)['proved'], 1)

    def test_a_pr_closing_a_listener_issue_is_not_cleared_by_an_owner_pass(self):
        api = FakeApi({4783: {'labels': [{'name': 'area: pass it on'}]}},
                      {4783: [comment('Owner PASS on phone pass 2026-11-24, build abc1234.')]})
        reasons = proof.pr_blockers(api, 9, pull('Closes #4783'), [], lambda: ['aaaaaaa0' + 'b' * 32], lambda c: [])
        self.assertEqual(len(reasons), 1)
        pass_in_pr = proof.pr_blockers(api, 9, pull('Closes #4783\n\nOwner PASS on phone pass x, build y'), [],
                                       lambda: ['aaaaaaa0' + 'b' * 32], lambda c: [])
        self.assertEqual(len(pass_in_pr), 1)

    def test_a_pr_whose_body_says_part_of_but_whose_commit_says_closes_still_counts(self):
        # merge policy reads body plus commit messages; the sweep reads the same text, or it would reopen what merge policy passed.
        gh = self.Gh([self.closed(14)], {}, timeline={14: [{'event': 'closed', 'commit_id': 'deadbee'}]},
                     pulls={'deadbee': [{'number': 32, 'body': 'Part of #14\n\n' + GOOD, 'created_at': '2026-11-22T09:00:00Z',
                                         'author_association': 'OWNER', 'user': {'login': 'x'}}]})
        gh.commits = {'deadbee': {'commit': {'message': 'Fix it\n\nCloses #14'}}}
        report = self.run_sweep(gh, apply=True)
        self.assertEqual((report['proved'], report['flagged'], gh.writes), (1, [], []))

    def test_the_closing_pr_is_found_by_the_timeline_when_the_closed_event_has_no_commit(self):
        gh = self.Gh([self.closed(15)], {}, timeline={15: [
            {'event': 'closed', 'commit_id': None},
            {'event': 'cross-referenced', 'source': {'issue': {'number': 33, 'pull_request': {}}}}]})
        gh.pull_by_number = {33: {'number': 33, 'merged_at': '2026-11-22T10:00:00Z', 'body': 'Closes #15\n\n' + GOOD,
                                  'created_at': '2026-11-22T09:00:00Z', 'author_association': 'OWNER', 'user': {'login': 'x'}}}
        report = self.run_sweep(gh, apply=True)
        self.assertEqual((report['proved'], report['flagged']), (1, []))

    def test_a_read_failure_is_reported_and_reopens_nothing(self):
        gh = self.Gh([self.closed(10)], {})
        gh.api_orig = gh.api
        def broken(path, paginate=False, method='GET', fields=None):
            if path.startswith('issues/10/timeline'):
                raise RuntimeError('boom')
            return gh.api_orig(path, paginate, method, fields)
        gh.api = broken
        report = self.run_sweep(gh, apply=True)
        self.assertEqual((report['reopened'], len(report['unknown'])), ([], 1))


if __name__ == '__main__':
    unittest.main()
