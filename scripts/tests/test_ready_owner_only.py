"""`ready` on an issue with only the owner's check left (#3666): the table of look-alike comments, the stranger's
comment that must be ignored, and what --apply writes."""
import os
os.environ.pop('SM_TRUNK', None)
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import ready_owner_only as guard
import sm_status


def comment(body, when='2026-11-07T10:00:00Z', association='MEMBER', login='uncomposed'):
    return {'body': body, 'created_at': when, 'author_association': association, 'user': {'login': login}}


def issue(number=3108, *labels, pull=False):
    item = {'number': number, 'labels': [{'name': name} for name in (labels or (guard.READY,))]}
    if pull:
        item['pull_request'] = {}
    return item


class Wording(unittest.TestCase):
    def test_table_of_comments(self):
        table = {
            # the owner's check is all that is left
            'Owner only now.': True,
            'owner-only': True,
            'OWNER ONLY': True,
            "Only the owner's check is left.": True,
            "only the owner's phone check remains": True,
            'Only his check remains.': True,
            "Only the owner’s check is left": True,
            'all that is left is the owner check': True,
            "All that's left is his phone check": True,
            "Nothing left but the owner's check.": True,
            "no work left except the owner's check": True,
            "The owner's check is the only thing left.": True,
            "his check is all that's left": True,
            "Waiting only on the owner's check": True,
            "just waiting on his phone check": True,
            'Merged in #3403.\n\nOwner only.': True,
            # look-alikes that must stay `ready`
            'Owner check: none. Leave this off the owner\'s plans.': False,
            "The owner's check is one item of three; the other two are code.": False,
            'Only the code is left; the owner will check it later.': False,
            'not owner only': False,
            "it isn't owner only": False,
            'No longer owner only': False,
            "not only the owner's check is left": False,
            "Claimed by project thread \"Work the ready queue\"": False,
            'Handing back: I cannot finish this, the test needs the Mac.': False,
            'Only the owner can decide this.': False,
            'Owners only look at the phone plan.': False,
            '`owner only`': False,
            '```\nowner only\n```': False,
            '> Owner only, said the old comment\nStill work here.': False,
            '': False,
            None: False,
        }
        for body, want in table.items():
            with self.subTest(body=body):
                self.assertEqual(guard.says_owner_only(body), want)


class Verdict(unittest.TestCase):
    def test_only_the_newest_trusted_comment_counts(self):
        owner_only = comment('Owner only.', '2026-11-07T10:00:00Z')
        newer_work = comment('More code is left: the export step.', '2026-11-07T11:00:00Z')
        table = {
            'newest says owner only': ([comment('Done in #1.', '2026-11-06T09:00:00Z'), owner_only], 'flag'),
            'a later comment names work': ([owner_only, newer_work], None),
            'listed newest first still reads the newest': ([newer_work, owner_only], None),
            'no comments': ([], None),
            'a collaborator counts': ([comment('Owner only.', association='COLLABORATOR', login='c')], 'flag'),
            'the workflows bot counts': ([comment('Owner only.', association='NONE', login='github-actions[bot]')], 'flag'),
        }
        for name, (comments, want) in table.items():
            with self.subTest(name):
                self.assertEqual(guard.verdict(issue(), comments), want)

    def test_a_strangers_comment_is_ignored_either_way(self):
        for association in ('NONE', 'CONTRIBUTOR', 'FIRST_TIME_CONTRIBUTOR', 'FIRST_TIMER', 'MANNEQUIN', None):
            with self.subTest(association=association):
                stranger = comment('Owner only.', '2026-11-07T12:00:00Z', association=association, login='mallory')
                # alone: nothing to act on
                self.assertIsNone(guard.verdict(issue(), [stranger]))
                # newest, over a trusted comment that names work: still nothing
                self.assertIsNone(guard.verdict(issue(), [comment('Code is left.', '2026-11-07T10:00:00Z'), stranger]))
                # newest, over a trusted "owner only": the trusted one still counts
                self.assertEqual(guard.verdict(issue(), [comment('Owner only.', '2026-11-07T10:00:00Z'), stranger]), 'flag')
                # a stranger's plain comment must not hide the trusted "owner only" either
                self.assertEqual(guard.verdict(issue(), [comment('Owner only.', '2026-11-07T10:00:00Z'),
                                                         comment('any update?', '2026-11-07T12:00:00Z', association=association, login='mallory')]), 'flag')

    def test_lookalike_bot_logins_are_strangers(self):
        for login in ('github-actions', 'GitHub-Actions[bot]', 'github-actions[bot]x'):
            with self.subTest(login=login):
                self.assertIsNone(guard.verdict(issue(), [comment('Owner only.', association='NONE', login=login)]))

    def test_a_stranger_cannot_fake_the_guards_marker(self):
        trusted = comment('Owner only.', '2026-11-07T10:00:00Z')
        fake = comment(guard.MARKER + ' more', '2026-11-07T12:00:00Z', association='NONE', login='mallory')
        self.assertEqual(guard.verdict(issue(), [trusted, fake]), 'flag')

    def test_the_guards_own_comment_stops_a_loop(self):
        said = comment('Owner only.', '2026-11-07T10:00:00Z')
        own = comment(guard.COMMENT, '2026-11-07T10:05:00Z')
        self.assertEqual(guard.verdict(issue(), [said]), 'flag')
        self.assertIsNone(guard.verdict(issue(), [said, own]))   # the owner put `ready` back: leave it
        self.assertEqual(guard.verdict(issue(), [said, own, comment('Owner only again.', '2026-11-07T11:00:00Z')]), 'flag')

    def test_an_issue_without_ready_is_never_flagged(self):
        self.assertIsNone(guard.verdict(issue(3108, 'status: needs-human-validation'), [comment('Owner only.')]))


class FakeApi:
    def __init__(self, issues, comments):
        self.issues, self.comments, self.writes = issues, comments, []

    def pages(self, path, limit=30, partial=False):
        if path.startswith('issues?state=open&labels=ready'):
            return self.issues
        number = int(path.split('/')[1])
        assert path.endswith('/comments'), path
        return self.comments[number]

    def post(self, path, body):
        self.writes.append(('POST', path, body))

    def delete(self, path):
        self.writes.append(('DELETE', path))
        if path.endswith('/gone'):
            raise sm_status.GitHubError('HTTP 404')


class Apply(unittest.TestCase):
    def setUp(self):
        self.issues = [issue(1), issue(2), issue(3, guard.READY, 'status: needs-human-validation'), issue(4, pull=True)]
        self.comments = {1: [comment('Owner only.')], 2: [comment('Code is left.')], 3: [comment('Owner only.')]}

    def test_dry_run_reports_and_writes_nothing(self):
        api = FakeApi(self.issues, self.comments)
        report = guard.reconcile(api)
        self.assertEqual(report['flagged'], [1, 3])
        self.assertEqual(report['unchanged'], 1)
        self.assertEqual(api.writes, [])

    def test_apply_comments_labels_and_takes_ready_off(self):
        api = FakeApi(self.issues, self.comments)
        guard.reconcile(api, apply=True)
        self.assertEqual(api.writes, [
            ('POST', 'issues/1/comments', {'body': guard.COMMENT}),
            ('POST', 'issues/1/labels', {'labels': [guard.VALIDATION]}),
            ('DELETE', 'issues/1/labels/ready'),
            ('POST', 'issues/3/comments', {'body': guard.COMMENT}),   # already carries a validation label: not added again
            ('DELETE', 'issues/3/labels/ready'),
        ])

    def test_a_second_pass_does_nothing(self):
        api = FakeApi(self.issues, self.comments)
        guard.reconcile(api, apply=True)
        self.comments[1].append(comment(guard.COMMENT, '2026-11-07T10:05:00Z'))
        self.comments[3].append(comment(guard.COMMENT, '2026-11-07T10:05:00Z'))
        again = FakeApi(self.issues, self.comments)   # `ready` put back by hand: the guard stays out
        self.assertEqual(guard.reconcile(again, apply=True)['flagged'], [])
        self.assertEqual(again.writes, [])

    def test_a_read_failure_is_reported_and_the_rest_go_on(self):
        class Broken(FakeApi):
            def pages(self, path, limit=30, partial=False):
                if path == 'issues/1/comments':
                    raise sm_status.GitHubError('HTTP 502')
                return super().pages(path, limit, partial)
        report = guard.reconcile(Broken(self.issues, self.comments))
        self.assertEqual([u['issue'] for u in report['unknown']], [1])
        self.assertEqual(report['flagged'], [3])

    def test_a_missing_ready_label_on_delete_is_fine(self):
        class Gone(FakeApi):
            def delete(self, path):
                super().delete(path)
                raise sm_status.GitHubError('HTTP 404')
        report = guard.reconcile(Gone(self.issues, self.comments), apply=True)
        self.assertEqual(report['unknown'], [])


if __name__ == '__main__':
    unittest.main()
